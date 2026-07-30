import { Response } from 'express';
import { randomUUID } from 'crypto';
import path from 'path';
import { AuthRequest } from '../middleware/authMiddleware';
import { Warranty, Client, sequelize } from '../models';
import { removeStoredPdf, removeUploadedFile } from '../middleware/uploadMiddleware';

const pdfUrlFor = (id: string) => `/api/warranty/${id}/download`;

export const uploadWarranty = async (req: AuthRequest, res: Response) => {
	const { client_id, start_date, duration_years, warranty_card_number } = req.body;
	const franchiseeId = req.user?.franchiseeId;
	const file = req.file;
	const replaceExisting =
		req.body.replace_existing === 'true' || req.body.replace_existing === true;
	const reject = async (status: number, error: string) => {
		await removeUploadedFile(file);
		return res.status(status).json({ error });
	};

	if (!file) return res.status(400).json({ error: 'No PDF file uploaded' });
	if (!franchiseeId) return reject(401, 'Unauthorized: Franchisee ID not found in token');
	if (typeof client_id !== 'string' || !client_id.trim())
		return reject(400, 'client_id is required');
	const parsedStartDate = new Date(start_date);
	if (Number.isNaN(parsedStartDate.getTime()))
		return reject(400, 'start_date must be a valid date');
	const parsedDurationYears = Number.parseInt(duration_years, 10);
	if (Number.isNaN(parsedDurationYears) || parsedDurationYears <= 0) {
		return reject(400, 'duration_years must be a positive integer');
	}
	if (typeof warranty_card_number !== 'string' || !warranty_card_number.trim()) {
		return reject(400, 'warranty_card_number is required');
	}

	try {
		const client = await Client.findByPk(client_id, {
			paranoid: false,
			attributes: ['id', 'franchiseeId', 'deletedAt'],
		});
		if (!client) return reject(404, 'Client not found. Please sync client data and try again');
		if (client.franchiseeId !== franchiseeId)
			return reject(403, 'Unauthorized: Client does not belong to your franchisee');
		if (client.deletedAt) return reject(409, 'Client is deleted and cannot receive a warranty');

		const id = randomUUID();
		const replacedPdfs: Array<{ pdfUrl: string; pdfFileName?: string }> = [];
		const warranty = await sequelize.transaction(async (transaction) => {
			// A warranty replaced by the pre-migration process during a rolling
			// deploy has active_client_id = NULL. Treat every non-deleted warranty
			// for the client as active so the new process can replace it safely.
			const active = await Warranty.findAll({
				where: { clientId: client.id },
				transaction,
				lock: transaction.LOCK.UPDATE,
			});
			if (active.length && !replaceExisting) {
				const error = new Error('ACTIVE_WARRANTY_EXISTS');
				throw error;
			}
			// The old process soft-deletes a migrated warranty without clearing
			// active_client_id. Clear the marker across history before creating
			// the replacement so either a full or partial unique index is safe.
			await Warranty.update(
				{ activeClientId: null },
				{
					where: { clientId: client.id },
					paranoid: false,
					transaction,
				},
			);
			for (const existing of active) {
				replacedPdfs.push({ pdfUrl: existing.pdfUrl, pdfFileName: existing.pdfFileName });
				await existing.destroy({ transaction });
			}
			return Warranty.create(
				{
					id,
					clientId: client.id,
					activeClientId: client.id,
					startDate: parsedStartDate,
					durationYears: parsedDurationYears,
					pdfUrl: pdfUrlFor(id),
					pdfFileName: file.filename,
					warrantyCardNumber: warranty_card_number.trim(),
				},
				{ transaction },
			);
		});
		await Promise.all(
			replacedPdfs.map(({ pdfUrl, pdfFileName }) => removeStoredPdf(pdfUrl, pdfFileName)),
		);
		return res.status(201).json(warranty);
	} catch (error: any) {
		await removeUploadedFile(file);
		if (error?.message === 'ACTIVE_WARRANTY_EXISTS') {
			return res.status(409).json({
				error: 'An active warranty already exists. Set replace_existing to true to replace it.',
			});
		}
		if (error?.name === 'SequelizeUniqueConstraintError') {
			return res.status(409).json({
				error: 'An active warranty already exists. Please confirm replacement and try again.',
			});
		}
		console.error('Warranty upload error:', error);
		return res.status(500).json({ error: 'An error occurred during warranty upload' });
	}
};

export const getWarranties = async (req: AuthRequest, res: Response) => {
	const client = await Client.findOne({
		where: { id: req.params.client_id, franchiseeId: req.user?.franchiseeId },
	});
	if (!client) return res.status(403).json({ error: 'Unauthorized' });
	return res.json(
		await Warranty.findAll({ where: { clientId: client.id }, order: [['createdAt', 'DESC']] }),
	);
};

export const downloadWarranty = async (req: AuthRequest, res: Response) => {
	const warranty = await Warranty.findOne({
		where: { id: req.params.id },
		include: [{ model: Client, where: { franchiseeId: req.user?.franchiseeId } }],
	});
	if (!warranty) return res.status(404).json({ error: 'Warranty not found or unauthorized' });
	const filename =
		warranty.pdfFileName ||
		path.basename(new URL(warranty.pdfUrl, 'http://localhost').pathname);
	const filePath = path.join(__dirname, '../../uploads', filename);
	return res.type('application/pdf').sendFile(filePath, (error) => {
		if (error && !res.headersSent) res.status(404).json({ error: 'Warranty PDF not found' });
	});
};

export const deleteWarranty = async (req: AuthRequest, res: Response) => {
	const warranty = await Warranty.findOne({
		where: { id: req.params.id },
		include: [{ model: Client, where: { franchiseeId: req.user?.franchiseeId } }],
	});
	if (!warranty) return res.status(404).json({ error: 'Warranty not found or unauthorized' });
	const pdfUrl = warranty.pdfUrl;
	await warranty.update({ activeClientId: null });
	await warranty.destroy();
	await removeStoredPdf(pdfUrl, warranty.pdfFileName);
	return res.status(204).send();
};
