'use strict';

const table = 'client_photo_uploads';
const clientIndex = 'client_photo_uploads_tenant_client';

const hasTable = async (queryInterface) =>
	(await queryInterface.showAllTables()).map((name) => String(name)).includes(table);

const hasIndex = async (queryInterface, name) =>
	(await queryInterface.showIndex(table)).some((index) => index.name === name);

const ensureColumn = async (queryInterface, name, definition, transaction) => {
	const columns = await queryInterface.describeTable(table);
	if (!columns[name]) await queryInterface.addColumn(table, name, definition, { transaction });
};

module.exports = {
	async up(queryInterface, Sequelize) {
		await queryInterface.sequelize.transaction(async (transaction) => {
			if (!(await hasTable(queryInterface))) {
				await queryInterface.createTable(
					table,
					{
						franchisee_id: {
							type: Sequelize.UUID,
							primaryKey: true,
							allowNull: false,
							references: { model: 'franchisees', key: 'id' },
						},
						upload_id: { type: Sequelize.UUID, primaryKey: true, allowNull: false },
						client_id: {
							type: Sequelize.UUID,
							allowNull: false,
							references: { model: 'clients', key: 'id' },
						},
						file_sha256: { type: Sequelize.STRING(64), allowNull: false },
						canonical_url: { type: Sequelize.STRING(255), allowNull: false },
						storage_key: { type: Sequelize.STRING(255), allowNull: false },
						response_cursor: { type: Sequelize.BIGINT, allowNull: false },
						status: {
							type: Sequelize.STRING(16),
							allowNull: false,
							defaultValue: 'staged',
						},
						deleted_at: { type: Sequelize.DATE, allowNull: true },
						created_at: { type: Sequelize.DATE, allowNull: false },
						updated_at: { type: Sequelize.DATE, allowNull: false },
					},
					{ transaction },
				);
			} else {
				// This branch supports a paused pre-release rollout without rewriting
				// or removing any completed receipt rows.
				await ensureColumn(
					queryInterface,
					'file_sha256',
					{ type: Sequelize.STRING(64), allowNull: true },
					transaction,
				);
				await ensureColumn(
					queryInterface,
					'response_cursor',
					{ type: Sequelize.BIGINT, allowNull: true },
					transaction,
				);
				await ensureColumn(
					queryInterface,
					'deleted_at',
					{ type: Sequelize.DATE, allowNull: true },
					transaction,
				);
				await ensureColumn(
					queryInterface,
					'status',
					{ type: Sequelize.STRING(16), allowNull: true },
					transaction,
				);
			}
			if (!(await hasIndex(queryInterface, clientIndex))) {
				await queryInterface.addIndex(table, ['franchisee_id', 'client_id'], {
					name: clientIndex,
					transaction,
				});
			}
		});
	},

	async down(queryInterface) {
		// Retain successful upload receipts and their canonical-asset mapping.
		// Deleting them would make an ambiguous retry duplicate server media.
		if (await hasTable(queryInterface)) {
			if (await hasIndex(queryInterface, clientIndex)) {
				await queryInterface.removeIndex(table, clientIndex);
			}
		}
	},
};
