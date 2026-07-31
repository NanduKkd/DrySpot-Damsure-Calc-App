'use strict';

const assert = require('assert/strict');
const { DataTypes, QueryTypes, Sequelize } = require('sequelize');
const migration = require('../migrations/20260731000000-add-client-photo-upload-idempotency.js');

const databaseUrl = process.env.APP112_POSTGRES_URL;
if (!databaseUrl) throw new Error('APP112_POSTGRES_URL is required.');
const databaseName = new URL(databaseUrl).pathname.slice(1);
if (!databaseName.startsWith('app112_proof_')) {
	throw new Error('Refusing destructive proof outside a disposable app112_proof_* database.');
}

const database = new Sequelize(databaseUrl, { logging: false });
const tenantId = '60000000-0000-4000-8000-000000000001';
const clientId = '60000000-0000-4000-8000-000000000002';
const uploadId = '60000000-0000-4000-8000-000000000003';

const main = async () => {
	await database.authenticate();
	await database.query('DROP SCHEMA public CASCADE');
	await database.query('CREATE SCHEMA public');
	const queryInterface = database.getQueryInterface();
	await queryInterface.createTable('franchisees', {
		id: { type: DataTypes.UUID, primaryKey: true },
	});
	await queryInterface.createTable('clients', {
		id: { type: DataTypes.UUID, primaryKey: true },
		franchisee_id: { type: DataTypes.UUID, allowNull: false },
	});
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
			response_cursor: '1',
			status: 'completed',
			created_at: new Date(),
			updated_at: new Date(),
		},
	]);
	await migration.down(queryInterface, Sequelize);
	assert.equal(
		(
			await database.query('SELECT count(*)::int AS count FROM client_photo_uploads', {
				type: QueryTypes.SELECT,
			})
		)[0].count,
		1,
	);
	await migration.up(queryInterface, Sequelize);
	assert.ok(
		(await queryInterface.showIndex('client_photo_uploads')).some(
			(index) => index.name === 'client_photo_uploads_tenant_client',
		),
	);
	console.log('APP-112 PostgreSQL migration proof passed');
};

main()
	.catch((error) => {
		console.error(error);
		process.exitCode = 1;
	})
	.finally(() => database.close());
