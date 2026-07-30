'use strict';

const { randomUUID } = require('crypto');
const { QueryTypes } = require('sequelize');

const tombstoneTable = 'warranty_deletion_tombstones';
const sequenceTable = 'warranty_deletion_sequence';
const reservationTable = 'warranty_uuid_reservations';
const cleanupTable = 'managed_file_cleanups';
const managedPdfFilename = /^[a-z0-9][a-z0-9._-]{0,240}\.pdf$/i;

const hasTable = async (queryInterface, table, transaction) => {
	const tables = await queryInterface.showAllTables(
		transaction ? { transaction } : undefined,
	);
	return tables.includes(table);
};

const requireTable = async (queryInterface, table) => {
	if (!(await hasTable(queryInterface, table))) {
		throw new Error(
			`Required table "${table}" does not exist. This is a delta migration for an existing Damsure database; do not use it to initialise an empty database.`,
		);
	}
};

const hasColumn = async (queryInterface, table, column, transaction) => {
	const columns = await queryInterface.describeTable(
		table,
		transaction ? { transaction } : undefined,
	);
	return Object.prototype.hasOwnProperty.call(columns, column);
};

const ensureIndex = async (queryInterface, fields, options, transaction) => {
	const indexes = await queryInterface.showIndex(tombstoneTable, { transaction });
	if (!indexes.some((index) => index.name === options.name)) {
		await queryInterface.addIndex(tombstoneTable, fields, {
			...options,
			transaction,
		});
	}
};

const reserveExistingWarrantyIds = async (queryInterface, transaction) => {
	const liveIds = await queryInterface.sequelize.query('SELECT id FROM warranties', {
		type: QueryTypes.SELECT,
		transaction,
	});
	for (const { id } of liveIds) {
		await queryInterface.sequelize.query(
			`INSERT INTO ${reservationTable} (warranty_id, reservation_state)
       VALUES (:warrantyId, 'live')
       ON CONFLICT (warranty_id) DO NOTHING`,
			{ replacements: { warrantyId: id }, transaction },
		);
	}

	const tombstoneIds = await queryInterface.sequelize.query(
		`SELECT warranty_id FROM ${tombstoneTable}`,
		{ type: QueryTypes.SELECT, transaction },
	);
	for (const { warranty_id: warrantyId } of tombstoneIds) {
		await queryInterface.sequelize.query(
			`INSERT INTO ${reservationTable} (warranty_id, reservation_state)
       VALUES (:warrantyId, 'tombstoned')
       ON CONFLICT (warranty_id)
       DO UPDATE SET reservation_state = 'tombstoned'`,
			{ replacements: { warrantyId }, transaction },
		);
	}
};

