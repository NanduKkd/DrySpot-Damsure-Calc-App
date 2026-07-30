import { Response } from 'express';
import { randomUUID } from 'crypto';
import path from 'path';
import { AuthRequest } from '../middleware/authMiddleware';
import { Proposal, Client, sequelize } from '../models';
import { removeUploadedFile } from '../middleware/uploadMiddleware';
import {
	queueManagedFileCleanup,
	reconcileManagedFileCleanupByStorageKeys,
} from '../services/managedFileCleanup';
import { lockTenantSyncState, nextTenantSyncCursor } from '../services/tenantSyncCursor';

const pdfUrlFor = (id: string) => `/api/proposal/${id}/download`;

export const uploadProposal = async (req: AuthRequest, res: Response) => {
	const file = req.file;
	if (!file) return res.status(400).json({ error: 'No PDF file uploaded' });
	const franchiseeId = req.user?.franchiseeId;
	if (!franchiseeId) {
		await removeUploadedFile(file);
		return res.status(401).json({ error: 'Unauthorized' });
	}
	try {
		const proposal = await sequelize.transaction(async (transaction) => {
			const state = await lockTenantSyncState(franchiseeId, transaction);
			const client = await Client.findOne({
				where: { id: req.body.client_id, franchiseeId },
				transaction,
				lock: transaction.LOCK.UPDATE,
			});
			if (!client) return null;
			const cursor = nextTenantSyncCursor(state.cursor);
			const id = randomUUID();
			const created = await Proposal.create(
				{
					id,
					clientId: client.id,
					pdfUrl: pdfUrlFor(id),
					pdfFileName: file.filename,
					syncCursor: cursor.toString(),
				},
				{ transaction },
			);
			await state.update({ cursor: cursor.toString() }, { transaction });
			return created;
		});
		if (!proposal) {
			await removeUploadedFile(file);
			return res
				.status(403)
				.json({ error: 'Unauthorized: Client does not belong to your franchisee' });
		}
		return res.status(201).json(proposal);
	} catch (error) {
		await removeUploadedFile(file);
		console.error('Proposal upload error:', error);
		return res.status(500).json({ error: 'An error occurred during proposal upload' });
	}
};

export const getProposals = async (req: AuthRequest, res: Response) => {
	const client = await Client.findOne({
		where: { id: req.params.client_id, franchiseeId: req.user?.franchiseeId },
	});
	if (!client) return res.status(403).json({ error: 'Unauthorized' });
	return res.json(
		await Proposal.findAll({ where: { clientId: client.id }, order: [['createdAt', 'DESC']] }),
	);
};

export const downloadProposal = async (req: AuthRequest, res: Response) => {
	const proposal = await Proposal.findOne({
		where: { id: req.params.id },
		include: [{ model: Client, where: { franchiseeId: req.user?.franchiseeId } }],
	});
	if (!proposal) return res.status(404).json({ error: 'Proposal not found or unauthorized' });
	const filename =
		proposal.pdfFileName ||
		path.basename(new URL(proposal.pdfUrl, 'http://localhost').pathname);
	return res
		.type('application/pdf')
		.sendFile(path.join(__dirname, '../../uploads', filename), (error) => {
			if (error && !res.headersSent)
				res.status(404).json({ error: 'Proposal PDF not found' });
		});
};

export const deleteProposal = async (req: AuthRequest, res: Response) => {
	const franchiseeId = req.user?.franchiseeId;
	if (!franchiseeId) return res.status(401).json({ error: 'Unauthorized' });
	const storageKey = await sequelize.transaction(async (transaction) => {
		const state = await lockTenantSyncState(franchiseeId, transaction);
		const proposal = await Proposal.findByPk(req.params.id, {
			transaction,
			lock: transaction.LOCK.UPDATE,
		});
		if (!proposal) return undefined;
		const client = await Client.findOne({
			where: { id: proposal.clientId, franchiseeId },
			paranoid: false,
			transaction,
		});
		if (!client) return undefined;
		const cursor = nextTenantSyncCursor(state.cursor);
		await proposal.update({ syncCursor: cursor.toString() }, { transaction });
		await proposal.destroy({ transaction });
		if (proposal.pdfFileName) {
			await queueManagedFileCleanup('pdf', proposal.pdfFileName, transaction);
		}
		await state.update({ cursor: cursor.toString() }, { transaction });
		return proposal.pdfFileName ?? null;
	});
	if (storageKey === undefined) {
		return res.status(404).json({ error: 'Proposal not found or unauthorized' });
	}
	await reconcileManagedFileCleanupByStorageKeys(storageKey ? [storageKey] : [], 1);
	return res.status(204).send();
};
