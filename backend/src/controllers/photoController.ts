import { Response } from 'express';
import fs from 'fs';
import path from 'path';
import { createHash } from 'crypto';
import { AuthRequest } from '../middleware/authMiddleware';
import { Client, ClientPhotoUpload, sequelize } from '../models';
import { removeUploadedPhoto } from '../middleware/photoUploadMiddleware';
import {
	queueManagedFileCleanup,
	reconcileManagedFileCleanupByStorageKeys,
} from '../services/managedFileCleanup';
import { MAX_CLIENT_PHOTOS, serializeLwwRecord } from '../services/lwwSync';
import { lockTenantSyncState, nextTenantSyncCursor } from '../services/tenantSyncCursor';
import {
	finalizeClientPhotoUploadReceipt,
	terminalizeClientPhotoUploadReceipts,
	withClientPhotoUploadReceiptLock,
} from '../services/clientPhotoUploadReceipt';

const uploadsDirectory = path.join(__dirname, '../../uploads');
const opaqueFilename =
	/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(?:jpg|png|webp)$/i;
const uuidV4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

export const photoPath = (clientId: string, filename: string) =>
	`/api/photos/client/${clientId}/${filename}`;

const parsePhotos = (photos: unknown): string[] => {
	if (Array.isArray(photos))
		return photos.filter((value): value is string => typeof value === 'string');
	if (typeof photos !== 'string') return [];
	try {
		const parsed = JSON.parse(photos);
		return Array.isArray(parsed)
			? parsed.filter((value): value is string => typeof value === 'string')
			: [];
	} catch {
		return [];
	}
};

const validImageContent = async (file: Express.Multer.File) => {
	const bytes = await fs.promises.readFile(file.path);
	const extension = path.extname(file.originalname).toLowerCase();
	const jpeg = bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
	const png =
		bytes.length >= 8 &&
		bytes.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]));
	const webp =
		bytes.length >= 12 &&
		bytes.subarray(0, 4).toString() === 'RIFF' &&
		bytes.subarray(8, 12).toString() === 'WEBP';
	return (
		(jpeg && ['.jpg', '.jpeg'].includes(extension)) ||
		(png && extension === '.png') ||
		(webp && extension === '.webp')
	);
};

const fileSha256 = async (file: Express.Multer.File) =>
	createHash('sha256')
		.update(await fs.promises.readFile(file.path))
		.digest('hex');

const ownedActiveClient = async (clientId: string, franchiseeId?: string) =>
	Client.findOne({ where: { id: clientId, franchiseeId } });

const safeFilePath = (filename: string) => {
	if (!opaqueFilename.test(filename)) return null;
	const filePath = path.resolve(uploadsDirectory, filename);
	return path.dirname(filePath) === uploadsDirectory ? filePath : null;
};