const installReservationGuard = async (queryInterface, transaction) => {
	const dialect = queryInterface.sequelize.getDialect();
	if (dialect === 'postgres') {
		await queryInterface.sequelize.query(
			`CREATE OR REPLACE FUNCTION reserve_live_warranty_uuid()
       RETURNS trigger AS $$
       DECLARE current_state varchar(16);
       BEGIN
         INSERT INTO ${reservationTable} (warranty_id, reservation_state)
         VALUES (NEW.id, 'live')
         ON CONFLICT (warranty_id) DO NOTHING;
         SELECT reservation_state INTO current_state
         FROM ${reservationTable}
         WHERE warranty_id = NEW.id
         FOR UPDATE;
         IF current_state = 'tombstoned' THEN
           RAISE EXCEPTION 'warranty UUID is permanently tombstoned'
             USING ERRCODE = '23505',
                   CONSTRAINT = 'warranty_uuid_not_tombstoned';
         END IF;
         RETURN NEW;
       END;
       $$ LANGUAGE plpgsql`,
			{ transaction },
		);
		await queryInterface.sequelize.query(
			`CREATE OR REPLACE FUNCTION reserve_tombstoned_warranty_uuid()
       RETURNS trigger AS $$
       BEGIN
         INSERT INTO ${reservationTable} (warranty_id, reservation_state)
         VALUES (NEW.warranty_id, 'tombstoned')
         ON CONFLICT (warranty_id)
         DO UPDATE SET reservation_state = 'tombstoned';
         RETURN NEW;
       END;
       $$ LANGUAGE plpgsql`,
			{ transaction },
		);
		await queryInterface.sequelize.query(
			'DROP TRIGGER IF EXISTS warranties_reserve_uuid_insert ON warranties',
			{ transaction },
		);
		await queryInterface.sequelize.query(
			'DROP TRIGGER IF EXISTS warranties_reserve_uuid_update ON warranties',
			{ transaction },
		);
		await queryInterface.sequelize.query(
			`DROP TRIGGER IF EXISTS warranty_tombstones_reserve_uuid
       ON ${tombstoneTable}`,
			{ transaction },
		);
		await queryInterface.sequelize.query(
			`CREATE TRIGGER warranties_reserve_uuid_insert
       BEFORE INSERT ON warranties
       FOR EACH ROW EXECUTE FUNCTION reserve_live_warranty_uuid()`,
			{ transaction },
		);
		await queryInterface.sequelize.query(
			`CREATE TRIGGER warranties_reserve_uuid_update
       BEFORE UPDATE OF id ON warranties
       FOR EACH ROW EXECUTE FUNCTION reserve_live_warranty_uuid()`,
			{ transaction },
		);
		await queryInterface.sequelize.query(
			`CREATE TRIGGER warranty_tombstones_reserve_uuid
       BEFORE INSERT ON ${tombstoneTable}
       FOR EACH ROW EXECUTE FUNCTION reserve_tombstoned_warranty_uuid()`,
			{ transaction },
		);
		return;
	}

	if (dialect !== 'sqlite') {
		throw new Error(`APP-110 warranty UUID reservation guard does not support ${dialect}.`);
	}
	for (const trigger of [
		'warranties_reserve_uuid_insert',
		'warranties_reserve_uuid_update',
		'warranty_tombstones_reserve_uuid',
	]) {
		await queryInterface.sequelize.query(`DROP TRIGGER IF EXISTS ${trigger}`, {
			transaction,
		});
	}
	await queryInterface.sequelize.query(
		`CREATE TRIGGER warranties_reserve_uuid_insert
     BEFORE INSERT ON warranties
     FOR EACH ROW
     BEGIN
       INSERT OR IGNORE INTO ${reservationTable} (warranty_id, reservation_state)
       VALUES (NEW.id, 'live');
       SELECT RAISE(ABORT, 'warranty UUID is permanently tombstoned')
       WHERE EXISTS (
         SELECT 1 FROM ${reservationTable}
         WHERE warranty_id = NEW.id AND reservation_state = 'tombstoned'
       );
     END`,
		{ transaction },
	);
	await queryInterface.sequelize.query(
		`CREATE TRIGGER warranties_reserve_uuid_update
     BEFORE UPDATE OF id ON warranties
     FOR EACH ROW
     BEGIN
       INSERT OR IGNORE INTO ${reservationTable} (warranty_id, reservation_state)
       VALUES (NEW.id, 'live');
       SELECT RAISE(ABORT, 'warranty UUID is permanently tombstoned')
       WHERE EXISTS (
         SELECT 1 FROM ${reservationTable}
         WHERE warranty_id = NEW.id AND reservation_state = 'tombstoned'
       );
     END`,
		{ transaction },
	);
	await queryInterface.sequelize.query(
		`CREATE TRIGGER warranty_tombstones_reserve_uuid
     BEFORE INSERT ON ${tombstoneTable}
     FOR EACH ROW
     BEGIN
       INSERT INTO ${reservationTable} (warranty_id, reservation_state)
       VALUES (NEW.warranty_id, 'tombstoned')
       ON CONFLICT (warranty_id)
       DO UPDATE SET reservation_state = 'tombstoned';
     END`,
		{ transaction },
	);
};

