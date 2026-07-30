'use strict';

const assert = require('assert/strict');
const { DataTypes, QueryTypes, Sequelize } = require('sequelize');

const cleanupMigration = require('../migrations/20260730000000-add-managed-file-cleanups.js');
const deletionMigration = require('../migrations/20260730010000-add-warranty-deletion-tombstones.js');

const databaseUrl = process.env.APP110_POSTGRES_URL;
if (!databaseUrl) {
	throw new Error('APP110_POSTGRES_URL is required.');
}
const databaseName = new URL(databaseUrl).pathname.slice(1);
if (!databaseName.startsWith('app110_proof_')) {
	throw new Error(
		'Refusing destructive proof outside a disposable app110_proof_* database.',
	);
}

const database = new Sequelize(databaseUrl, {
	logging: false,
	pool: { min: 0, max: 5 },
});

const clientId = '10000000-0000-0000-0000-000000000001';
const franchiseeId = '10000000-0000-0000-0000-000000000002';
const legacyId = '10000000-0000-0000-0000-000000000003';
const activeId = '10000000-0000-0000-0000-000000000004';
const tombstonedLiveId = '10000000-0000-0000-0000-000000000005';
const updateSourceId = '10000000-0000-0000-0000-000000000006';
const raceId = '10000000-0000-0000-0000-000000000007';

const createBaseSchema = async () => {
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
	return queryInterface;
};

const resetPublicSchema = async () => {
	await database.query('DROP SCHEMA public CASCADE');
	await database.query('CREATE SCHEMA public');
};

const expectDatabaseRejection = async (promise, label) => {
	let rejected = false;
	try {
		await promise;
	} catch {
		rejected = true;
	}
	assert.equal(rejected, true, label);
};

const insertLiveWarranty = (id, transaction) =>
	database.query(
		`INSERT INTO warranties
     (id, client_id, pdf_file_name, deleted_at, version)
     VALUES (:id, :clientId, :filename, NULL, 1)`,
		{
			replacements: {
				id,
				clientId,
				filename: `${id}.pdf`,
			},
			transaction,
		},
	);

