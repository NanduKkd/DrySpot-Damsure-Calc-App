import { createHash } from 'crypto';
import { Op, QueryTypes, Transaction } from 'sequelize';
import {
	Client,
	Warranty,
	WarrantyDeletionSequence,
	WarrantyDeletionTombstone,
	sequelize,
} from '../models';
import {
	queueManagedFileCleanup,
	reconcileManagedFileCleanupByStorageKeys,
} from './managedFileCleanup';
import { lockTenantSyncState, nextTenantSyncCursor } from './tenantSyncCursor';

export type WarrantyConfirmation = {
	warrantyId: string;
	warrantyCardNumber: string;
	warrantyVersion: number;
	irreversibleConfirmation: string;
};

export type WarrantyIdempotencyAction = 'delete' | 'replace';

export const warrantyReplacementConflict = {
	code: 'warranty_conflict',
	message: 'Warranty replacement could not be completed. Retry or contact support.',
} as const;

export type NewWarrantyValues = {
	id: string;
	clientId: string;
	warrantyCardNumber: string;
	startDate: Date;
	durationYears: number;
	pdfUrl: string;
	pdfFileName: string;
};

export const warrantyRequestDigest = ({
	action,
	confirmation,
	replacement,
}: {
	action: WarrantyIdempotencyAction;
	confirmation: WarrantyConfirmation;
	replacement?: {
		clientId: string;
		warrantyCardNumber: string;
		startDate: Date;
		durationYears: number;
		pdfSha256: string;
		targetWarrantyId: string;
	};
}) =>
	createHash('sha256')
		.update(
			JSON.stringify({
				action,
				source: {
					warrantyId: confirmation.warrantyId,
					warrantyVersion: confirmation.warrantyVersion,
					warrantyCardNumber: confirmation.warrantyCardNumber,
					irreversibleConfirmation: confirmation.irreversibleConfirmation,
				},
				...(replacement
					? {
							replacement: {
								clientId: replacement.clientId,
								warrantyCardNumber: replacement.warrantyCardNumber,
								startDate: replacement.startDate.toISOString(),
								durationYears: replacement.durationYears,
								pdfSha256: replacement.pdfSha256,
								targetWarrantyId: replacement.targetWarrantyId,
							},
						}
					: {}),
			}),
		)
		.digest('hex');

export class WarrantyLifecycleError extends Error {
	constructor(
		public readonly code:
			| 'not_found'
			| 'tenant_forbidden'
			| 'client_deleted'
			| 'active_warranty_exists'
			| 'stale_confirmation'
			| 'confirmation_required'
			| 'idempotency_conflict'
			| 'warranty_conflict'
			| 'warranty_id_reserved'
			| 'invariant_violation',
		message: string,
	) {
		super(message);
	}
}

export const irreversibleWarrantyConfirmation = (warrantyCardNumber: string) =>
	`PERMANENTLY DELETE WARRANTY ${warrantyCardNumber}`;

export const validIdempotencyKey = (value: unknown): value is string =>
	typeof value === 'string' && /^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$/.test(value);

const assertConfirmation = (warranty: Warranty, confirmation: WarrantyConfirmation | undefined) => {
	if (!confirmation) {
		throw new WarrantyLifecycleError(
			'confirmation_required',
			'Named, version-bound irreversible confirmation is required.',
		);
	}
	const isCurrent =
		confirmation.warrantyId === warranty.id &&
		confirmation.warrantyCardNumber === warranty.warrantyCardNumber &&
		confirmation.warrantyVersion === warranty.version &&
		confirmation.irreversibleConfirmation ===
			irreversibleWarrantyConfirmation(warranty.warrantyCardNumber);
	if (!isCurrent) {
		throw new WarrantyLifecycleError(
			'stale_confirmation',
			'The warranty changed after confirmation. Refresh and confirm the current warranty.',
		);
	}
};

const allocateDeletionSequence = async (transaction: Transaction) => {
	const [sequence] = await WarrantyDeletionSequence.findOrCreate({
		where: { id: 1 },
		defaults: { id: 1, lastValue: '0' },
		transaction,
	});
	await sequence.reload({ transaction, lock: transaction.LOCK.UPDATE });
	const nextValue = BigInt(sequence.lastValue) + 1n;
	await sequence.update({ lastValue: nextValue.toString() }, { transaction });
	return nextValue.toString();
};

