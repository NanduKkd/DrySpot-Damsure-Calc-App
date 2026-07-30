import { DataTypes, Sequelize } from 'sequelize';

// eslint-disable-next-line @typescript-eslint/no-var-requires
const migration = require('../migrations/20260730010000-add-warranty-deletion-tombstones.js');
// eslint-disable-next-line @typescript-eslint/no-var-requires
const cleanupMigration = require('../migrations/20260730000000-add-managed-file-cleanups.js');

describe('APP-110 warranty deletion migration', () => {
	let database: Sequelize;

	beforeEach(async () => {
		database = new Sequelize('sqlite::memory:', { logging: false });
		const queryInterface = database.getQueryInterface();
		await queryInterface.createTable('clients', {
			id: { type: DataTypes.UUID, primaryKey: true },
			franchisee_id: { type: DataTypes.UUID, allowNull: false },
			deleted_at: { type: DataTypes.DATE, allowNull: true },
		});
		await queryInterface.createTable('warranties', {
			id: { type: DataTypes.UUID, primaryKey: true },
			client_id: { type: DataTypes.UUID, allowNull: false },
			pdf_file_name: { type: DataTypes.STRING, allowNull: true },
			deleted_at: { type: DataTypes.DATE, allowNull: true },
		});
		await cleanupMigration.up(queryInterface, Sequelize);
	});

	afterEach(async () => {
		await database.close();
	});

	it('idempotently backfills before hard-delete and keeps down non-destructive', async () => {
		const queryInterface = database.getQueryInterface();
		const deletedWarrantyId = '30000000-0000-0000-0000-000000000001';
		const activeWarrantyId = '30000000-0000-0000-0000-000000000002';
		const clientId = '30000000-0000-0000-0000-000000000003';
		const franchiseeId = '30000000-0000-0000-0000-000000000004';
		await queryInterface.bulkInsert('clients', [
			{ id: clientId, franchisee_id: franchiseeId, deleted_at: null },
		]);
		await queryInterface.bulkInsert('warranties', [
			{
				id: deletedWarrantyId,
				client_id: clientId,
				pdf_file_name: 'legacy-warranty.pdf',
				deleted_at: new Date('2026-07-01T00:00:00.000Z'),
			},
			{
				id: activeWarrantyId,
				client_id: clientId,
				pdf_file_name: 'active-warranty.pdf',
				deleted_at: null,
			},
		]);

		await migration.up(queryInterface, Sequelize);
		await migration.up(queryInterface, Sequelize);

		const tombstones = await database.query('SELECT * FROM warranty_deletion_tombstones', {
			type: 'SELECT' as any,
		});
		expect(tombstones).toHaveLength(1);
		expect((tombstones[0] as any).warranty_id).toBe(deletedWarrantyId);
		expect((tombstones[0] as any).franchisee_id).toBe(franchiseeId);
		expect(
			await database.query('SELECT id FROM warranties ORDER BY id', {
				type: 'SELECT' as any,
			}),
		).toEqual([{ id: activeWarrantyId }]);
		expect(Object.keys(await queryInterface.describeTable('warranties'))).toContain('version');
		expect(
			await database.query(
				'SELECT storage_key, kind FROM managed_file_cleanups ORDER BY storage_key',
				{ type: 'SELECT' as any },
			),
		).toEqual([{ storage_key: 'legacy-warranty.pdf', kind: 'pdf' }]);
		expect(
			await database.query(
				'SELECT warranty_id, reservation_state FROM warranty_uuid_reservations ORDER BY warranty_id',
				{ type: 'SELECT' as any },
			),
		).toEqual([
			{ warranty_id: deletedWarrantyId, reservation_state: 'tombstoned' },
			{ warranty_id: activeWarrantyId, reservation_state: 'live' },
		]);

		await migration.down(queryInterface, Sequelize);
		expect(await queryInterface.showAllTables()).toEqual(
			expect.arrayContaining([
				'warranties',
				'warranty_deletion_sequence',
				'warranty_deletion_tombstones',
				'warranty_uuid_reservations',
			]),
		);
		expect(
			await database.query('SELECT warranty_id FROM warranty_deletion_tombstones', {
				type: 'SELECT' as any,
			}),
		).toEqual([{ warranty_id: deletedWarrantyId }]);
		await expect(
			database.query(
				`INSERT INTO warranties (id, client_id, pdf_file_name, deleted_at, version)
         VALUES (:id, :clientId, 'resurrection.pdf', NULL, 1)`,
				{ replacements: { id: deletedWarrantyId, clientId } },
			),
		).rejects.toThrow();
	});

	it('allows tombstoning the current live row but blocks later inserts and id updates', async () => {
		const queryInterface = database.getQueryInterface();
		const liveId = '30000000-0000-0000-0000-000000000020';
		const otherId = '30000000-0000-0000-0000-000000000021';
		const clientId = '30000000-0000-0000-0000-000000000022';
		const franchiseeId = '30000000-0000-0000-0000-000000000023';
		await queryInterface.bulkInsert('clients', [
			{ id: clientId, franchisee_id: franchiseeId, deleted_at: null },
		]);
		await migration.up(queryInterface, Sequelize);
		await database.query(
			`INSERT INTO warranties (id, client_id, pdf_file_name, deleted_at, version)
       VALUES (:id, :clientId, 'live.pdf', NULL, 1)`,
			{ replacements: { id: liveId, clientId } },
		);
		await database.query(
			`INSERT INTO warranty_deletion_tombstones
       (warranty_id, franchisee_id, deletion_sequence, deleted_at)
       VALUES (:id, :franchiseeId, 1, CURRENT_TIMESTAMP)`,
			{ replacements: { id: liveId, franchiseeId } },
		);
		await database.query('DELETE FROM warranties WHERE id = :id', {
			replacements: { id: liveId },
		});

		await expect(
			database.query(
				`INSERT INTO warranties (id, client_id, pdf_file_name, deleted_at, version)
         VALUES (:id, :clientId, 'resurrection.pdf', NULL, 1)`,
				{ replacements: { id: liveId, clientId } },
			),
		).rejects.toThrow();

		await database.query(
			`INSERT INTO warranties (id, client_id, pdf_file_name, deleted_at, version)
       VALUES (:id, :clientId, 'other.pdf', NULL, 1)`,
			{ replacements: { id: otherId, clientId } },
		);
		await expect(
			database.query('UPDATE warranties SET id = :liveId WHERE id = :otherId', {
				replacements: { liveId, otherId },
			}),
		).rejects.toThrow();
	});

	it('aborts without deleting an orphaned legacy warranty', async () => {
		const queryInterface = database.getQueryInterface();
		const orphanId = '30000000-0000-0000-0000-000000000010';
		await queryInterface.bulkInsert('warranties', [
			{
				id: orphanId,
				client_id: '30000000-0000-0000-0000-000000000011',
				deleted_at: new Date('2026-07-01T00:00:00.000Z'),
			},
		]);

		await expect(migration.up(queryInterface, Sequelize)).rejects.toThrow(
			'no tenant-owned client',
		);
		expect(
			await database.query('SELECT id FROM warranties', {
				type: 'SELECT' as any,
			}),
		).toEqual([{ id: orphanId }]);
	});
});
