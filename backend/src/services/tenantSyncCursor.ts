import { Transaction } from 'sequelize';
import { TenantSyncState } from '../models';

export const MAX_TENANT_SYNC_CURSOR = 9223372036854775807n;

export class TenantCursorExhaustedError extends Error {
	constructor() {
		super('The authoritative tenant cursor is exhausted.');
	}
}

/**
 * Every transaction that can become visible through sync must acquire this
 * row before locking an entity row. This is the single PostgreSQL lock order
 * shared by protocol v1, protocol v2, media, warranty, and proposal writers.
 */
export const lockTenantSyncState = async (franchiseeId: string, transaction: Transaction) => {
	let state = await TenantSyncState.findByPk(franchiseeId, {
		transaction,
		lock: transaction.LOCK.UPDATE,
	});
	if (!state) {
		await TenantSyncState.findOrCreate({
			where: { franchiseeId },
			defaults: { franchiseeId, cursor: '1' },
			transaction,
		});
		state = await TenantSyncState.findByPk(franchiseeId, {
			transaction,
			lock: transaction.LOCK.UPDATE,
		});
	}
	if (!state) throw new Error('Unable to establish tenant sync state.');
	return state;
};

export const nextTenantSyncCursor = (current: string) => {
	const parsed = BigInt(current);
	if (parsed >= MAX_TENANT_SYNC_CURSOR) {
		throw new TenantCursorExhaustedError();
	}
	return parsed + 1n;
};