const findIdempotencyReplay = (
	franchiseeId: string,
	idempotencyKey: string,
	transaction: Transaction,
) =>
	WarrantyDeletionTombstone.findOne({
		where: { franchiseeId, idempotencyKey },
		transaction,
		lock: transaction.LOCK.UPDATE,
	});

const assertIdempotencyIdentity = ({
	tombstone,
	action,
	requestDigest,
	warrantyId,
}: {
	tombstone: WarrantyDeletionTombstone;
	action: WarrantyIdempotencyAction;
	requestDigest: string;
	warrantyId: string;
}) => {
	if (
		tombstone.warrantyId !== warrantyId ||
		tombstone.idempotencyAction !== action ||
		tombstone.requestDigest !== requestDigest
	) {
		throw new WarrantyLifecycleError(
			'idempotency_conflict',
			'The idempotency key was already used for a different warranty mutation.',
		);
	}
};

export const findReservedWarrantyId = (warrantyId: string, transaction?: Transaction) =>
	WarrantyDeletionTombstone.findByPk(warrantyId, {
		transaction,
		...(transaction ? { lock: transaction.LOCK.UPDATE } : {}),
	});

const lockWarrantyUuidReservation = async (warrantyId: string, transaction: Transaction) => {
	const lockClause = sequelize.getDialect() === 'postgres' ? ' FOR UPDATE' : '';
	const reservations = await sequelize.query(
		`SELECT warranty_id
		 FROM warranty_uuid_reservations
		 WHERE warranty_id = :warrantyId${lockClause}`,
		{
			replacements: { warrantyId },
			type: QueryTypes.SELECT,
			transaction,
		},
	);
	return reservations.length > 0;
};

const createWarrantyTombstone = async ({
	warrantyId,
	franchiseeId,
	idempotencyKey,
	idempotencyAction,
	requestDigest,
	replacementWarrantyId,
	deletedAt,
	transaction,
}: {
	warrantyId: string;
	franchiseeId: string;
	idempotencyKey?: string | null;
	idempotencyAction?: WarrantyIdempotencyAction | null;
	requestDigest?: string | null;
	replacementWarrantyId?: string | null;
	deletedAt?: Date;
	transaction: Transaction;
}) => {
	const existing = await findReservedWarrantyId(warrantyId, transaction);
	if (existing) {
		if (existing.franchiseeId !== franchiseeId) {
			throw new WarrantyLifecycleError(
				'warranty_id_reserved',
				'The warranty UUID is permanently reserved.',
			);
		}
		return existing;
	}

	if (idempotencyKey) {
		const replay = await findIdempotencyReplay(franchiseeId, idempotencyKey, transaction);
		if (replay && replay.warrantyId !== warrantyId) {
			throw new WarrantyLifecycleError(
				'idempotency_conflict',
				'The idempotency key was already used for another warranty mutation.',
			);
		}
	}

	return WarrantyDeletionTombstone.create(
		{
			warrantyId,
			franchiseeId,
			deletionSequence: await allocateDeletionSequence(transaction),
			idempotencyKey: idempotencyKey ?? null,
			idempotencyAction: idempotencyAction ?? null,
			requestDigest: requestDigest ?? null,
			replacementWarrantyId: replacementWarrantyId ?? null,
			deletedAt: deletedAt ?? new Date(),
		},
		{ transaction },
	);
};

const tombstoneAndHardDelete = async ({
	warranty,
	franchiseeId,
	idempotencyKey,
	idempotencyAction,
	requestDigest,
	replacementWarrantyId,
	transaction,
}: {
	warranty: Warranty;
	franchiseeId: string;
	idempotencyKey?: string | null;
	idempotencyAction?: WarrantyIdempotencyAction | null;
	requestDigest?: string | null;
	replacementWarrantyId?: string | null;
	transaction: Transaction;
}) => {
	const tombstone = await createWarrantyTombstone({
		warrantyId: warranty.id,
		franchiseeId,
		idempotencyKey,
		idempotencyAction,
		requestDigest,
		replacementWarrantyId,
		transaction,
	});
	await queueManagedFileCleanup('pdf', warranty.pdfFileName, transaction);
	await warranty.destroy({ force: true, transaction });
	return tombstone;
};