module.exports = {
	async up(queryInterface, Sequelize) {
		await Promise.all(
			['clients', 'warranties', cleanupTable].map((table) =>
				requireTable(queryInterface, table),
			),
		);

		await queryInterface.sequelize.transaction(async (transaction) => {
			if (!(await hasColumn(queryInterface, 'warranties', 'version', transaction))) {
				await queryInterface.addColumn(
					'warranties',
					'version',
					{
						type: Sequelize.INTEGER,
						allowNull: false,
						defaultValue: 1,
					},
					{ transaction },
				);
			}

			if (!(await hasTable(queryInterface, sequenceTable, transaction))) {
				await queryInterface.createTable(
					sequenceTable,
					{
						id: { type: Sequelize.INTEGER, primaryKey: true, allowNull: false },
						last_value: {
							type: Sequelize.BIGINT,
							allowNull: false,
							defaultValue: 0,
						},
					},
					{ transaction },
				);
			}

			if (!(await hasTable(queryInterface, tombstoneTable, transaction))) {
				await queryInterface.createTable(
					tombstoneTable,
					{
						warranty_id: {
							type: Sequelize.UUID,
							primaryKey: true,
							allowNull: false,
						},
						franchisee_id: { type: Sequelize.UUID, allowNull: false },
						deletion_sequence: {
							type: Sequelize.BIGINT,
							allowNull: false,
							unique: true,
						},
						idempotency_key: { type: Sequelize.STRING(128), allowNull: true },
						idempotency_action: { type: Sequelize.STRING(32), allowNull: true },
						request_digest: { type: Sequelize.STRING(64), allowNull: true },
						replacement_warranty_id: { type: Sequelize.UUID, allowNull: true },
						deleted_at: { type: Sequelize.DATE, allowNull: false },
					},
					{ transaction },
				);
			}
			if (
				!(await hasColumn(
					queryInterface,
					tombstoneTable,
					'idempotency_action',
					transaction,
				))
			) {
				await queryInterface.addColumn(
					tombstoneTable,
					'idempotency_action',
					{ type: Sequelize.STRING(32), allowNull: true },
					{ transaction },
				);
			}
			if (
				!(await hasColumn(
					queryInterface,
					tombstoneTable,
					'request_digest',
					transaction,
				))
			) {
				await queryInterface.addColumn(
					tombstoneTable,
					'request_digest',
					{ type: Sequelize.STRING(64), allowNull: true },
					{ transaction },
				);
			}

			if (!(await hasTable(queryInterface, reservationTable, transaction))) {
				await queryInterface.createTable(
					reservationTable,
					{
						warranty_id: {
							type: Sequelize.UUID,
							primaryKey: true,
							allowNull: false,
						},
						reservation_state: {
							type: Sequelize.STRING(16),
							allowNull: false,
						},
					},
					{ transaction },
				);
			}

			await ensureIndex(
				queryInterface,
				['franchisee_id', 'deletion_sequence'],
				{ name: 'warranty_deletion_tombstones_tenant_cursor' },
				transaction,
			);
			await ensureIndex(
				queryInterface,
				['franchisee_id', 'idempotency_key'],
				{
					name: 'warranty_deletion_tombstones_tenant_idempotency_unique',
					unique: true,
				},
				transaction,
			);

			const sequenceRows = await queryInterface.sequelize.query(
				`SELECT last_value FROM ${sequenceTable} WHERE id = 1`,
				{ type: QueryTypes.SELECT, transaction },
			);
			if (!sequenceRows.length) {
				await queryInterface.bulkInsert(sequenceTable, [{ id: 1, last_value: 0 }], {
					transaction,
				});
			}

			// Roll forward this migration before deploying APP-110 application
			// writers. The permanent database guard deliberately remains installed
			// across application rollback so an older writer cannot resurrect a
			// tombstoned UUID.
			await reserveExistingWarrantyIds(queryInterface, transaction);
			await installReservationGuard(queryInterface, transaction);

			// Backfill first, then hard-delete. If an orphaned warranty cannot derive
			// its tenant from the trusted client parent, abort without deleting it.
			const hasPdfFileName = await hasColumn(
				queryInterface,
				'warranties',
				'pdf_file_name',
				transaction,
			);
			const legacyWarranties = await queryInterface.sequelize.query(
				`SELECT w.id, w.deleted_at, c.franchisee_id,
                ${hasPdfFileName ? 'w.pdf_file_name' : 'NULL AS pdf_file_name'}
         FROM warranties w
         LEFT JOIN clients c ON c.id = w.client_id
         WHERE w.deleted_at IS NOT NULL
         ORDER BY w.deleted_at ASC, w.id ASC`,
				{ type: QueryTypes.SELECT, transaction },
			);
			if (legacyWarranties.some((warranty) => !warranty.franchisee_id)) {
				throw new Error(
					'Cannot backfill legacy warranty tombstones because at least one soft-deleted warranty has no tenant-owned client.',
				);
			}

			const existingTombstones = await queryInterface.sequelize.query(
				`SELECT warranty_id, deletion_sequence FROM ${tombstoneTable}`,
				{ type: QueryTypes.SELECT, transaction },
			);
			const reservedIds = new Set(existingTombstones.map((row) => row.warranty_id));
			let lastValue = existingTombstones.reduce(
				(maximum, row) =>
					BigInt(row.deletion_sequence) > maximum
						? BigInt(row.deletion_sequence)
						: maximum,
				0n,
			);

			for (const warranty of legacyWarranties) {
				if (!reservedIds.has(warranty.id)) {
					lastValue += 1n;
					await queryInterface.bulkInsert(
						tombstoneTable,
						[
							{
								warranty_id: warranty.id,
								franchisee_id: warranty.franchisee_id,
								deletion_sequence: lastValue.toString(),
								idempotency_key: null,
								idempotency_action: null,
								request_digest: null,
								replacement_warranty_id: null,
								deleted_at: warranty.deleted_at,
							},
						],
						{ transaction },
					);
					reservedIds.add(warranty.id);
				}
				if (
					warranty.pdf_file_name &&
					managedPdfFilename.test(warranty.pdf_file_name)
				) {
					const now = new Date();
					await queryInterface.sequelize.query(
						`INSERT INTO ${cleanupTable}
             (id, storage_key, kind, attempts, next_attempt_at, last_error,
              exhausted_at, created_at, updated_at)
             VALUES (:id, :storageKey, 'pdf', 0, :now, NULL, NULL, :now, :now)
             ON CONFLICT (storage_key) DO NOTHING`,
						{
							replacements: {
								id: randomUUID(),
								storageKey: warranty.pdf_file_name,
								now,
							},
							transaction,
						},
					);
				}
			}

			if (legacyWarranties.length) {
				await queryInterface.bulkDelete(
					'warranties',
					{ deleted_at: { [Sequelize.Op.ne]: null } },
					{ transaction },
				);
			}
			await queryInterface.bulkUpdate(
				sequenceTable,
				{ last_value: lastValue.toString() },
				{ id: 1 },
				{ transaction },
			);
		});
	},

	async down() {
		// Intentionally non-destructive. Removing the version column, cursor,
		// tombstones, reservation table, or database triggers would permit an
		// old/rolled-back writer or stale device to resurrect a warranty UUID.
	},
};
