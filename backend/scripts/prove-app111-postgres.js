'use strict';

const assert = require('assert/strict');
const { DataTypes, QueryTypes, Sequelize } = require('sequelize');

const migration = require('../migrations/20260730020000-add-lww-sync-v2.js');

const databaseUrl = process.env.APP111_POSTGRES_URL;
if (!databaseUrl) throw new Error('APP111_POSTGRES_URL is required.');
const databaseName = new URL(databaseUrl).pathname.slice(1);
if (!databaseName.startsWith('app111_proof_')) {
	throw new Error(
		'Refusing destructive proof outside a disposable app111_proof_* database.',
	);
}

const database = new Sequelize(databaseUrl, {
	logging: false,
	pool: { min: 0, max: 8 },
});
const tenantId = '50000000-0000-4000-8000-000000000001';
const clientId = '50000000-0000-4000-8000-000000000002';
const itemId = '50000000-0000-4000-8000-000000000003';
const rectangleId = '50000000-0000-4000-8000-000000000004';
const priceId = '50000000-0000-4000-8000-000000000005';
const rollbackWriterId = '50000000-0000-4000-8000-000000000006';

const resetPublicSchema = async () => {
	await database.query('DROP SCHEMA public CASCADE');
	await database.query('CREATE SCHEMA public');
};

const createBaseSchema = async () => {
	const queryInterface = database.getQueryInterface();
	await queryInterface.createTable('franchisees', {
		id: { type: DataTypes.UUID, primaryKey: true },
	});
	await queryInterface.createTable('clients', {
		id: { type: DataTypes.UUID, primaryKey: true },
		franchisee_id: { type: DataTypes.UUID, allowNull: false },
		name: { type: DataTypes.STRING, allowNull: false },
		address: DataTypes.STRING,
		site_address: DataTypes.STRING,
		email: DataTypes.STRING,
		phone: DataTypes.STRING,
		latitude: DataTypes.FLOAT,
		longitude: DataTypes.FLOAT,
		discounted_price: DataTypes.FLOAT,
		deleted_at: DataTypes.DATE,
	});
	await queryInterface.createTable('items', {
		id: { type: DataTypes.UUID, primaryKey: true },
		client_id: { type: DataTypes.UUID, allowNull: false },
		name: { type: DataTypes.STRING, allowNull: false },
		price: { type: DataTypes.DECIMAL(10, 2), allowNull: false },
		enabled: { type: DataTypes.BOOLEAN, allowNull: false },
		deleted_at: DataTypes.DATE,
	});
	await queryInterface.createTable('rectangles', {
		id: { type: DataTypes.UUID, primaryKey: true },
		item_id: { type: DataTypes.UUID, allowNull: false },
		length: { type: DataTypes.FLOAT, allowNull: false },
		width: { type: DataTypes.FLOAT, allowNull: false },
		deleted_at: DataTypes.DATE,
	});
	await queryInterface.createTable('default_prices', {
		id: { type: DataTypes.UUID, primaryKey: true },
		franchisee_id: { type: DataTypes.UUID, allowNull: false },
		price: { type: DataTypes.DECIMAL(10, 2), allowNull: false },
		enabled: { type: DataTypes.BOOLEAN, allowNull: false },
		deleted_at: DataTypes.DATE,
	});
	return queryInterface;
};

const expectRejection = async (promise, label) => {
	let rejected = false;
	try {
		await promise;
	} catch {
		rejected = true;
	}
	assert.equal(rejected, true, label);
};

const lockAndAdvance = async (rowId, hold) => {
	const transaction = await database.transaction();
	try {
		const rows = await database.query(
			`SELECT cursor
       FROM tenant_sync_state
       WHERE franchisee_id = :tenantId
       FOR UPDATE`,
			{ replacements: { tenantId }, type: QueryTypes.SELECT, transaction },
		);
		const current = BigInt(rows[0].cursor);
		if (hold) await hold();
		const next = current + 1n;
		await database.query(
			`UPDATE tenant_sync_state
       SET cursor = :next, updated_at = CURRENT_TIMESTAMP
       WHERE franchisee_id = :tenantId`,
			{ replacements: { tenantId, next: next.toString() }, transaction },
		);
		await database.query(
			'UPDATE clients SET sync_cursor = :next WHERE id = :rowId',
			{ replacements: { next: next.toString(), rowId }, transaction },
		);
		await transaction.commit();
		return next;
	} catch (error) {
		await transaction.rollback();
		throw error;
	}
};