export const backfillLegacySoftDeletedWarranties = async ({
	franchiseeId,
	clientId,
	transaction,
}: {
	franchiseeId: string;
	clientId?: string;
	transaction: Transaction;
}) => {
	const ownedClients = await Client.findAll({
		where: {
			franchiseeId,
			...(clientId ? { id: clientId } : {}),
		},
		attributes: ['id'],
		paranoid: false,
		transaction,
	});
	if (!ownedClients.length) return [] as string[];
	const where = {
		clientId: { [Op.in]: ownedClients.map((client) => client.id) },
		deletedAt: { [Op.ne]: null },
	};
	const legacyIds = await Warranty.findAll({
		where,
		attributes: ['id'],
		paranoid: false,
		transaction,
	});
	for (const legacyId of legacyIds.map(({ id }) => id).sort()) {
		await lockWarrantyUuidReservation(legacyId, transaction);
	}
	const warranties = await Warranty.findAll({
		where,
		paranoid: false,
		transaction,
		lock: transaction.LOCK.UPDATE,
	});
	const storageKeys: string[] = [];
	for (const warranty of warranties) {
		if (warranty.pdfFileName) storageKeys.push(warranty.pdfFileName);
		await tombstoneAndHardDelete({
			warranty,
			franchiseeId,
			transaction,
		});
	}
	return storageKeys;
};

const findOwnedClientForUpdate = async (
	clientId: string,
	franchiseeId: string,
	transaction: Transaction,
) => {
	const client = await Client.findByPk(clientId, {
		paranoid: false,
		transaction,
		lock: transaction.LOCK.UPDATE,
	});
	if (!client) {
		throw new WarrantyLifecycleError(
			'not_found',
			'Client not found. Please sync client data and try again',
		);
	}
	if (client.franchiseeId !== franchiseeId) {
		throw new WarrantyLifecycleError(
			'tenant_forbidden',
			'Unauthorized: Client does not belong to your franchisee',
		);
	}
	if (client.deletedAt) {
		throw new WarrantyLifecycleError(
			'client_deleted',
			'A deleted client cannot receive or delete a warranty.',
		);
	}
	return client;
};

export const deleteConfirmedWarranty = async ({
	warrantyId,
	franchiseeId,
	idempotencyKey,
	confirmation,
	requestDigest,
}: {
	warrantyId: string;
	franchiseeId: string;
	idempotencyKey: string;
	confirmation: WarrantyConfirmation;
	requestDigest: string;
}) =>
	sequelize.transaction(async (transaction) => {
		const tenantState = await lockTenantSyncState(franchiseeId, transaction);
		const replay = await findIdempotencyReplay(franchiseeId, idempotencyKey, transaction);
		if (replay) {
			assertIdempotencyIdentity({
				tombstone: replay,
				action: 'delete',
				requestDigest,
				warrantyId,
			});
			return { storageKey: null, replayed: true, tombstone: replay };
		}

		const reserved = await findReservedWarrantyId(warrantyId, transaction);
		if (reserved) {
			if (reserved.franchiseeId !== franchiseeId) {
				throw new WarrantyLifecycleError('not_found', 'Warranty not found.');
			}
			throw new WarrantyLifecycleError(
				'stale_confirmation',
				'The confirmed warranty is no longer active.',
			);
		}

		const candidate = await Warranty.findByPk(warrantyId, {
			paranoid: false,
			transaction,
			attributes: ['id', 'clientId', 'deletedAt'],
		});
		if (!candidate) {
			throw new WarrantyLifecycleError('not_found', 'Warranty not found.');
		}
		const client = await Client.findByPk(candidate.clientId, {
			paranoid: false,
			transaction,
			lock: transaction.LOCK.UPDATE,
		});
		if (!client || client.franchiseeId !== franchiseeId) {
			throw new WarrantyLifecycleError('not_found', 'Warranty not found.');
		}
		if (client.deletedAt) {
			throw new WarrantyLifecycleError(
				'client_deleted',
				'A deleted client cannot receive or delete a warranty.',
			);
		}
		// Production rollout keeps the UUID guard active for old writers. Lock
		// its reservation before the live row so an old INSERT cannot invert the
		// tombstone transaction's lock order.
		await lockWarrantyUuidReservation(warrantyId, transaction);
		if (candidate.deletedAt) {
			const legacy = await Warranty.findByPk(warrantyId, {
				paranoid: false,
				transaction,
				lock: transaction.LOCK.UPDATE,
			});
			if (!legacy) {
				throw new WarrantyLifecycleError('not_found', 'Warranty not found.');
			}
			assertConfirmation(legacy, confirmation);
			const storageKey = legacy.pdfFileName;
			const tombstone = await tombstoneAndHardDelete({
				warranty: legacy,
				franchiseeId,
				idempotencyKey,
				idempotencyAction: 'delete',
				requestDigest,
				transaction,
			});
			const cursor = nextTenantSyncCursor(tenantState.cursor);
			await tenantState.update({ cursor: cursor.toString() }, { transaction });
			return { storageKey, replayed: false, tombstone };
		}
		const warranty = await Warranty.findByPk(warrantyId, {
			transaction,
			lock: transaction.LOCK.UPDATE,
		});
		if (!warranty) {
			throw new WarrantyLifecycleError(
				'stale_confirmation',
				'The confirmed warranty is no longer active.',
			);
		}
		assertConfirmation(warranty, confirmation);
		const storageKey = warranty.pdfFileName;
		const tombstone = await tombstoneAndHardDelete({
			warranty,
			franchiseeId,
			idempotencyKey,
			idempotencyAction: 'delete',
			requestDigest,
			transaction,
		});
		const cursor = nextTenantSyncCursor(tenantState.cursor);
		await tenantState.update({ cursor: cursor.toString() }, { transaction });
		return { storageKey, replayed: false, tombstone };
	});

