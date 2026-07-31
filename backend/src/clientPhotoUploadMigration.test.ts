import { DataTypes, QueryTypes, Sequelize } from 'sequelize';

// eslint-disable-next-line @typescript-eslint/no-var-requires
const migration = require('../migrations/20260731000000-add-client-photo-upload-idempotency.js');

describe('APP-112 client photo receipt migration', () => {
	let database: Sequelize;

	beforeEach(async () => {
		database = new Sequelize('sqlite::memory:', { logging: false });
		const queryInterface = database.getQueryInterface();
		await queryInterface.createTable('franchisees', {
			id: { type: DataTypes.UUID, primaryKey: true },
		});
		await queryInterface.createTable('clients', {
			id: { type: DataTypes.UUID, primaryKey: true },
			franchisee_id: { type: DataTypes.UUID, allowNull: false },
		});
	});

	afterEach(async () => {
		await database.close();
	});

	it('is additive, forward-idempotent, non-destructive down, and reapplicable', async () => {
		const queryInterface = database.getQueryInterface();
		const tenantId = '50000000-0000-4000-8000-000000000001';
		const clientId = '50000000-0000-4000-8000-000000000002';
		const uploadId = '50000000-0000-4000-8000-000000000003';
		await queryInterface.bulkInsert('franchisees', [{ id: tenantId }]);
		await queryInterface.bulkInsert('clients', [{ id: clientId, franchisee_id: tenantId }]);

		await migration.up(queryInterface, Sequelize);
		await migration.up(queryInterface, Sequelize);
		await queryInterface.bulkInsert('client_photo_uploads', [
			{
				franchisee_id: tenantId,
				upload_id: uploadId,
				client_id: clientId,
				file_sha256: 'a'.repeat(64),
				canonical_url: `/api/photos/client/${clientId}/${uploadId}.jpg`,
				storage_key: `${uploadId}.jpg`,
				response_cursor: '4',
				status: 'completed',
				deleted_at: null,
				created_at: new Date('2026-07-31T00:00:00.000Z'),
				updated_at: new Date('2026-07-31T00:00:00.000Z'),
			},
		]);
		expect(await queryInterface.showIndex('client_photo_uploads')).toEqual(
			expect.arrayContaining([
				expect.objectContaining({ name: 'client_photo_uploads_tenant_client' }),
			]),
		);

		await migration.down(queryInterface, Sequelize);
		expect(await queryInterface.showAllTables()).toContain('client_photo_uploads');
		expect(
			await database.query(
				'SELECT franchisee_id, upload_id, canonical_url FROM client_photo_uploads',
				{
					type: QueryTypes.SELECT,
				},
			),
		).toEqual([
			{
				franchisee_id: tenantId,
				upload_id: uploadId,
				canonical_url: `/api/photos/client/${clientId}/${uploadId}.jpg`,
			},
		]);

		await migration.up(queryInterface, Sequelize);
		expect(await queryInterface.showIndex('client_photo_uploads')).toEqual(
			expect.arrayContaining([
				expect.objectContaining({ name: 'client_photo_uploads_tenant_client' }),
			]),
		);
	});
});