const main = async () => {
	await database.authenticate();
	const queryInterface = await createBaseSchema();
	await queryInterface.bulkInsert('clients', [
		{ id: clientId, franchisee_id: franchiseeId, deleted_at: null },
	]);
	await queryInterface.bulkInsert('warranties', [
		{
			id: legacyId,
			client_id: clientId,
			pdf_file_name: 'legacy-proof.pdf',
			deleted_at: new Date('2026-07-01T00:00:00.000Z'),
		},
		{
			id: activeId,
			client_id: clientId,
			pdf_file_name: 'active-proof.pdf',
			deleted_at: null,
		},
	]);

	await deletionMigration.up(queryInterface, Sequelize);
	await deletionMigration.up(queryInterface, Sequelize);
	assert.equal(
		Number(
			(
				await database.query(
					'SELECT COUNT(*) AS count FROM warranties WHERE id = :id',
					{ replacements: { id: legacyId }, type: QueryTypes.SELECT },
				)
			)[0].count,
		),
		0,
		'legacy soft-deleted warranty must be hard-deleted',
	);
	assert.deepEqual(
		await database.query(
			`SELECT storage_key, kind
       FROM managed_file_cleanups
       WHERE storage_key = 'legacy-proof.pdf'`,
			{ type: QueryTypes.SELECT },
		),
		[{ storage_key: 'legacy-proof.pdf', kind: 'pdf' }],
	);

	await deletionMigration.down(queryInterface, Sequelize);
	assert(
		(await queryInterface.showAllTables()).includes('warranty_uuid_reservations'),
		'down must retain UUID reservations',
	);
	await expectDatabaseRejection(
		insertLiveWarranty(legacyId),
		'old writer insert after down must not resurrect a tombstoned UUID',
	);

	await insertLiveWarranty(tombstonedLiveId);
	await database.query(
		`INSERT INTO warranty_deletion_tombstones
     (warranty_id, franchisee_id, deletion_sequence, deleted_at)
     VALUES (:id, :franchiseeId, 2, CURRENT_TIMESTAMP)`,
		{ replacements: { id: tombstonedLiveId, franchiseeId } },
	);
	await database.query('DELETE FROM warranties WHERE id = :id', {
		replacements: { id: tombstonedLiveId },
	});
	await expectDatabaseRejection(
		insertLiveWarranty(tombstonedLiveId),
		'insert after tombstone must fail',
	);
	await insertLiveWarranty(updateSourceId);
	await expectDatabaseRejection(
		database.query('UPDATE warranties SET id = :target WHERE id = :source', {
			replacements: { target: tombstonedLiveId, source: updateSourceId },
		}),
		'ID update to a tombstoned UUID must fail',
	);

	// Reapply after the intentionally non-destructive down. This proves the
	// forward migration is idempotent and recreates only the same triggers.
	await deletionMigration.up(queryInterface, Sequelize);
	assert.equal(
		Number(
			(
				await database.query(
					`SELECT COUNT(*) AS count
           FROM pg_trigger
           WHERE NOT tgisinternal
             AND tgname IN (
               'warranties_reserve_uuid_insert',
               'warranties_reserve_uuid_update',
               'warranty_tombstones_reserve_uuid'
             )`,
					{ type: QueryTypes.SELECT },
				)
			)[0].count,
		),
		3,
		'reapply must leave exactly one copy of each guard trigger',
	);

	// A rolled-back writer that starts while the tombstone transaction holds
	// the reservation row must wake after commit and still fail.
	await insertLiveWarranty(raceId);
	const tombstoneTransaction = await database.transaction();
	await database.query(
		`INSERT INTO warranty_deletion_tombstones
     (warranty_id, franchisee_id, deletion_sequence, deleted_at)
     VALUES (:id, :franchiseeId, 3, CURRENT_TIMESTAMP)`,
		{
			replacements: { id: raceId, franchiseeId },
			transaction: tombstoneTransaction,
		},
	);
	const oldWriterRejected = insertLiveWarranty(raceId).then(
		() => false,
		() => true,
	);
	await new Promise((resolve) => setTimeout(resolve, 100));
	await database.query('DELETE FROM warranties WHERE id = :id', {
		replacements: { id: raceId },
		transaction: tombstoneTransaction,
	});
	await tombstoneTransaction.commit();
	assert.equal(
		await oldWriterRejected,
		true,
		'concurrent old writer must lose to the committed tombstone',
	);

	await resetPublicSchema();
	const orphanQueryInterface = await createBaseSchema();
	await orphanQueryInterface.bulkInsert('warranties', [
		{
			id: legacyId,
			client_id: clientId,
			pdf_file_name: 'orphan-proof.pdf',
			deleted_at: new Date('2026-07-01T00:00:00.000Z'),
		},
	]);
	await expectDatabaseRejection(
		deletionMigration.up(orphanQueryInterface, Sequelize),
		'orphaned legacy warranty must abort migration',
	);
	assert.deepEqual(
		await database.query('SELECT id FROM warranties', {
			type: QueryTypes.SELECT,
		}),
		[{ id: legacyId }],
		'orphan failure must retain the legacy row',
	);

	process.stdout.write(
		`${JSON.stringify({
			dialect: database.getDialect(),
			forward: 'passed',
			idempotent: 'passed',
			down_guard_retained: 'passed',
			rollback_old_writer: 'passed',
			insert_and_id_update_blocked: 'passed',
			concurrency: 'passed',
			legacy_cleanup_enqueued: 'passed',
			orphan_rollback: 'passed',
		})}\n`,
	);
};

main()
	.finally(() => database.close())
	.catch((error) => {
		console.error(error);
		process.exitCode = 1;
	});