const main = async () => {
	await database.authenticate();
	await resetPublicSchema();
	const queryInterface = await createBaseSchema();
	await queryInterface.bulkInsert('franchisees', [{ id: tenantId }]);
	await queryInterface.bulkInsert('clients', [
		{ id: clientId, franchisee_id: tenantId, name: 'Client' },
	]);
	await queryInterface.bulkInsert('items', [
		{
			id: itemId,
			client_id: clientId,
			name: 'Deleted item',
			price: 1,
			enabled: true,
			deleted_at: new Date('2026-07-01T00:00:00.000Z'),
		},
	]);
	await queryInterface.bulkInsert('rectangles', [
		{ id: rectangleId, item_id: itemId, length: 1, width: 2 },
	]);
	await queryInterface.bulkInsert('default_prices', [
		{ id: priceId, franchisee_id: tenantId, price: 3, enabled: true },
	]);

	await migration.up(queryInterface, Sequelize);
	const firstBackfill = await database.query(
		`SELECT lww_generation, lww_operation_rank, lww_writer_id,
            lww_change_id, lww_payload_hash, sync_cursor
     FROM items WHERE id = :itemId`,
		{ replacements: { itemId }, type: QueryTypes.SELECT },
	);
	assert.equal(firstBackfill[0].lww_generation, '1');
	assert.equal(firstBackfill[0].lww_operation_rank, 1);
	assert.match(firstBackfill[0].lww_writer_id, /^[0-9a-f-]{36}$/);
	assert.equal(firstBackfill[0].lww_payload_hash.length, 64);

	await migration.up(queryInterface, Sequelize);
	assert.deepEqual(
		await database.query(
			`SELECT lww_writer_id, lww_change_id, lww_payload_hash
       FROM items WHERE id = :itemId`,
			{ replacements: { itemId }, type: QueryTypes.SELECT },
		),
		firstBackfill.map(({ lww_writer_id, lww_change_id, lww_payload_hash }) => ({
			lww_writer_id,
			lww_change_id,
			lww_payload_hash,
		})),
		'idempotent forward must retain deterministic identities',
	);

	await database.query(
		`UPDATE items
     SET lww_generation = 2, sync_cursor = 2
     WHERE id = :itemId`,
		{ replacements: { itemId } },
	);
	await migration.down(queryInterface, Sequelize);
	assert(
		(await queryInterface.showAllTables()).includes('tenant_sync_state'),
		'non-destructive down must retain tenant cursor state',
	);
	await database.query(
		`INSERT INTO clients (id, franchisee_id, name)
     VALUES (:id, :tenantId, 'rollback writer')`,
		{ replacements: { id: rollbackWriterId, tenantId } },
	);
	assert.deepEqual(
		await database.query(
			`SELECT lww_generation, lww_writer_id, lww_change_id, sync_cursor
       FROM clients WHERE id = :id`,
			{ replacements: { id: rollbackWriterId }, type: QueryTypes.SELECT },
		),
		[
			{
				lww_generation: '1',
				lww_writer_id: '00000000-0000-4000-8000-000000000000',
				lww_change_id: '00000000-0000-4000-8000-000000000001',
				sync_cursor: '1',
			},
		],
		'rolled-back writers must retain additive insert compatibility',
	);
	await migration.up(queryInterface, Sequelize);
	assert.deepEqual(
		await database.query(
			'SELECT lww_generation, sync_cursor FROM items WHERE id = :itemId',
			{ replacements: { itemId }, type: QueryTypes.SELECT },
		),
		[{ lww_generation: '2', sync_cursor: '2' }],
		'reapply must not reset authoritative logical state',
	);

	await database.query(
		`UPDATE tenant_sync_state
     SET cursor = '9007199254740993'
     WHERE franchisee_id = :tenantId`,
		{ replacements: { tenantId } },
	);
	let releaseFirst;
	const firstMayCommit = new Promise((resolve) => {
		releaseFirst = resolve;
	});
	let firstLocked;
	const firstHasLock = new Promise((resolve) => {
		firstLocked = resolve;
	});
	const firstCommit = lockAndAdvance(clientId, async () => {
		firstLocked();
		await firstMayCommit;
	});
	await firstHasLock;
	const secondCommit = lockAndAdvance(clientId);
	await new Promise((resolve) => setTimeout(resolve, 100));
	releaseFirst();
	const orderedCursors = await Promise.all([firstCommit, secondCommit]);
	assert.deepEqual(orderedCursors, [9007199254740994n, 9007199254740995n]);
	assert.deepEqual(
		await database.query(
			`SELECT cursor
       FROM tenant_sync_state
       WHERE franchisee_id = :tenantId`,
			{ type: QueryTypes.SELECT, replacements: { tenantId } },
		),
		[{ cursor: '9007199254740995' }],
	);

	const rollback = await database.transaction();
	await database.query(
		`SELECT cursor
     FROM tenant_sync_state
     WHERE franchisee_id = :tenantId
     FOR UPDATE`,
		{ replacements: { tenantId }, transaction: rollback },
	);
	await database.query(
		`UPDATE tenant_sync_state
     SET cursor = cursor + 1
     WHERE franchisee_id = :tenantId`,
		{ replacements: { tenantId }, transaction: rollback },
	);
	await rollback.rollback();
	assert.deepEqual(
		await database.query(
			'SELECT cursor FROM tenant_sync_state WHERE franchisee_id = :tenantId',
			{ replacements: { tenantId }, type: QueryTypes.SELECT },
		),
		[{ cursor: '9007199254740995' }],
		'rollback must not leave a cursor gap',
	);

	await database.query(
		`UPDATE tenant_sync_state
     SET cursor = '9223372036854775807'
     WHERE franchisee_id = :tenantId`,
		{ replacements: { tenantId } },
	);
	await expectRejection(
		database.query(
			`UPDATE tenant_sync_state
       SET cursor = cursor + 1
       WHERE franchisee_id = :tenantId`,
			{ replacements: { tenantId } },
		),
		'PostgreSQL BIGINT overflow must fail closed',
	);

	await resetPublicSchema();
	const orphanQueryInterface = await createBaseSchema();
	await orphanQueryInterface.bulkInsert('items', [
		{
			id: itemId,
			client_id: clientId,
			name: 'Orphan',
			price: 1,
			enabled: true,
		},
	]);
	await expectRejection(
		migration.up(orphanQueryInterface, Sequelize),
		'inconsistent legacy parentage must abort',
	);
	assert.deepEqual(
		await database.query('SELECT id FROM items', { type: QueryTypes.SELECT }),
		[{ id: itemId }],
	);
	assert(
		!Object.keys(await orphanQueryInterface.describeTable('items')).includes(
			'lww_generation',
		),
		'failed forward migration must roll back its columns',
	);

	process.stdout.write(
		`${JSON.stringify({
			dialect: database.getDialect(),
			forward: 'passed',
			deterministic_backfill: 'passed',
			idempotent: 'passed',
			non_destructive_down: 'passed',
			rollback_writer_insert: 'passed',
			reapply: 'passed',
			cursor_above_2_53: 'passed',
			concurrent_commit_order: 'passed',
			rollback_gap: 'passed',
			bigint_overflow: 'passed',
			inconsistent_legacy_rollback: 'passed',
		})}\n`,
	);
};

main()
	.finally(() => database.close())
	.catch((error) => {
		console.error(error);
		process.exitCode = 1;
	});