export const createOrReplaceConfirmedWarranty = async ({
	franchiseeId,
	values,
	idempotencyKey,
	confirmation,
	requestDigest,
}: {
	franchiseeId: string;
	values: NewWarrantyValues;
	idempotencyKey?: string;
	confirmation?: WarrantyConfirmation;
	requestDigest?: string;
}) =>
	sequelize.transaction(async (transaction) => {
		const tenantState = await lockTenantSyncState(franchiseeId, transaction);
		if (confirmation && idempotencyKey && requestDigest) {
			const keyedReplay = await findIdempotencyReplay(
				franchiseeId,
				idempotencyKey,
				transaction,
			);
			if (keyedReplay) {
				// Bind the key before trusting any changed request parent. A replay
				// with a different client or other business field is a 409 identity
				// conflict, not a fresh authorization/not-found probe.
				assertIdempotencyIdentity({
					tombstone: keyedReplay,
					action: 'replace',
					requestDigest,
					warrantyId: confirmation.warrantyId,
				});
			}
		}
		await findOwnedClientForUpdate(values.clientId, franchiseeId, transaction);
		const legacyStorageKeys = await backfillLegacySoftDeletedWarranties({
			franchiseeId,
			clientId: values.clientId,
			transaction,
		});

		if (confirmation && idempotencyKey && requestDigest) {
			const keyedReplay = await findIdempotencyReplay(
				franchiseeId,
				idempotencyKey,
				transaction,
			);
			if (keyedReplay) {
				assertIdempotencyIdentity({
					tombstone: keyedReplay,
					action: 'replace',
					requestDigest,
					warrantyId: confirmation.warrantyId,
				});
				if (!keyedReplay.replacementWarrantyId) {
					throw new WarrantyLifecycleError(
						'idempotency_conflict',
						'The original replacement result is no longer available.',
					);
				}
				const replacement = await Warranty.findOne({
					where: {
						id: keyedReplay.replacementWarrantyId,
						clientId: values.clientId,
					},
					transaction,
					lock: transaction.LOCK.UPDATE,
				});
				if (!replacement) {
					throw new WarrantyLifecycleError(
						'idempotency_conflict',
						'The original replacement result is no longer available.',
					);
				}
				return {
					warranty: replacement,
					cleanupStorageKeys: legacyStorageKeys,
					replayed: true,
				};
			}

			const replay = await findReservedWarrantyId(confirmation.warrantyId, transaction);
			if (replay) {
				if (
					replay.franchiseeId !== franchiseeId ||
					replay.idempotencyKey !== idempotencyKey ||
					!replay.replacementWarrantyId
				) {
					throw new WarrantyLifecycleError(
						'stale_confirmation',
						'The confirmed warranty is no longer the active warranty.',
					);
				}
				assertIdempotencyIdentity({
					tombstone: replay,
					action: 'replace',
					requestDigest,
					warrantyId: confirmation.warrantyId,
				});
				const replacement = await Warranty.findOne({
					where: {
						id: replay.replacementWarrantyId,
						clientId: values.clientId,
					},
					transaction,
					lock: transaction.LOCK.UPDATE,
				});
				if (!replacement) {
					throw new WarrantyLifecycleError(
						'idempotency_conflict',
						'The original replacement result is no longer available.',
					);
				}
				return {
					warranty: replacement,
					cleanupStorageKeys: legacyStorageKeys,
					replayed: true,
				};
			}
		}

		if (await lockWarrantyUuidReservation(values.id, transaction)) {
			throw new WarrantyLifecycleError(
				warrantyReplacementConflict.code,
				warrantyReplacementConflict.message,
			);
		}

		const activeIds = await Warranty.findAll({
			where: { clientId: values.clientId },
			attributes: ['id'],
			transaction,
		});
		for (const activeId of activeIds.map(({ id }) => id).sort()) {
			await lockWarrantyUuidReservation(activeId, transaction);
		}
		const active = await Warranty.findAll({
			where: { clientId: values.clientId },
			transaction,
			lock: transaction.LOCK.UPDATE,
		});
		if (active.length > 1) {
			throw new WarrantyLifecycleError(
				'invariant_violation',
				'More than one active warranty exists for the client.',
			);
		}
		if (!active.length) {
			if (confirmation) {
				throw new WarrantyLifecycleError(
					'stale_confirmation',
					'The confirmed warranty is no longer the active warranty.',
				);
			}
			const cursor = nextTenantSyncCursor(tenantState.cursor);
			const warranty = await Warranty.create(
				{
					...values,
					version: 1,
					activeClientId: values.clientId,
					syncCursor: cursor.toString(),
				},
				{ transaction },
			);
			await tenantState.update({ cursor: cursor.toString() }, { transaction });
			return {
				warranty,
				cleanupStorageKeys: legacyStorageKeys,
				replayed: false,
			};
		}

		if (!idempotencyKey) {
			throw new WarrantyLifecycleError(
				'confirmation_required',
				'Replacement requires an idempotency key and named, version-bound confirmation.',
			);
		}
		if (!requestDigest) {
			throw new WarrantyLifecycleError(
				'confirmation_required',
				'Replacement requires a request identity digest.',
			);
		}
		const current = active[0];
		assertConfirmation(current, confirmation);
		const replacedStorageKey = current.pdfFileName;
		await tombstoneAndHardDelete({
			warranty: current,
			franchiseeId,
			idempotencyKey,
			idempotencyAction: 'replace',
			requestDigest,
			replacementWarrantyId: values.id,
			transaction,
		});
		const warranty = await Warranty.create(
			{
				...values,
				version: 1,
				activeClientId: values.clientId,
				syncCursor: nextTenantSyncCursor(tenantState.cursor).toString(),
			},
			{ transaction },
		);
		await tenantState.update({ cursor: warranty.syncCursor.toString() }, { transaction });
		return {
			warranty,
			cleanupStorageKeys: [
				...legacyStorageKeys,
				...(replacedStorageKey ? [replacedStorageKey] : []),
			],
			replayed: false,
		};
	});