export const uploadPhoto = async (req: AuthRequest, res: Response) => {
	const file = req.file;
	if (!file) return res.status(400).json({ error: 'No image file uploaded' });
	const uploadId = req.get('Idempotency-Key')?.trim().toLowerCase();
	if (!uploadId || !uuidV4.test(uploadId)) {
		await removeUploadedPhoto(file);
		return res.status(400).json({
			error: {
				code: 'invalid_idempotency_key',
				message: 'A valid upload id is required.',
			},
		});
	}
	if (!(await validImageContent(file))) {
		await removeUploadedPhoto(file);
		return res
			.status(400)
			.json({ error: 'Image content does not match its JPEG, PNG, or WebP extension' });
	}

	const franchiseeId = req.user?.franchiseeId;
	if (!franchiseeId) {
		await removeUploadedPhoto(file);
		return res.status(401).json({ error: 'Unauthorized' });
	}
	const digest = await fileSha256(file);
	const suppliedDigest = req.get('X-Photo-SHA256')?.trim().toLowerCase();
	if (!suppliedDigest || !/^[0-9a-f]{64}$/.test(suppliedDigest) || suppliedDigest !== digest) {
		await removeUploadedPhoto(file);
		return res.status(400).json({
			error: {
				code: 'invalid_photo_digest',
				message: 'The uploaded photo could not be verified.',
			},
		});
	}
	const canonicalPath = photoPath(req.params.client_id, file.filename);
	let receiptCommitted = false;
	try {
		const result = await withClientPhotoUploadReceiptLock(franchiseeId, uploadId, () =>
			sequelize.transaction(async (transaction) => {
				const state = await lockTenantSyncState(franchiseeId, transaction);
				// The shared tenant row is acquired first everywhere that changes sync
				// visibility. Receipt before client then gives duplicate requests one
				// deterministic lock order on PostgreSQL as well as SQLite.
				const receipt = await ClientPhotoUpload.findOne({
					where: { franchiseeId, uploadId },
					transaction,
					lock: transaction.LOCK.UPDATE,
				});
				if (receipt) {
					if (
						receipt.clientId !== req.params.client_id ||
						receipt.fileSha256 !== digest
					) {
						return { kind: 'conflict' as const };
					}
					if (receipt.deletedAt != null || receipt.status === 'deleted') {
						return { kind: 'deleted' as const };
					}
					return {
						kind: 'replay' as const,
						url: receipt.canonicalUrl,
						// SQLite can hydrate BIGINT as a number; callers must receive the
						// same canonical decimal response shape as a newly-created upload.
						cursor: String(receipt.responseCursor),
						receipt,
					};
				}
				const client = await Client.findOne({
					where: { id: req.params.client_id, franchiseeId },
					transaction,
					lock: transaction.LOCK.UPDATE,
				});
				if (!client) return { kind: 'unauthorized' as const };
				const photos = parsePhotos(client.photos);
				if (photos.length >= MAX_CLIENT_PHOTOS) {
					throw new Error('client_photo_limit');
				}
				const nextCursor = nextTenantSyncCursor(state.cursor);
				await client.update(
					{
						photos: JSON.stringify([...new Set([...photos, canonicalPath])]),
						syncCursor: nextCursor.toString(),
					},
					{ transaction },
				);
				await state.update({ cursor: nextCursor.toString() }, { transaction });
				const createdReceipt = await ClientPhotoUpload.create(
					{
						franchiseeId,
						uploadId,
						clientId: req.params.client_id,
						fileSha256: digest,
						canonicalUrl: canonicalPath,
						storageKey: file.filename,
						responseCursor: nextCursor.toString(),
						status: 'staged',
					},
					{ transaction },
				);
				return {
					kind: 'created' as const,
					url: canonicalPath,
					cursor: nextCursor.toString(),
					record: serializeLwwRecord('clients', client),
					receipt: createdReceipt,
				};
			}),
		);
		receiptCommitted = result.kind === 'created';
		if (result.kind === 'unauthorized') {
			await removeUploadedPhoto(file);
			return res
				.status(403)
				.json({ error: 'Unauthorized: Client does not belong to your franchisee' });
		}
		if (result.kind === 'conflict') {
			await removeUploadedPhoto(file);
			return res.status(409).json({
				error: {
					code: 'idempotency_conflict',
					message: 'This upload id is already bound to different photo data.',
				},
			});
		}
		if (result.kind === 'deleted') {
			await removeUploadedPhoto(file);
			return res.status(410).json({
				error: {
					code: 'uploaded_asset_deleted',
					message: 'The previously uploaded photo was deleted.',
				},
			});
		}
		if (result.kind === 'replay') {
			const publication = await finalizeClientPhotoUploadReceipt(result.receipt);
			await removeUploadedPhoto(file);
			if (publication === 'deleted') {
				return res.status(410).json({
					error: {
						code: 'uploaded_asset_deleted',
						message: 'The previously uploaded photo was deleted.',
					},
				});
			}
			return res.status(201).json({
				url: result.url,
				response_cursor: result.cursor,
			});
		}
		const publication = await finalizeClientPhotoUploadReceipt(result.receipt);
		if (publication === 'deleted') {
			return res.status(410).json({
				error: {
					code: 'uploaded_asset_deleted',
					message: 'The uploaded photo was not available after recovery.',
				},
			});
		}
		return res.status(201).json({
			url: result.url,
			response_cursor: result.cursor,
			authoritative: result.record,
		});
	} catch (error) {
		if (!receiptCommitted) await removeUploadedPhoto(file);
		if (error instanceof Error && error.message === 'client_photo_limit') {
			return res.status(409).json({ error: 'A client may store at most 100 photos' });
		}
		console.error('Photo upload error:', error);
		return res.status(500).json({ error: 'An error occurred during photo upload' });
	}
};

