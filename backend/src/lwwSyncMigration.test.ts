import { DataTypes, QueryTypes, Sequelize } from 'sequelize';

// eslint-disable-next-line @typescript-eslint/no-var-requires
const migration = require('../migrations/20260730020000-add-lww-sync-v2.js');

describe('APP-111 LWW sync migration', () => {
	let database: Sequelize;

	const createSchema = async () => {
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
		await queryInterface.createTable('warranties', {
			id: { type: DataTypes.UUID, primaryKey: true },
			client_id: { type: DataTypes.UUID, allowNull: false },
			warranty_card_number: { type: DataTypes.STRING, allowNull: false },
			start_date: { type: DataTypes.DATE, allowNull: false },
			duration_years: { type: DataTypes.INTEGER, allowNull: false },
			pdf_url: { type: DataTypes.STRING, allowNull: false },
		});
		await queryInterface.createTable('proposals', {
			id: { type: DataTypes.UUID, primaryKey: true },
			client_id: { type: DataTypes.UUID, allowNull: false },
			pdf_url: { type: DataTypes.STRING, allowNull: false },
			deleted_at: DataTypes.DATE,
		});
		return queryInterface;
	};

	beforeEach(async () => {
		database = new Sequelize('sqlite::memory:', { logging: false });
	});

	afterEach(async () => {
		await database.close();
	});

	it('backfills deterministic generation-one identities and cursor one idempotently', async () => {
		const queryInterface = await createSchema();
		const tenantId = '30000000-0000-4000-8000-000000000001';
		const clientId = '30000000-0000-4000-8000-000000000002';
		const itemId = '30000000-0000-4000-8000-000000000003';
		const rectangleId = '30000000-0000-4000-8000-000000000004';
		const priceId = '30000000-0000-4000-8000-000000000005';
		await queryInterface.bulkInsert('franchisees', [{ id: tenantId }]);
		await queryInterface.bulkInsert('clients', [
			{ id: clientId, franchisee_id: tenantId, name: 'Client' },
		]);
		await queryInterface.bulkInsert('items', [
			{
				id: itemId,
				client_id: clientId,
				name: 'Item',
				price: 10,
				enabled: true,
				deleted_at: new Date('2026-01-01T00:00:00.000Z'),
			},
		]);
		await queryInterface.bulkInsert('rectangles', [
			{ id: rectangleId, item_id: itemId, length: 1, width: 2 },
		]);
		await queryInterface.bulkInsert('default_prices', [
			{ id: priceId, franchisee_id: tenantId, price: 3, enabled: true },
		]);

		await migration.up(queryInterface, Sequelize);
		const first = await database.query(
			`SELECT lww_generation, lww_branch_seq, lww_operation_rank,
              lww_writer_id, lww_change_id, lww_payload_hash, sync_cursor
       FROM items WHERE id = :itemId`,
			{ replacements: { itemId }, type: QueryTypes.SELECT },
		);
		expect(first).toEqual([
			expect.objectContaining({
				lww_generation: 1,
				lww_branch_seq: 1,
				lww_operation_rank: 1,
				sync_cursor: 1,
			}),
		]);
		expect((first[0] as any).lww_writer_id).toMatch(
			/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab]/,
		);
		expect((first[0] as any).lww_payload_hash).toHaveLength(64);
		expect(
			await database.query('SELECT franchisee_id, cursor FROM tenant_sync_state', {
				type: QueryTypes.SELECT,
			}),
		).toEqual([{ franchisee_id: tenantId, cursor: 1 }]);

		await database.query(
			`UPDATE items
       SET lww_generation = 2, sync_cursor = 2
       WHERE id = :itemId`,
			{ replacements: { itemId } },
		);
		await database.query(
			`UPDATE tenant_sync_state SET cursor = 2 WHERE franchisee_id = :tenantId`,
			{ replacements: { tenantId } },
		);
		await migration.down(queryInterface, Sequelize);
		await migration.up(queryInterface, Sequelize);
		expect(
			await database.query(
				'SELECT lww_generation, sync_cursor FROM items WHERE id = :itemId',
				{ replacements: { itemId }, type: QueryTypes.SELECT },
			),
		).toEqual([{ lww_generation: 2, sync_cursor: 2 }]);
		expect(await queryInterface.showAllTables()).toEqual(
			expect.arrayContaining([
				'tenant_sync_state',
				'sync_v2_requests',
				'sync_v2_change_receipts',
			]),
		);
	});

	it('rolls back safely when a child has no tenant-owned parent', async () => {
		const queryInterface = await createSchema();
		const itemId = '30000000-0000-4000-8000-000000000010';
		await queryInterface.bulkInsert('items', [
			{
				id: itemId,
				client_id: '30000000-0000-4000-8000-000000000011',
				name: 'Orphan',
				price: 1,
				enabled: true,
			},
		]);
		await expect(migration.up(queryInterface, Sequelize)).rejects.toThrow(
			'no tenant-owned parent',
		);
		expect(
			await database.query('SELECT id FROM items', {
				type: QueryTypes.SELECT,
			}),
		).toEqual([{ id: itemId }]);
		expect(Object.keys(await queryInterface.describeTable('items'))).not.toContain(
			'lww_generation',
		);
	});

	it('aborts rather than overwriting partial legacy logical state', async () => {
		const queryInterface = await createSchema();
		const tenantId = '30000000-0000-4000-8000-000000000020';
		const clientId = '30000000-0000-4000-8000-000000000021';
		await queryInterface.addColumn('clients', 'lww_generation', {
			type: DataTypes.BIGINT,
			allowNull: true,
		});
		await queryInterface.bulkInsert('franchisees', [{ id: tenantId }]);
		await queryInterface.bulkInsert('clients', [
			{
				id: clientId,
				franchisee_id: tenantId,
				name: 'Partial',
				lww_generation: 7,
			},
		]);
		await expect(migration.up(queryInterface, Sequelize)).rejects.toThrow(
			'partial logical state',
		);
		expect(
			await database.query('SELECT id, lww_generation FROM clients WHERE id = :clientId', {
				replacements: { clientId },
				type: QueryTypes.SELECT,
			}),
		).toEqual([{ id: clientId, lww_generation: 7 }]);
	});

	it('fails closed on every complete-state invariant and reapplies after repair', async () => {
		const queryInterface = await createSchema();
		const tenantId = '30000000-0000-4000-8000-000000000030';
		const clientId = '30000000-0000-4000-8000-000000000031';
		const warrantyId = '30000000-0000-4000-8000-000000000032';
		await queryInterface.bulkInsert('franchisees', [{ id: tenantId }]);
		await queryInterface.bulkInsert('clients', [
			{ id: clientId, franchisee_id: tenantId, name: 'Invariant client' },
		]);
		await queryInterface.bulkInsert('warranties', [
			{
				id: warrantyId,
				client_id: clientId,
				warranty_card_number: 'INV-1',
				start_date: new Date('2026-01-01T00:00:00.000Z'),
				duration_years: 5,
				pdf_url: `/api/warranty/${warrantyId}/download`,
			},
		]);
		await migration.up(queryInterface, Sequelize);
		const [original] = (await database.query(
			`SELECT lww_branch_seq, lww_operation_rank, lww_writer_id,
			        lww_change_id, lww_payload_hash, sync_cursor
			 FROM clients WHERE id = :clientId`,
			{ replacements: { clientId }, type: QueryTypes.SELECT },
		)) as any[];

		const cases = [
			{
				mutate: `UPDATE clients SET lww_branch_seq = 0 WHERE id = '${clientId}'`,
				repair: `UPDATE clients SET lww_branch_seq = ${original.lww_branch_seq} WHERE id = '${clientId}'`,
				error: 'invalid logical state',
			},
			{
				mutate: `UPDATE clients SET lww_operation_rank = 1 WHERE id = '${clientId}'`,
				repair: `UPDATE clients SET lww_operation_rank = ${original.lww_operation_rank} WHERE id = '${clientId}'`,
				error: 'invalid logical state',
			},
			{
				mutate: `UPDATE clients SET lww_writer_id = 'not-a-v4' WHERE id = '${clientId}'`,
				repair: `UPDATE clients SET lww_writer_id = '${original.lww_writer_id}' WHERE id = '${clientId}'`,
				error: 'invalid logical state',
			},
			{
				mutate: `UPDATE clients SET lww_change_id = '30000000-0000-1000-8000-000000000099' WHERE id = '${clientId}'`,
				repair: `UPDATE clients SET lww_change_id = '${original.lww_change_id}' WHERE id = '${clientId}'`,
				error: 'invalid logical state',
			},
			{
				mutate: `UPDATE clients SET lww_payload_hash = '${'f'.repeat(64)}' WHERE id = '${clientId}'`,
				repair: `UPDATE clients SET lww_payload_hash = '${original.lww_payload_hash}' WHERE id = '${clientId}'`,
				error: 'invalid logical state',
			},
			{
				mutate: `UPDATE clients SET sync_cursor = 2 WHERE id = '${clientId}'`,
				repair: `UPDATE clients SET sync_cursor = ${original.sync_cursor} WHERE id = '${clientId}'`,
				error: 'ahead of its tenant cursor',
			},
			{
				mutate: `UPDATE warranties SET sync_cursor = 2 WHERE id = '${warrantyId}'`,
				repair: `UPDATE warranties SET sync_cursor = 1 WHERE id = '${warrantyId}'`,
				error: 'inconsistent tenant cursor state',
			},
		];
		for (const invariant of cases) {
			await database.query(invariant.mutate);
			await expect(migration.up(queryInterface, Sequelize)).rejects.toThrow(invariant.error);
			expect(
				await database.query(
					'SELECT cursor FROM tenant_sync_state WHERE franchisee_id = :tenantId',
					{ replacements: { tenantId }, type: QueryTypes.SELECT },
				),
			).toEqual([{ cursor: 1 }]);
			await database.query(invariant.repair);
			await expect(migration.up(queryInterface, Sequelize)).resolves.toBeUndefined();
		}

		const now = new Date();
		await queryInterface.bulkInsert('sync_v2_requests', [
			{
				franchisee_id: tenantId,
				request_id: '30000000-0000-4000-8000-000000000033',
				request_hash: 'a'.repeat(64),
				response_cursor: 2,
				response_json: '{}',
				created_at: now,
				updated_at: now,
			},
		]);
		await expect(migration.up(queryInterface, Sequelize)).rejects.toThrow(
			'inconsistent tenant cursor state',
		);
		expect(
			await database.query('SELECT response_cursor FROM sync_v2_requests', {
				type: QueryTypes.SELECT,
			}),
		).toEqual([{ response_cursor: 2 }]);
		await queryInterface.bulkDelete('sync_v2_requests', {});
		await expect(migration.up(queryInterface, Sequelize)).resolves.toBeUndefined();
	});
});