export const tombstoneClientWarranties = async ({
	clientId,
	franchiseeId,
	transaction,
}: {
	clientId: string;
	franchiseeId: string;
	transaction: Transaction;
}) => {
	const warrantyIds = await Warranty.findAll({
		where: { clientId },
		attributes: ['id'],
		paranoid: false,
		transaction,
	});
	for (const warrantyId of warrantyIds.map(({ id }) => id).sort()) {
		await lockWarrantyUuidReservation(warrantyId, transaction);
	}
	const warranties = await Warranty.findAll({
		where: { clientId },
		paranoid: false,
		transaction,
		lock: transaction.LOCK.UPDATE,
	});
	const storageKeys: string[] = [];
	for (const warranty of warranties) {
		if (warranty.pdfFileName) storageKeys.push(warranty.pdfFileName);
		await tombstoneAndHardDelete({
			warranty,
			franchiseeId,
			transaction,
		});
	}
	return storageKeys;
};

export const warrantyTombstonesAfter = async (
	franchiseeId: string,
	cursor: string,
	transaction?: Transaction,
	limit = 1000,
) =>
	WarrantyDeletionTombstone.findAll({
		where: {
			franchiseeId,
			deletionSequence: { [Op.gt]: cursor },
		},
		order: [['deletionSequence', 'ASC']],
		limit,
		transaction,
	});

/**
 * Metadata deletion is complete at commit. Filesystem reconciliation is
 * deliberately detached from the user response and leaves APP-109 outbox state
 * intact on failure.
 */
export const triggerWarrantyFileCleanup = (storageKeys: Array<string | null>) => {
	const keys = storageKeys.filter((key): key is string => Boolean(key));
	if (!keys.length) return;
	void reconcileManagedFileCleanupByStorageKeys(keys).catch((error) => {
		console.error('Unable to run post-commit warranty file reconciliation:', error);
	});
};
