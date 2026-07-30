'use strict';

const { createHash } = require('crypto');
const { QueryTypes } = require('sequelize');

const entityTables = ['clients', 'items', 'rectangles', 'default_prices'];
const auxiliaryTables = ['warranties', 'proposals'];
const syncVisibleTables = [...entityTables, ...auxiliaryTables];
const maxBigint = 9223372036854775807n;
const maxBranchSequence = 1000000;
const uuidV4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const sha256Hex = /^[0-9a-f]{64}$/;

const stableValue = (value) => {
	if (Array.isArray(value)) return value.map(stableValue);
	if (value && typeof value === 'object') {
		return Object.fromEntries(
			Object.keys(value)
				.sort()
				.map((key) => [key, stableValue(value[key])]),
		);
	}
	return value;
};

const canonicalJson = (value) => JSON.stringify(stableValue(value));
const sha256 = (value) => createHash('sha256').update(canonicalJson(value)).digest('hex');

const deterministicUuidV4 = (seed) => {
	const bytes = createHash('sha256').update(seed).digest().subarray(0, 16);
	bytes[6] = (bytes[6] & 0x0f) | 0x40;
	bytes[8] = (bytes[8] & 0x3f) | 0x80;
	const hex = bytes.toString('hex');
	return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(
		16,
		20,
	)}-${hex.slice(20)}`;
};

const hasTable = async (queryInterface, table, transaction) =>
	(await queryInterface.showAllTables({ transaction })).includes(table);

const describe = async (queryInterface, table, transaction) =>
	queryInterface.describeTable(table, { transaction });

const ensureColumn = async (queryInterface, table, column, definition, transaction) => {
	const columns = await describe(queryInterface, table, transaction);
	if (!columns[column]) {
		await queryInterface.addColumn(table, column, definition, { transaction });
	}
};

const ensureIndex = async (queryInterface, table, fields, options, transaction) => {
	const indexes = await queryInterface.showIndex(table, { transaction });
	if (!indexes.some((index) => index.name === options.name)) {
		await queryInterface.addIndex(table, fields, { ...options, transaction });
	}
};

const normalizeBoolean = (value) =>
	value === true || value === 1 || value === '1' || value === 'true';

const payloadFor = (entity, row) => {
	switch (entity) {
		case 'clients':
			return {
				address: row.address ?? null,
				discounted_price:
					row.discounted_price === null || row.discounted_price === undefined
						? null
						: Number(row.discounted_price),
				email: row.email ?? null,
				latitude:
					row.latitude === null || row.latitude === undefined
						? null
						: Number(row.latitude),
				longitude:
					row.longitude === null || row.longitude === undefined
						? null
						: Number(row.longitude),
				name: row.name,
				phone: row.phone ?? null,
				site_address: row.site_address ?? null,
			};
		case 'items':
			return {
				enabled: normalizeBoolean(row.enabled),
				name: row.name,
				price: Number(row.price),
			};
		case 'rectangles':
			return {
				length: Number(row.length),
				width: Number(row.width),
			};
		case 'default_prices':
			return {
				enabled: normalizeBoolean(row.enabled),
				price: Number(row.price),
			};
		default:
			throw new Error(`Unknown LWW entity ${entity}`);
	}
};

const entityRows = async (queryInterface, entity, transaction) => {
	const sequelize = queryInterface.sequelize;
	switch (entity) {
		case 'clients':
			return sequelize.query(
				`SELECT c.*, c.franchisee_id AS resolved_franchisee_id
         FROM clients c`,
				{ type: QueryTypes.SELECT, transaction },
			);
		case 'items':
			return sequelize.query(
				`SELECT i.*, c.franchisee_id AS resolved_franchisee_id
         FROM items i
         LEFT JOIN clients c ON c.id = i.client_id`,
				{ type: QueryTypes.SELECT, transaction },
			);
		case 'rectangles':
			return sequelize.query(
				`SELECT r.*, c.franchisee_id AS resolved_franchisee_id
         FROM rectangles r
         LEFT JOIN items i ON i.id = r.item_id
         LEFT JOIN clients c ON c.id = i.client_id`,
				{ type: QueryTypes.SELECT, transaction },
			);
		case 'default_prices':
			return sequelize.query(
				`SELECT d.*, d.franchisee_id AS resolved_franchisee_id
         FROM default_prices d`,
				{ type: QueryTypes.SELECT, transaction },
			);
		default:
			return [];
	}
};

const createProtocolTables = async (queryInterface, Sequelize, transaction) => {
	if (!(await hasTable(queryInterface, 'tenant_sync_state', transaction))) {
		await queryInterface.createTable(
			'tenant_sync_state',
			{
				franchisee_id: {
					type: Sequelize.UUID,
					primaryKey: true,
					allowNull: false,
					references: { model: 'franchisees', key: 'id' },
				},
				cursor: {
					type: Sequelize.BIGINT,
					allowNull: false,
					defaultValue: '1',
				},
				created_at: { type: Sequelize.DATE, allowNull: false },
				updated_at: { type: Sequelize.DATE, allowNull: false },
			},
			{ transaction },
		);
	}

	if (!(await hasTable(queryInterface, 'sync_v2_requests', transaction))) {
		await queryInterface.createTable(
			'sync_v2_requests',
			{
				franchisee_id: {
					type: Sequelize.UUID,
					primaryKey: true,
					allowNull: false,
					references: { model: 'franchisees', key: 'id' },
				},
				request_id: {
					type: Sequelize.UUID,
					primaryKey: true,
					allowNull: false,
				},
				request_hash: { type: Sequelize.STRING(64), allowNull: false },
				response_cursor: { type: Sequelize.BIGINT, allowNull: false },
				response_json: { type: Sequelize.TEXT, allowNull: false },
				created_at: { type: Sequelize.DATE, allowNull: false },
				updated_at: { type: Sequelize.DATE, allowNull: false },
			},
			{ transaction },
		);
	}

	if (!(await hasTable(queryInterface, 'sync_v2_change_receipts', transaction))) {
		await queryInterface.createTable(
			'sync_v2_change_receipts',
			{
				franchisee_id: {
					type: Sequelize.UUID,
					primaryKey: true,
					allowNull: false,
					references: { model: 'franchisees', key: 'id' },
				},
				change_id: {
					type: Sequelize.UUID,
					primaryKey: true,
					allowNull: false,
				},
				entity_type: { type: Sequelize.STRING(32), allowNull: false },
				entity_id: { type: Sequelize.UUID, allowNull: false },
				generation: { type: Sequelize.BIGINT, allowNull: false },
				branch_seq: { type: Sequelize.INTEGER, allowNull: false },
				operation_rank: { type: Sequelize.SMALLINT, allowNull: false },
				writer_id: { type: Sequelize.UUID, allowNull: false },
				payload_hash: { type: Sequelize.STRING(64), allowNull: false },
				change_hash: { type: Sequelize.STRING(64), allowNull: true },
				outcome_json: { type: Sequelize.TEXT, allowNull: true },
				created_at: { type: Sequelize.DATE, allowNull: false },
				updated_at: { type: Sequelize.DATE, allowNull: false },
			},
			{ transaction },
		);
	} else {
		await ensureColumn(
			queryInterface,
			'sync_v2_change_receipts',
			'change_hash',
			{ type: Sequelize.STRING(64), allowNull: true },
			transaction,
		);
		await ensureColumn(
			queryInterface,
			'sync_v2_change_receipts',
			'outcome_json',
			{ type: Sequelize.TEXT, allowNull: true },
			transaction,
		);
	}
};

module.exports = {
	async up(queryInterface, Sequelize) {
		await queryInterface.sequelize.transaction(async (transaction) => {
			for (const table of syncVisibleTables) {
				if (!(await hasTable(queryInterface, table, transaction))) {
					throw new Error(`APP-111 requires the existing ${table} table.`);
				}
			}
			for (const table of entityTables) {
				await ensureColumn(
					queryInterface,
					table,
					'lww_generation',
					{ type: Sequelize.BIGINT, allowNull: true },
					transaction,
				);
				await ensureColumn(
					queryInterface,
					table,
					'lww_branch_seq',
					{ type: Sequelize.INTEGER, allowNull: true },
					transaction,
				);
				await ensureColumn(
					queryInterface,
					table,
					'lww_operation_rank',
					{ type: Sequelize.SMALLINT, allowNull: true },
					transaction,
				);
				await ensureColumn(
					queryInterface,
					table,
					'lww_writer_id',
					{ type: Sequelize.UUID, allowNull: true },
					transaction,
				);
				await ensureColumn(
					queryInterface,
					table,
					'lww_change_id',
					{ type: Sequelize.UUID, allowNull: true },
					transaction,
				);
				await ensureColumn(
					queryInterface,
					table,
					'lww_payload_hash',
					{ type: Sequelize.STRING(64), allowNull: true },
					transaction,
				);
				await ensureColumn(
					queryInterface,
					table,
					'sync_cursor',
					{ type: Sequelize.BIGINT, allowNull: true },
					transaction,
				);
			}
			for (const table of auxiliaryTables) {
				await ensureColumn(
					queryInterface,
					table,
					'sync_cursor',
					{ type: Sequelize.BIGINT, allowNull: true },
					transaction,
				);
			}

			await createProtocolTables(queryInterface, Sequelize, transaction);

			const now = new Date();
			const tenantIds = new Set();
			for (const entity of entityTables) {
				const rows = await entityRows(queryInterface, entity, transaction);
				const inconsistent = rows.find((row) => !row.resolved_franchisee_id);
				if (inconsistent) {
					throw new Error(
						`Cannot backfill APP-111 because ${entity} row ${inconsistent.id} has no tenant-owned parent.`,
					);
				}
				for (const row of rows) {
					tenantIds.add(row.resolved_franchisee_id);
					const logicalValues = [
						row.lww_generation,
						row.lww_branch_seq,
						row.lww_operation_rank,
						row.lww_writer_id,
						row.lww_change_id,
						row.lww_payload_hash,
						row.sync_cursor,
					];
					const presentLogicalValues = logicalValues.filter(
						(value) => value !== null && value !== undefined,
					).length;
					if (
						presentLogicalValues !== 0 &&
						presentLogicalValues !== logicalValues.length
					) {
						throw new Error(
							`Cannot backfill APP-111 because ${entity} row ${row.id} has partial logical state.`,
						);
					}
					const alreadyBackfilled = presentLogicalValues === logicalValues.length;
					if (alreadyBackfilled) {
						const generation = BigInt(row.lww_generation);
						const cursor = BigInt(row.sync_cursor);
						const deleted = row.deleted_at !== null && row.deleted_at !== undefined;
						const expectedRank = deleted ? 1 : 0;
						const expectedHash = sha256(deleted ? {} : payloadFor(entity, row));
						if (
							generation < 1n ||
							generation > maxBigint ||
							cursor < 1n ||
							cursor > maxBigint ||
							!Number.isInteger(Number(row.lww_branch_seq)) ||
							Number(row.lww_branch_seq) < 1 ||
							Number(row.lww_branch_seq) > maxBranchSequence ||
							Number(row.lww_operation_rank) !== expectedRank ||
							!uuidV4.test(String(row.lww_writer_id)) ||
							!uuidV4.test(String(row.lww_change_id)) ||
							!sha256Hex.test(String(row.lww_payload_hash)) ||
							String(row.lww_payload_hash) !== expectedHash
						) {
							throw new Error(
								`Cannot reapply APP-111 because ${entity} row ${row.id} has invalid logical state.`,
							);
						}
						continue;
					}
					const deleted = row.deleted_at !== null && row.deleted_at !== undefined;
					const values = {
						lww_generation: '1',
						lww_branch_seq: 1,
						lww_operation_rank: deleted ? 1 : 0,
						lww_writer_id: deterministicUuidV4(`app-111:${entity}:${row.id}:writer`),
						lww_change_id: deterministicUuidV4(`app-111:${entity}:${row.id}:change`),
						lww_payload_hash: sha256(deleted ? {} : payloadFor(entity, row)),
						sync_cursor: '1',
					};
					await queryInterface.bulkUpdate(
						entity,
						values,
						{ id: row.id },
						{ transaction },
					);
				}
			}
			for (const table of auxiliaryTables) {
				const rows = await queryInterface.sequelize.query(
					`SELECT id, sync_cursor FROM ${table}`,
					{ type: QueryTypes.SELECT, transaction },
				);
				for (const row of rows) {
					if (row.sync_cursor === null || row.sync_cursor === undefined) {
						await queryInterface.bulkUpdate(
							table,
							{ sync_cursor: '1' },
							{ id: row.id },
							{ transaction },
						);
						continue;
					}
					const cursor = BigInt(row.sync_cursor);
					if (cursor < 1n || cursor > maxBigint) {
						throw new Error(
							`Cannot reapply APP-111 because ${table} row ${row.id} has an invalid sync cursor.`,
						);
					}
				}
			}

			if (await hasTable(queryInterface, 'franchisees', transaction)) {
				const franchisees = await queryInterface.sequelize.query(
					'SELECT id FROM franchisees',
					{ type: QueryTypes.SELECT, transaction },
				);
				franchisees.forEach((row) => tenantIds.add(row.id));
			}

			for (const franchiseeId of tenantIds) {
				const existing = await queryInterface.sequelize.query(
					`SELECT franchisee_id, cursor
           FROM tenant_sync_state
           WHERE franchisee_id = :franchiseeId`,
					{
						replacements: { franchiseeId },
						type: QueryTypes.SELECT,
						transaction,
					},
				);
				if (!existing.length) {
					await queryInterface.bulkInsert(
						'tenant_sync_state',
						[
							{
								franchisee_id: franchiseeId,
								cursor: '1',
								created_at: now,
								updated_at: now,
							},
						],
						{ transaction },
					);
				} else if (
					BigInt(existing[0].cursor) < 1n ||
					BigInt(existing[0].cursor) > maxBigint
				) {
					throw new Error(
						`Cannot backfill APP-111 because tenant ${franchiseeId} has an invalid cursor.`,
					);
				}
			}

			const tenantCursorRows = await queryInterface.sequelize.query(
				'SELECT franchisee_id, cursor FROM tenant_sync_state',
				{ type: QueryTypes.SELECT, transaction },
			);
			const tenantCursors = new Map(
				tenantCursorRows.map((row) => [row.franchisee_id, BigInt(row.cursor)]),
			);
			const requestRows = await queryInterface.sequelize.query(
				`SELECT franchisee_id, request_id, response_cursor
				 FROM sync_v2_requests`,
				{ type: QueryTypes.SELECT, transaction },
			);
			for (const row of requestRows) {
				const tenantCursor = tenantCursors.get(row.franchisee_id);
				const responseCursor = BigInt(row.response_cursor);
				if (
					tenantCursor === undefined ||
					responseCursor < 0n ||
					responseCursor > tenantCursor
				) {
					throw new Error(
						`Cannot reapply APP-111 because request ${row.request_id} has inconsistent tenant cursor state.`,
					);
				}
			}
			for (const table of entityTables) {
				const rows = await entityRows(queryInterface, table, transaction);
				for (const row of rows) {
					const tenantCursor = tenantCursors.get(row.resolved_franchisee_id);
					if (tenantCursor === undefined || BigInt(row.sync_cursor) > tenantCursor) {
						throw new Error(
							`Cannot reapply APP-111 because ${table} row ${row.id} is ahead of its tenant cursor.`,
						);
					}
				}
			}
			for (const table of auxiliaryTables) {
				const rows = await queryInterface.sequelize.query(
					`SELECT a.id, a.sync_cursor, c.franchisee_id AS resolved_franchisee_id
					 FROM ${table} a
					 LEFT JOIN clients c ON c.id = a.client_id`,
					{ type: QueryTypes.SELECT, transaction },
				);
				for (const row of rows) {
					const tenantCursor = tenantCursors.get(row.resolved_franchisee_id);
					if (
						!row.resolved_franchisee_id ||
						tenantCursor === undefined ||
						BigInt(row.sync_cursor) > tenantCursor
					) {
						throw new Error(
							`Cannot reapply APP-111 because ${table} row ${row.id} has inconsistent tenant cursor state.`,
						);
					}
				}
			}

			for (const table of entityTables) {
				const columns = await describe(queryInterface, table, transaction);
				const requiredDefinitions = {
					lww_generation: {
						type: Sequelize.BIGINT,
						allowNull: false,
						defaultValue: '1',
					},
					lww_branch_seq: {
						type: Sequelize.INTEGER,
						allowNull: false,
						defaultValue: 1,
					},
					lww_operation_rank: {
						type: Sequelize.SMALLINT,
						allowNull: false,
						defaultValue: 0,
					},
					lww_writer_id: {
						type: Sequelize.UUID,
						allowNull: false,
						defaultValue: '00000000-0000-4000-8000-000000000000',
					},
					lww_change_id: {
						type: Sequelize.UUID,
						allowNull: false,
						defaultValue: '00000000-0000-4000-8000-000000000001',
					},
					lww_payload_hash: {
						type: Sequelize.STRING(64),
						allowNull: false,
						defaultValue: '0'.repeat(64),
					},
					sync_cursor: {
						type: Sequelize.BIGINT,
						allowNull: false,
						defaultValue: '1',
					},
				};
				for (const [column, definition] of Object.entries(requiredDefinitions)) {
					if (columns[column].allowNull) {
						await queryInterface.changeColumn(table, column, definition, {
							transaction,
						});
					}
				}
			}
			for (const table of auxiliaryTables) {
				const columns = await describe(queryInterface, table, transaction);
				if (columns.sync_cursor.allowNull) {
					await queryInterface.changeColumn(
						table,
						'sync_cursor',
						{
							type: Sequelize.BIGINT,
							allowNull: false,
							defaultValue: '1',
						},
						{ transaction },
					);
				}
			}

			await ensureIndex(
				queryInterface,
				'clients',
				['franchisee_id', 'sync_cursor'],
				{ name: 'clients_tenant_sync_cursor' },
				transaction,
			);
			await ensureIndex(
				queryInterface,
				'items',
				['client_id', 'sync_cursor'],
				{ name: 'items_parent_sync_cursor' },
				transaction,
			);
			await ensureIndex(
				queryInterface,
				'rectangles',
				['item_id', 'sync_cursor'],
				{ name: 'rectangles_parent_sync_cursor' },
				transaction,
			);
			await ensureIndex(
				queryInterface,
				'default_prices',
				['franchisee_id', 'sync_cursor'],
				{ name: 'default_prices_tenant_sync_cursor' },
				transaction,
			);
			await ensureIndex(
				queryInterface,
				'warranties',
				['client_id', 'sync_cursor'],
				{ name: 'warranties_parent_sync_cursor' },
				transaction,
			);
			await ensureIndex(
				queryInterface,
				'proposals',
				['client_id', 'sync_cursor'],
				{ name: 'proposals_parent_sync_cursor' },
				transaction,
			);
		});
	},

	async down() {
		// Intentionally non-destructive. Removing logical versions, permanent
		// four-entity tombstones, cursors, or idempotency receipts would let a
		// rolled-back writer resurrect or reorder already-acknowledged changes.
	},
};
