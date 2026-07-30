'use strict';

const { createHash, randomUUID } = require('crypto');
const assert = require('assert/strict');
const { DataTypes, QueryTypes, Sequelize } = require('sequelize');

const migration = require('../migrations/20260730020000-add-lww-sync-v2.js');

const databaseUrl = process.env.APP111_POSTGRES_URL;
if (!databaseUrl) throw new Error('APP111_POSTGRES_URL is required.');
const databaseName = new URL(databaseUrl).pathname.slice(1);
if (!databaseName.startsWith('app111_proof_')) {
	throw new Error('Refusing destructive proof outside a disposable app111_proof_* database.');
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
		image_data: DataTypes.TEXT,
		deleted_at: DataTypes.DATE,
	});
	await queryInterface.createTable('default_prices', {
		id: { type: DataTypes.UUID, primaryKey: true },
		franchisee_id: { type: DataTypes.UUID, allowNull: false },
		price: { type: DataTypes.DECIMAL(10, 2), allowNull: false },
		enabled: { type: DataTypes.BOOLEAN, allowNull: false },
		deleted_at: DataTypes.DATE,
	});
	await queryInterface.createTable('warranties', {
		id: { type: DataTypes.UUID, primaryKey: true },
		client_id: { type: DataTypes.UUID, allowNull: false },
		warranty_card_number: { type: DataTypes.STRING, allowNull: false },
		start_date: { type: DataTypes.DATE, allowNull: false },
		duration_years: { type: DataTypes.INTEGER, allowNull: false },
		pdf_url: { type: DataTypes.STRING, allowNull: false },
		deleted_at: DataTypes.DATE,
	});
	await queryInterface.createTable('proposals', {
		id: { type: DataTypes.UUID, primaryKey: true },
		client_id: { type: DataTypes.UUID, allowNull: false },
		pdf_url: { type: DataTypes.STRING, allowNull: false },
		deleted_at: DataTypes.DATE,
	});
	return queryInterface;
};