export const downloadPhoto = async (req: AuthRequest, res: Response) => {
	const { client_id: clientId, filename } = req.params;
	const client = await ownedActiveClient(clientId, req.user?.franchiseeId);
	const canonicalPath = photoPath(clientId, filename);
	const filePath = safeFilePath(filename);
	if (!client || !filePath || !parsePhotos(client.photos).includes(canonicalPath)) {
		return res.status(404).json({ error: 'Photo not found or unauthorized' });
	}
	return res.sendFile(filePath, (error) => {
		if (error && !res.headersSent) res.status(404).json({ error: 'Photo file not found' });
	});
};

export const deletePhoto = async (req: AuthRequest, res: Response) => {
	const { client_id: clientId, filename } = req.params;
	const canonicalPath = photoPath(clientId, filename);
	const filePath = safeFilePath(filename);
	if (!filePath) return res.status(404).json({ error: 'Photo not found or unauthorized' });

	const transaction = await sequelize.transaction();
	let committed = false;
	try {
		const franchiseeId = req.user?.franchiseeId;
		if (!franchiseeId) {
			await transaction.rollback();
			return res.status(401).json({ error: 'Unauthorized' });
		}
		const state = await lockTenantSyncState(franchiseeId, transaction);
		// Establish that this canonical URL is currently owned before changing a
		// receipt. The locked read below revalidates after the receipt lock.
		const preview = await Client.findOne({
			where: { id: clientId, franchiseeId },
			transaction,
		});
		if (!preview || !parsePhotos(preview.photos).includes(canonicalPath)) {
			await transaction.rollback();
			return res.status(404).json({ error: 'Photo not found or unauthorized' });
		}
		await terminalizeClientPhotoUploadReceipts({
			franchiseeId,
			clientId,
			canonicalUrls: [canonicalPath],
			transaction,
		});
		const client = await Client.findOne({
			where: { id: clientId, franchiseeId: req.user?.franchiseeId },
			transaction,
			lock: transaction.LOCK.UPDATE,
		});
		const photos = client && parsePhotos(client.photos);
		if (!client || !photos?.includes(canonicalPath)) {
			await transaction.rollback();
			return res.status(404).json({ error: 'Photo not found or unauthorized' });
		}
		const nextCursor = nextTenantSyncCursor(state.cursor);
		await client.update(
			{
				photos: JSON.stringify(photos.filter((photo) => photo !== canonicalPath)),
				syncCursor: nextCursor.toString(),
			},
			{ transaction },
		);
		await queueManagedFileCleanup('photo', filename, transaction);
		await state.update({ cursor: nextCursor.toString() }, { transaction });
		await transaction.commit();
		committed = true;
		// Metadata deletion remains authoritative; cleanup failures are retained
		// by the transactionally-created outbox row for an operator retry.
		await reconcileManagedFileCleanupByStorageKeys([filename], 1);
		return res.status(204).send();
	} catch (error) {
		if (!committed) await transaction.rollback();
		console.error('Photo deletion error:', error);
		return res.status(500).json({ error: 'An error occurred during photo deletion' });
	}
};
