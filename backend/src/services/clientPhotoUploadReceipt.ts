import fs from 'fs';
import path from 'path';
import { Transaction } from 'sequelize';
import { Client, ClientPhotoUpload, sequelize } from '../models';
import { lockTenantSyncState, nextTenantSyncCursor } from './tenantSyncCursor';
import {
	photoUploadPath,
	photoUploadStagingPath,
	stagedPhotoPath,
	storedPhotoPath,
} from '../middleware/photoUploadMiddleware';

const opaqueFilename =
	/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(?:jpg|png|webp)$/i;

const isManagedFilename = (filename: string) => opaqueFilename.test(filename);
const activeReceiptOperations = new Map<string, Promise<void>>();

/**
 * PostgreSQL serialization is enforced by the tenant-state row. This small
 * in-process gate gives SQLite and the test harness the identical one-key
 * behavior; the composite database key remains the cross-process guard.
 */
export const withClientPhotoUploadReceiptLock = async <T>(
	franchiseeId: string,
	uploadId: string,
	operation: () => Promise<T>,
): Promise<T> => {
	const key = `${franchiseeId}:${uploadId}`;
	const previous = activeReceiptOperations.get(key) ?? Promise.resolve();
	let release!: () => void;
	const current = new Promise<void>((resolve) => {
		release = resolve;
	});
	activeReceiptOperations.set(key, current);
	await previous;
	try {
		return await operation();
	} finally {
		release();
		if (activeReceiptOperations.get(key) === current) activeReceiptOperations.delete(key);
	}
};

const parsePhotos = (photos: unknown): string[] => {
	if (Array.isArray(photos))
		return photos.filter((photo): photo is string => typeof photo === 'string');
	if (typeof photos !== 'string') return [];
	try {
		const parsed = JSON.parse(photos);
		return Array.isArray(parsed)
			? parsed.filter((photo): photo is string => typeof photo === 'string')
			: [];
	} catch {
		return [];
	}
};

/**
 * A crashed request can commit the client URL and receipt before the staged
 * file is published.  Never leave that URL visible when the staged file is
 * unrecoverable: compensate under the same lock order as media mutation.
 */
const compensateLockedUnpublishableReceipt = async ({
	state,
	receipt,
	client,
	transaction,
}: {
	state: Awaited<ReturnType<typeof lockTenantSyncState>>;
	receipt: ClientPhotoUpload;
	client: Client | null;
	transaction: Transaction;
}) => {
	const photos = client ? parsePhotos(client.photos) : [];
	if (client && photos.includes(receipt.canonicalUrl)) {
		const nextCursor = nextTenantSyncCursor(state.cursor);
		await client.update(
			{
				photos: JSON.stringify(photos.filter((photo) => photo !== receipt.canonicalUrl)),
				syncCursor: nextCursor.toString(),
			},
			{ transaction },
		);
		await state.update({ cursor: nextCursor.toString() }, { transaction });
	}
	await receipt.update({ status: 'deleted', deletedAt: new Date() }, { transaction });
};

export const terminalizeClientPhotoUploadReceipts = async ({
	franchiseeId,
	clientId,
	canonicalUrls,
	transaction,
}: {
	franchiseeId: string;
	clientId: string;
	canonicalUrls: string[];
	transaction: Transaction;
}) => {
	if (!canonicalUrls.length) return;
	// The caller holds the tenant sync-state lock before this conditional row
	// transition. PostgreSQL therefore serializes against finalization's own
	// tenant-state -> receipt -> client lock sequence; SQLite gets the same
	// transaction boundary. A terminal receipt can never become completed.
	await ClientPhotoUpload.update(
		{ status: 'deleted', deletedAt: new Date() },
		{
			where: {
				franchiseeId,
				clientId,
				canonicalUrl: canonicalUrls,
				deletedAt: null,
			},
			transaction,
		},
	);
};

