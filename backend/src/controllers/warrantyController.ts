import { Response } from 'express';
import { randomUUID } from 'crypto';
import path from 'path';
import { AuthRequest } from '../middleware/authMiddleware';
import { Warranty, Client } from '../models';
import { removeUploadedFile } from '../middleware/uploadMiddleware';
import {
	createOrReplaceConfirmedWarranty,
	deleteConfirmedWarranty,
	triggerWarrantyFileCleanup,
	validIdempotencyKey,
	WarrantyConfirmation,
	WarrantyLifecycleError,
} from '../services/warrantyLifecycle';

const pdfUrlFor = (id: string) => `/api/warranty/${id}/download`;

const confirmationFrom = (body: Record<string, unknown>): WarrantyConfirmation | undefined => {
	const warrantyId = body.confirmed_warranty_id;
	const warrantyCardNumber = body.confirmed_warranty_card_number;
	const warrantyVersion = Number(body.confirmed_warranty_version);
	const irreversibleConfirmation = body.irreversible_confirmation;
	if (
		typeof warrantyId !== 'string' ||
		typeof warrantyCardNumber !== 'string' ||
		!Number.isInteger(warrantyVersion) ||
		warrantyVersion < 1 ||
		typeof irreversibleConfirmation !== 'string'
	) {
		return undefined;
	}
	return {
		warrantyId,
		warrantyCardNumber,
		warrantyVersion,
		irreversibleConfirmation,
	};
};

const lifecycleErrorResponse = (res: Response, error: unknown) => {
	if (!(error instanceof WarrantyLifecycleError)) return false;
	const status =
		error.code === 'not_found'
			? 404
			: error.code === 'tenant_forbidden'
				? 403
				: error.code === 'invariant_violation'
					? 500
					: 409;
	res.status(status).json({ error: error.message, code: error.code });
	return true;
};

export const uploadWarranty = async (req: AuthRequest, res: Response) => {
	const { client_id, start_date, duration_years, warranty_card_number } = req.body;
	const franchiseeId = req.user?.franchiseeId;
	const file = req.file;
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
	const confirmation = confirmationFrom(req.body);
	const idempotencyKey = req.get('Idempotency-Key');
	if (confirmation && !validIdempotencyKey(idempotencyKey)) {
		return reject(400, 'A valid Idempotency-Key header is required for replacement');
	}

	try {
		const id = randomUUID();
		const result = await createOrReplaceConfirmedWarranty({
			franchiseeId,
			idempotencyKey: validIdempotencyKey(idempotencyKey) ? idempotencyKey : undefined,
			confirmation,
			values: {
				id,
				clientId: client_id,
				startDate: parsedStartDate,
				durationYears: parsedDurationYears,
				pdfUrl: pdfUrlFor(id),
				pdfFileName: file.filename,
				warrantyCardNumber: warranty_card_number.trim(),
			},
		});
		if (result.replayed) await removeUploadedFile(file);
		triggerWarrantyFileCleanup(result.cleanupStorageKeys);
		return res.status(201).json({
			...result.warranty.toJSON(),
			replayed: result.replayed,
		});
	} catch (error: any) {
		await removeUploadedFile(file);
		if (lifecycleErrorResponse(res, error)) return;
		if (error?.name === 'SequelizeUniqueConstraintError') {
			return res.status(409).json({
				error: 'An active warranty already exists. Refresh and confirm the exact warranty before replacing it.',
				code: 'active_warranty_exists',
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
	const franchiseeId = req.user?.franchiseeId;
	if (!franchiseeId) return res.status(401).json({ error: 'Unauthorized' });
	const idempotencyKey = req.get('Idempotency-Key');
	if (!validIdempotencyKey(idempotencyKey)) {
		return res.status(400).json({ error: 'A valid Idempotency-Key header is required' });
	}
	const confirmation = confirmationFrom(req.body);
	if (!confirmation || confirmation.warrantyId !== req.params.id) {
		return res.status(400).json({
			error: 'Named, version-bound irreversible confirmation is required',
		});
	}
	try {
		const result = await deleteConfirmedWarranty({
			warrantyId: req.params.id,
			franchiseeId,
			idempotencyKey,
			confirmation,
		});
		triggerWarrantyFileCleanup([result.storageKey]);
		return res.status(204).send();
	} catch (error) {
		if (lifecycleErrorResponse(res, error)) return;
		console.error('Warranty deletion error:', error);
		return res.status(500).json({ error: 'An error occurred during warranty deletion' });
	}
};
