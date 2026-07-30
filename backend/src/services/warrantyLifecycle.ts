import { Op, Transaction } from 'sequelize';
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

export type WarrantyConfirmation = {
	warrantyId: string;
	warrantyCardNumber: string;
	warrantyVersion: number;
	irreversibleConfirmation: string;
};

export type NewWarrantyValues = {
	id: string;
	clientId: string;
	warrantyCardNumber: string;
	startDate: Date;
	durationYears: number;
	pdfUrl: string;
	pdfFileName: string;
};

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

export const findReservedWarrantyId = (warrantyId: string, transaction?: Transaction) =>
	WarrantyDeletionTombstone.findByPk(warrantyId, {
		transaction,
		...(transaction ? { lock: transaction.LOCK.UPDATE } : {}),
	});

const createWarrantyTombstone = async ({
	warrantyId,
	franchiseeId,
	idempotencyKey,
	replacementWarrantyId,
	deletedAt,
	transaction,
}: {
	warrantyId: string;
	franchiseeId: string;
	idempotencyKey?: string | null;
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
	replacementWarrantyId,
	transaction,
}: {
	warranty: Warranty;
	franchiseeId: string;
	idempotencyKey?: string | null;
	replacementWarrantyId?: string | null;
	transaction: Transaction;
}) => {
	const tombstone = await createWarrantyTombstone({
		warrantyId: warranty.id,
		franchiseeId,
		idempotencyKey,
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
	const warranties = await Warranty.findAll({
		where: {
			clientId: { [Op.in]: ownedClients.map((client) => client.id) },
			deletedAt: { [Op.ne]: null },
		},
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
}: {
	warrantyId: string;
	franchiseeId: string;
	idempotencyKey: string;
	confirmation: WarrantyConfirmation;
}) =>
	sequelize.transaction(async (transaction) => {
		const replay = await findIdempotencyReplay(franchiseeId, idempotencyKey, transaction);
		if (replay) {
			if (replay.warrantyId !== warrantyId) {
				throw new WarrantyLifecycleError(
					'idempotency_conflict',
					'The idempotency key was already used for another warranty mutation.',
				);
			}
			return { storageKey: null, replayed: true, tombstone: replay };
		}

		const reserved = await findReservedWarrantyId(warrantyId, transaction);
		if (reserved) {
			if (reserved.franchiseeId !== franchiseeId) {
				throw new WarrantyLifecycleError('not_found', 'Warranty not found.');
			}
			return { storageKey: null, replayed: true, tombstone: reserved };
		}

		const candidate = await Warranty.findByPk(warrantyId, {
			paranoid: false,
			transaction,
			attributes: ['id', 'clientId', 'deletedAt'],
		});
		if (!candidate) {
			throw new WarrantyLifecycleError('not_found', 'Warranty not found.');
		}
		await findOwnedClientForUpdate(candidate.clientId, franchiseeId, transaction);
		if (candidate.deletedAt) {
			const legacy = await Warranty.findByPk(warrantyId, {
				paranoid: false,
				transaction,
				lock: transaction.LOCK.UPDATE,
			});
			if (!legacy) {
				throw new WarrantyLifecycleError('not_found', 'Warranty not found.');
			}
			const storageKey = legacy.pdfFileName;
			const tombstone = await tombstoneAndHardDelete({
				warranty: legacy,
				franchiseeId,
				transaction,
			});
			return { storageKey, replayed: true, tombstone };
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
			transaction,
		});
		return { storageKey, replayed: false, tombstone };
	});

export const createOrReplaceConfirmedWarranty = async ({
	franchiseeId,
	values,
	idempotencyKey,
	confirmation,
}: {
	franchiseeId: string;
	values: NewWarrantyValues;
	idempotencyKey?: string;
	confirmation?: WarrantyConfirmation;
}) =>
	sequelize.transaction(async (transaction) => {
		await findOwnedClientForUpdate(values.clientId, franchiseeId, transaction);
		const legacyStorageKeys = await backfillLegacySoftDeletedWarranties({
			franchiseeId,
			clientId: values.clientId,
			transaction,
		});

		if (confirmation && idempotencyKey) {
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

		if (await findReservedWarrantyId(values.id, transaction)) {
			throw new WarrantyLifecycleError(
				'warranty_id_reserved',
				'The new warranty UUID is permanently reserved.',
			);
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
			return {
				warranty: await Warranty.create(
					{
						...values,
						version: 1,
						activeClientId: values.clientId,
					},
					{ transaction },
				),
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
		const current = active[0];
		assertConfirmation(current, confirmation);
		const replacedStorageKey = current.pdfFileName;
		await tombstoneAndHardDelete({
			warranty: current,
			franchiseeId,
			idempotencyKey,
			replacementWarrantyId: values.id,
			transaction,
		});
		const warranty = await Warranty.create(
			{
				...values,
				version: 1,
				activeClientId: values.clientId,
			},
			{ transaction },
		);
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

export const warrantyTombstonesAfter = async (franchiseeId: string, cursor: string, limit = 1000) =>
	WarrantyDeletionTombstone.findAll({
		where: {
			franchiseeId,
			deletionSequence: { [Op.gt]: cursor },
		},
		order: [['deletionSequence', 'ASC']],
		limit,
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