/** Finalize a receipt committed before its staged file could be published. */
export const finalizeClientPhotoUploadReceipt = async (staleReceipt: ClientPhotoUpload) =>
	withClientPhotoUploadReceiptLock(
		staleReceipt.franchiseeId,
		staleReceipt.uploadId,
		async () =>
			sequelize.transaction(async (transaction) => {
				// Never trust the stale Sequelize instance supplied by a replay or the
				// startup scan. The fresh locks make terminal deletion win before any
				// publication state is written or a 201 is returned.
				const state = await lockTenantSyncState(staleReceipt.franchiseeId, transaction);
				const receipt = await ClientPhotoUpload.findOne({
					where: {
						franchiseeId: staleReceipt.franchiseeId,
						uploadId: staleReceipt.uploadId,
					},
					transaction,
					lock: transaction.LOCK.UPDATE,
				});
				if (!receipt || receipt.status === 'deleted' || receipt.deletedAt != null) {
					return 'deleted' as const;
				}
				const client = await Client.findOne({
					where: { id: receipt.clientId, franchiseeId: receipt.franchiseeId },
					transaction,
					lock: transaction.LOCK.UPDATE,
				});
				if (!client || !parsePhotos(client.photos).includes(receipt.canonicalUrl)) {
					await receipt.update({ status: 'deleted', deletedAt: new Date() }, { transaction });
					return 'deleted' as const;
				}

				const filename = receipt.storageKey;
				const finalPath = path.resolve(storedPhotoPath(filename));
				const stagedPath = path.resolve(stagedPhotoPath(filename));
				const unsafePath =
					!isManagedFilename(filename) ||
					path.dirname(finalPath) !== photoUploadPath ||
					path.dirname(stagedPath) !== photoUploadStagingPath;
				if (unsafePath) {
					await compensateLockedUnpublishableReceipt({
						state,
						receipt,
						client,
						transaction,
					});
					return 'deleted' as const;
				}
				try {
					if (!fs.existsSync(finalPath) && fs.existsSync(stagedPath)) {
						await fs.promises.mkdir(photoUploadPath, { recursive: true });
						await fs.promises.rename(stagedPath, finalPath);
					}
				} catch {
					await compensateLockedUnpublishableReceipt({
						state,
						receipt,
						client,
						transaction,
					});
					return 'deleted' as const;
				}
				if (!fs.existsSync(finalPath)) {
					await compensateLockedUnpublishableReceipt({
						state,
						receipt,
						client,
						transaction,
					});
					return 'deleted' as const;
				}
				if (receipt.status === 'staged') {
					const [changed] = await ClientPhotoUpload.update(
						{ status: 'completed' },
						{
							where: {
								franchiseeId: receipt.franchiseeId,
								uploadId: receipt.uploadId,
								status: 'staged',
								deletedAt: null,
							},
							transaction,
						},
					);
					if (changed !== 1) return 'deleted' as const;
				}
				return 'completed' as const;
			}),
	);

/**
 * Startup reconciliation repairs a commit-before-response interruption and
 * removes only unclaimed, aged staging files.  It never scans or deletes
 * published assets, and the age grace prevents a live multipart parse from
 * being mistaken for a crash orphan.
 */
export const reconcileStagedClientPhotoUploads = async ({
	minimumAgeMs = 5 * 60 * 1000,
	now = Date.now(),
}: {
	minimumAgeMs?: number;
	now?: number;
} = {}) => {
	await fs.promises.mkdir(photoUploadStagingPath, { recursive: true });
	const staged = await ClientPhotoUpload.findAll({ where: { status: 'staged' } });
	for (const receipt of staged) await finalizeClientPhotoUploadReceipt(receipt);
	const claimed = new Set(
		(
			await ClientPhotoUpload.findAll({
				attributes: ['storageKey'],
				where: { status: 'staged' },
			})
		).map((receipt) => receipt.storageKey),
	);
	for (const entry of await fs.promises.readdir(photoUploadStagingPath, {
		withFileTypes: true,
	})) {
		if (!entry.isFile() || !isManagedFilename(entry.name) || claimed.has(entry.name)) continue;
		const file = stagedPhotoPath(entry.name);
		const stat = await fs.promises.stat(file);
		if (now - stat.mtimeMs >= minimumAgeMs) await fs.promises.unlink(file);
	}
};