const canonicalHash = (value) => {
	const stable = (candidate) => {
		if (Array.isArray(candidate)) return candidate.map(stable);
		if (candidate && typeof candidate === 'object') {
			return Object.fromEntries(
				Object.keys(candidate)
					.sort()
					.map((key) => [key, stable(candidate[key])]),
			);
		}
		return candidate;
	};
	return createHash('sha256')
		.update(JSON.stringify(stable(value)))
		.digest('hex');
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
		await database.query('UPDATE clients SET sync_cursor = :next WHERE id = :rowId', {
			replacements: { next: next.toString(), rowId },
			transaction,
		});
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
		{
			id: clientId,
			franchisee_id: tenantId,
			name: 'Client',
			address: '',
			site_address: '',
			email: '',
			phone: '',
			latitude: 11.123456789,
			longitude: -0,
			discounted_price: 44.44,
		},
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
	const clientBackfill = await database.query(
		`SELECT lww_payload_hash
     FROM clients WHERE id = :clientId`,
		{ replacements: { clientId }, type: QueryTypes.SELECT },
	);
	assert.equal(
		clientBackfill[0].lww_payload_hash,
		canonicalHash({
			address: '',
			discounted_price: 44.44,
			email: null,
			latitude: Math.fround(11.123456789),
			longitude: 0,
			name: 'Client',
			phone: '',
			site_address: '',
		}),
		'migration backfill must use the same storage-canonical payload hash',
	);
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
	await database.query(
		`UPDATE tenant_sync_state
     SET cursor = 2
     WHERE franchisee_id = :tenantId`,
		{ replacements: { tenantId } },
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
	await expectRejection(
		migration.up(queryInterface, Sequelize),
		'reapply must reject the complete but inconsistent default payload hash',
	);
	await database.query(
		`UPDATE clients
     SET lww_payload_hash = :payloadHash
     WHERE id = :id`,
		{
			replacements: {
				id: rollbackWriterId,
				payloadHash: canonicalHash({
					address: null,
					discounted_price: null,
					email: null,
					latitude: null,
					longitude: null,
					name: 'rollback writer',
					phone: null,
					site_address: null,
				}),
			},
		},
	);
	await migration.up(queryInterface, Sequelize);
	assert.deepEqual(
		await database.query('SELECT lww_generation, sync_cursor FROM items WHERE id = :itemId', {
			replacements: { itemId },
			type: QueryTypes.SELECT,
		}),
		[{ lww_generation: '2', sync_cursor: '2' }],
		'reapply must not reset authoritative logical state',
	);

	const invariantCases = [
		{
			mutate: 'UPDATE clients SET lww_branch_seq = 0 WHERE id = :rollbackWriterId',
			repair: 'UPDATE clients SET lww_branch_seq = 1 WHERE id = :rollbackWriterId',
		},
		{
			mutate: 'UPDATE clients SET lww_operation_rank = 1 WHERE id = :rollbackWriterId',
			repair: 'UPDATE clients SET lww_operation_rank = 0 WHERE id = :rollbackWriterId',
		},
		{
			mutate: "UPDATE clients SET lww_writer_id = '50000000-0000-1000-8000-000000000099' WHERE id = :rollbackWriterId",
			repair: "UPDATE clients SET lww_writer_id = '00000000-0000-4000-8000-000000000000' WHERE id = :rollbackWriterId",
		},
		{
			mutate: "UPDATE clients SET lww_change_id = '50000000-0000-1000-8000-000000000098' WHERE id = :rollbackWriterId",
			repair: "UPDATE clients SET lww_change_id = '00000000-0000-4000-8000-000000000001' WHERE id = :rollbackWriterId",
		},
		{
			mutate: `UPDATE clients SET lww_payload_hash = '${'f'.repeat(
				64,
			)}' WHERE id = :rollbackWriterId`,
			repair: 'UPDATE clients SET lww_payload_hash = :rollbackPayloadHash WHERE id = :rollbackWriterId',
		},
		{
			mutate: 'UPDATE clients SET sync_cursor = 3 WHERE id = :rollbackWriterId',
			repair: 'UPDATE clients SET sync_cursor = 1 WHERE id = :rollbackWriterId',
		},
	];
	const invariantReplacements = {
		rollbackWriterId,
		rollbackPayloadHash: canonicalHash({
			address: null,
			discounted_price: null,
			email: null,
			latitude: null,
			longitude: null,
			name: 'rollback writer',
			phone: null,
			site_address: null,
		}),
	};
	for (const invariant of invariantCases) {
		await database.query(invariant.mutate, {
			replacements: invariantReplacements,
		});
		await expectRejection(
			migration.up(queryInterface, Sequelize),
			'complete inconsistent logical state must abort',
		);
		assert.deepEqual(
			await database.query(
				'SELECT cursor FROM tenant_sync_state WHERE franchisee_id = :tenantId',
				{ replacements: { tenantId }, type: QueryTypes.SELECT },
			),
			[{ cursor: '2' }],
			'a failed reapply must roll back every migration mutation',
		);
		await database.query(invariant.repair, {
			replacements: invariantReplacements,
		});
		await migration.up(queryInterface, Sequelize);
	}

	const auxiliaryWarrantyId = '50000000-0000-4000-8000-000000000007';
	await database.query(
		`INSERT INTO warranties
       (id, client_id, warranty_card_number, start_date, duration_years,
        pdf_url, sync_cursor)
     VALUES
       (:id, :clientId, 'CURSOR', CURRENT_TIMESTAMP, 5,
        :pdfUrl, 3)`,
		{
			replacements: {
				id: auxiliaryWarrantyId,
				clientId,
				pdfUrl: `/api/warranty/${auxiliaryWarrantyId}/download`,
			},
		},
	);
	await expectRejection(
		migration.up(queryInterface, Sequelize),
		'auxiliary cursor ahead of tenant must abort',
	);
	await database.query('UPDATE warranties SET sync_cursor = 1 WHERE id = :id', {
		replacements: { id: auxiliaryWarrantyId },
	});
	await migration.up(queryInterface, Sequelize);

	const futureRequestId = randomUUID();
	await database.query(
		`INSERT INTO sync_v2_requests
       (franchisee_id, request_id, request_hash, response_cursor,
        response_json, created_at, updated_at)
     VALUES (:tenantId, :requestId, :requestHash, 3, '{}',
             CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)`,
		{
			replacements: {
				tenantId,
				requestId: futureRequestId,
				requestHash: 'a'.repeat(64),
			},
		},
	);
	await expectRejection(
		migration.up(queryInterface, Sequelize),
		'request response cursor ahead of tenant must abort',
	);
	await database.query('DELETE FROM sync_v2_requests WHERE request_id = :requestId', {
		replacements: { requestId: futureRequestId },
	});
	await migration.up(queryInterface, Sequelize);

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
	assert.deepEqual(await database.query('SELECT id FROM items', { type: QueryTypes.SELECT }), [
		{ id: itemId },
	]);
	assert(
		!Object.keys(await orphanQueryInterface.describeTable('items')).includes('lww_generation'),
		'failed forward migration must roll back its columns',
	);

	await resetPublicSchema();
	process.env.DATABASE_URL = databaseUrl;
	process.env.NODE_ENV = 'development';
	process.env.JWT_SECRET = 'app111-postgres-proof-jwt-secret-32-chars';
	delete process.env.SYNC_MIN_PROTOCOL_VERSION;
	require('ts-node/register/transpile-only');
	const app = require('../src/app').default;
	const {
		sequelize: appDatabase,
		Client,
		DefaultPrice,
		Franchisee,
		Item,
		Rectangle,
		TenantSyncState,
		User,
	} = require('../src/models');
	const jwt = require('jsonwebtoken');
	const request = require('supertest');
	await appDatabase.sync({ force: true });
	await migration.up(appDatabase.getQueryInterface(), Sequelize);
	await Franchisee.create({ id: tenantId, name: 'Handler proof tenant' });
	const handlerUserId = '50000000-0000-4000-8000-000000000008';
	await User.create({
		id: handlerUserId,
		name: 'Handler proof user',
		email: 'app111-handler-proof@example.com',
		password: 'not-used',
		franchiseeId: tenantId,
	});
	await TenantSyncState.create({ franchiseeId: tenantId, cursor: '1' });
	await appDatabase.query(`
    CREATE OR REPLACE FUNCTION app111_hold_tenant_cursor()
    RETURNS trigger AS $$
    BEGIN
      PERFORM pg_sleep(0.20);
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
  `);
	await appDatabase.query(`
    CREATE TRIGGER app111_hold_tenant_cursor_trigger
    BEFORE UPDATE ON tenant_sync_state
    FOR EACH ROW EXECUTE FUNCTION app111_hold_tenant_cursor()
  `);
	const handlerToken = jwt.sign(
		{ id: handlerUserId, franchiseeId: tenantId, tokenVersion: 0 },
		process.env.JWT_SECRET,
	);
	const legacyClientId = '50000000-0000-4000-8000-000000000009';
	const v2PriceId = '50000000-0000-4000-8000-000000000010';
	const v1Request = request(app)
		.post('/api/sync')
		.set('Authorization', `Bearer ${handlerToken}`)
		.send({
			last_sync_time: null,
			warranty_tombstone_cursor: '0',
			changes: {
				clients: [
					{
						remote_id: legacyClientId,
						name: 'Concurrent v1 client',
						address: null,
						site_address: null,
						email: null,
						phone: null,
						latitude: null,
						longitude: null,
						photos: [],
						discounted_price: null,
					},
				],
			},
		});
	const v2Request = request(app)
		.post('/api/sync/v2')
		.set('Authorization', `Bearer ${handlerToken}`)
		.send({
			protocol_version: 2,
			request_id: randomUUID(),
			request_cursor: '1',
			warranty_tombstone_cursor: '0',
			changes: {
				clients: [],
				items: [],
				rectangles: [],
				default_prices: [
					{
						remote_id: v2PriceId,
						operation: 'upsert',
						base_generation: '0',
						generation: '1',
						branch_seq: 1,
						writer_id: randomUUID(),
						change_id: randomUUID(),
						payload: { price: 42, enabled: true },
					},
				],
			},
		});
	const handlerResponses = await Promise.all([v1Request, v2Request]);
	assert.deepEqual(
		handlerResponses.map(({ status }) => status),
		[200, 200],
		'actual concurrent v1/v2 HTTP handlers must not deadlock or fail',
	);
	assert.equal(
		(await TenantSyncState.findByPk(tenantId)).cursor,
		'3',
		'two actual handler commits must serialize onto distinct cursors',
	);
	const handlerRows = [
		await Client.findByPk(legacyClientId, { paranoid: false }),
		await DefaultPrice.findByPk(v2PriceId, { paranoid: false }),
	];
	assert.deepEqual(
		handlerRows
			.map((row) => BigInt(row.syncCursor))
			.sort((left, right) => (left < right ? -1 : 1)),
		[2n, 3n],
		'v1 and v2 handler rows must carry the same serialized commit order',
	);

	const canonicalParentItemId = '50000000-0000-4000-8000-000000000011';
	const canonicalClientId = '50000000-0000-4000-8000-000000000012';
	const canonicalRectangleId = '50000000-0000-4000-8000-000000000013';
	await Item.create({
		id: canonicalParentItemId,
		clientId: legacyClientId,
		name: 'Canonical parent item',
		price: 1,
		enabled: true,
	});
	const clientPayload = {
		name: 'Canonical storage client',
		address: '',
		site_address: '',
		email: '',
		phone: '',
		latitude: 11.123456789,
		longitude: -0,
		discounted_price: 44.44,
	};
	const rectanglePayload = {
		length: 11.123456789,
		width: 0.0000001,
	};
	const canonicalResponse = await request(app)
		.post('/api/sync/v2')
		.set('Authorization', `Bearer ${handlerToken}`)
		.send({
			protocol_version: 2,
			request_id: randomUUID(),
			request_cursor: '3',
			warranty_tombstone_cursor: '0',
			changes: {
				clients: [
					{
						remote_id: canonicalClientId,
						operation: 'upsert',
						base_generation: '0',
						generation: '1',
						branch_seq: 1,
						writer_id: randomUUID(),
						change_id: randomUUID(),
						payload: clientPayload,
					},
				],
				items: [],
				rectangles: [
					{
						remote_id: canonicalRectangleId,
						parent_id: canonicalParentItemId,
						operation: 'upsert',
						base_generation: '0',
						generation: '1',
						branch_seq: 1,
						writer_id: randomUUID(),
						change_id: randomUUID(),
						payload: rectanglePayload,
					},
				],
				default_prices: [],
			},
		});
	assert.equal(canonicalResponse.status, 200);
	const canonicalClient = canonicalResponse.body.outcomes.clients[0].authoritative;
	const canonicalRectangle = canonicalResponse.body.outcomes.rectangles[0].authoritative;
	assert.deepEqual(canonicalClient.payload, {
		...clientPayload,
		email: null,
		latitude: Math.fround(clientPayload.latitude),
		longitude: 0,
	});
	assert.deepEqual(canonicalRectangle.payload, {
		length: Math.fround(rectanglePayload.length),
		width: Math.fround(rectanglePayload.width),
	});
	assert.equal(canonicalClient.payload_hash, canonicalHash(canonicalClient.payload));
	assert.equal(canonicalRectangle.payload_hash, canonicalHash(canonicalRectangle.payload));
	assert.equal(
		(await Client.findByPk(canonicalClientId)).lwwPayloadHash,
		canonicalClient.payload_hash,
	);
	assert.equal(
		(await Rectangle.findByPk(canonicalRectangleId)).lwwPayloadHash,
		canonicalRectangle.payload_hash,
	);
	await appDatabase.close();

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
			complete_state_invariants: 'passed',
			concurrent_v1_v2_handlers: 'passed',
			canonical_payload_round_trip: 'passed',
		})}\n`,
	);
};

main()
	.finally(() => database.close())
	.catch((error) => {
		console.error(error);
		process.exitCode = 1;
	});
