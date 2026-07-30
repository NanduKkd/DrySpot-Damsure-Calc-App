'use strict';

const { QueryTypes } = require('sequelize');

const tombstoneTable = 'warranty_deletion_tombstones';
const sequenceTable = 'warranty_deletion_sequence';

const hasTable = async (queryInterface, table) => {
	const tables = await queryInterface.showAllTables();
	return tables.includes(table);
};

const requireTable = async (queryInterface, table) => {
	if (!(await hasTable(queryInterface, table))) {
		throw new Error(
			`Required table "${table}" does not exist. This is a delta migration for an existing Damsure database; do not use it to initialise an empty database.`,
		);
	}
};

const hasColumn = async (queryInterface, table, column) => {
	const columns = await queryInterface.describeTable(table);
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

module.exports = {
	async up(queryInterface, Sequelize) {
		await Promise.all(
			['clients', 'warranties'].map((table) => requireTable(queryInterface, table)),
		);

		await queryInterface.sequelize.transaction(async (transaction) => {
			if (!(await hasColumn(queryInterface, 'warranties', 'version'))) {
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

			if (!(await hasTable(queryInterface, sequenceTable))) {
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

			if (!(await hasTable(queryInterface, tombstoneTable))) {
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
						replacement_warranty_id: { type: Sequelize.UUID, allowNull: true },
						deleted_at: { type: Sequelize.DATE, allowNull: false },
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

			// Backfill first, then hard-delete. If an orphaned warranty cannot derive
			// its tenant from the trusted client parent, abort without deleting it.
			const legacyWarranties = await queryInterface.sequelize.query(
				`SELECT w.id, w.deleted_at, c.franchisee_id
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
								replacement_warranty_id: null,
								deleted_at: warranty.deleted_at,
							},
						],
						{ transaction },
					);
					reservedIds.add(warranty.id);
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
		// Intentionally non-destructive. Removing the version column, cursor, or
		// permanent UUID reservations would permit stale-device resurrection.
	},
};
