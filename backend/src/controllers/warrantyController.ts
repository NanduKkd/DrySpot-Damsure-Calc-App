import { Response } from 'express';
import { createHash, randomUUID } from 'crypto';
import fs from 'fs';
import path from 'path';
import { AuthRequest } from '../middleware/authMiddleware';
import { Warranty, Client } from '../models';
import { removeUploadedFile } from '../middleware/uploadMiddleware';
import {
	createOrReplaceConfirmedWarranty,
	deleteConfirmedWarranty,
	triggerWarrantyFileCleanup,
	validIdempotencyKey,
	warrantyRequestDigest,
	WarrantyConfirmation,
	WarrantyLifecycleError,
} from '../services/warrantyLifecycle';

const pdfUrlFor = (id: string) => `/api/warranty/${id}/download`;

const confirmationFields = [
	'confirmed_warranty_id',
	'confirmed_warranty_card_number',
	'confirmed_warranty_version',
	'irreversible_confirmation',
] as const;

const confirmationFrom = (
	body: Record<string, unknown>,
): { present: boolean; confirmation?: WarrantyConfirmation } => {
	const present = confirmationFields.some((field) =>
		Object.prototype.hasOwnProperty.call(body, field),
	);
	if (!present) return { present: false };
	const warrantyId = body.confirmed_warranty_id;
	const canonicalWarrantyId = canonicalConfirmedWarrantyUuid(warrantyId);
	const warrantyCardNumber = body.confirmed_warranty_card_number;
	const rawWarrantyVersion = body.confirmed_warranty_version;
	const warrantyVersion =
		typeof rawWarrantyVersion === 'number'
			? rawWarrantyVersion
			: typeof rawWarrantyVersion === 'string' && /^[1-9]\d*$/.test(rawWarrantyVersion)
				? Number(rawWarrantyVersion)
				: Number.NaN;
	const irreversibleConfirmation = body.irreversible_confirmation;
	if (
		!canonicalWarrantyId ||
		typeof warrantyCardNumber !== 'string' ||
		!warrantyCardNumber.trim() ||
		!Number.isSafeInteger(warrantyVersion) ||
		warrantyVersion < 1 ||
		typeof irreversibleConfirmation !== 'string' ||
		!irreversibleConfirmation.trim()
	) {
		return { present: true };
	}
	return {
		present: true,
		confirmation: {
			warrantyId: canonicalWarrantyId,
			warrantyCardNumber,
			warrantyVersion,
			irreversibleConfirmation,
		},
	};
};

function canonicalConfirmedWarrantyUuid(value: unknown) {
	if (
		typeof value !== 'string' ||
		!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value)
	) {
		return undefined;
	}
	return value.toLowerCase();
}

function canonicalWarrantyUuid(value: unknown) {
	if (
		typeof value !== 'string' ||
		!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)
	) {
		return undefined;
	}
	return value.toLowerCase();
}

const invalidConfirmationResponse = (res: Response) =>
	res.status(422).json({
		error: 'Named, version-bound irreversible confirmation is required',
		code: 'confirmation_invalid',
	});

const lifecycleErrorResponse = (res: Response, error: unknown) => {
	if (!(error instanceof WarrantyLifecycleError)) return false;
	const status =
		error.code === 'not_found'
			? 404
			: error.code === 'tenant_forbidden'
				? 403
				: error.code === 'invariant_violation'
					? 500
					: error.code === 'confirmation_required'
						? 422
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
	const confirmationEnvelope = confirmationFrom(req.body);
	const targetWarrantyId = canonicalWarrantyUuid(req.body.replacement_warranty_id);
	const replacementRequested =
		confirmationEnvelope.present ||
		Object.prototype.hasOwnProperty.call(req.body, 'replacement_warranty_id');
	if (replacementRequested && (!confirmationEnvelope.confirmation || !targetWarrantyId)) {
		await removeUploadedFile(file);
		return invalidConfirmationResponse(res);
	}
	const confirmation = confirmationEnvelope.confirmation;
	const idempotencyKey = req.get('Idempotency-Key');
	if (confirmation && !validIdempotencyKey(idempotencyKey)) {
		return reject(400, 'A valid Idempotency-Key header is required for replacement');
	}

	try {
		const pdfSha256 = createHash('sha256')
			.update(await fs.promises.readFile(file.path))
			.digest('hex');
		const id = confirmation ? targetWarrantyId! : randomUUID();
		const result = await createOrReplaceConfirmedWarranty({
			franchiseeId,
			idempotencyKey: validIdempotencyKey(idempotencyKey) ? idempotencyKey : undefined,
			confirmation,
			requestDigest: confirmation
				? warrantyRequestDigest({
						action: 'replace',
						confirmation,
						replacement: {
							clientId: client_id,
							startDate: parsedStartDate,
							durationYears: parsedDurationYears,
							warrantyCardNumber: warranty_card_number.trim(),
							pdfSha256,
							targetWarrantyId: id,
						},
					})
				: undefined,
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
	const confirmation = confirmationFrom(req.body).confirmation;
	if (!confirmation) return invalidConfirmationResponse(res);
	const idempotencyKey = req.get('Idempotency-Key');
	if (!validIdempotencyKey(idempotencyKey)) {
		return res.status(400).json({ error: 'A valid Idempotency-Key header is required' });
	}
	try {
		const requestDigest = warrantyRequestDigest({
			action: 'delete',
			confirmation,
		});
		const result = await deleteConfirmedWarranty({
			warrantyId: req.params.id,
			franchiseeId,
			idempotencyKey,
			confirmation,
			requestDigest,
		});
		triggerWarrantyFileCleanup([result.storageKey]);
		return res.status(200).json({
			status: 'deleted',
			warranty_id: result.tombstone.warrantyId,
			deletion_sequence: result.tombstone.deletionSequence.toString(),
			replayed: result.replayed,
		});
	} catch (error) {
		if (lifecycleErrorResponse(res, error)) return;
		console.error('Warranty deletion error:', error);
		return res.status(500).json({ error: 'An error occurred during warranty deletion' });
	}
};
