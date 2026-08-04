'use strict';

const { QueryTypes } = require('sequelize');

const auditTable = 'user_admin_audit_events';
const auditSequenceColumn = 'audit_sequence';
const auditSequenceIndex = 'user_admin_audit_events_audit_sequence_unique';
const auditSequenceTable = 'user_admin_audit_event_sequence';
const auditSequenceName = 'user_admin_audit_events_audit_sequence_seq';
const auditGuardTriggers = ['user_admin_audit_events_no_update', 'user_admin_audit_events_no_delete'];

const hasTable = async (queryInterface, table, transaction) =>
  (await queryInterface.showAllTables({ transaction })).includes(table);
const hasColumn = async (queryInterface, table, column, transaction) =>
  Object.prototype.hasOwnProperty.call(await queryInterface.describeTable(table, { transaction }), column);
const hasIndex = async (queryInterface, table, name, transaction) =>
  (await queryInterface.showIndex(table, { transaction })).some((index) => index.name === name);

const requireTable = async (queryInterface, table, transaction) => {
  if (!(await hasTable(queryInterface, table, transaction))) {
    throw new Error(`Required table "${table}" does not exist. Apply the APP-108 lifecycle migration before the audit-sequence migration.`);
  }
};

const dropKnownAuditGuards = async (queryInterface, transaction) => {
  const suffix = queryInterface.sequelize.getDialect() === 'postgres' ? ` ON ${auditTable}` : '';
  for (const trigger of auditGuardTriggers) {
    await queryInterface.sequelize.query(`DROP TRIGGER IF EXISTS ${trigger}${suffix}`, { transaction });
  }
};

const ensureAppendOnlyAuditGuards = async (queryInterface, transaction) => {
  const dialect = queryInterface.sequelize.getDialect();
  if (dialect === 'postgres') {
    await queryInterface.sequelize.query(`CREATE OR REPLACE FUNCTION reject_user_admin_audit_mutation() RETURNS trigger AS $$ BEGIN RAISE EXCEPTION 'user admin audit events are append-only'; END; $$ LANGUAGE plpgsql`, { transaction });
    for (const action of ['UPDATE', 'DELETE']) {
      await queryInterface.sequelize.query(`DROP TRIGGER IF EXISTS user_admin_audit_events_no_${action.toLowerCase()} ON ${auditTable}`, { transaction });
      await queryInterface.sequelize.query(`CREATE TRIGGER user_admin_audit_events_no_${action.toLowerCase()} BEFORE ${action} ON ${auditTable} FOR EACH ROW EXECUTE FUNCTION reject_user_admin_audit_mutation()`, { transaction });
    }
  } else if (dialect === 'sqlite') {
    await queryInterface.sequelize.query(`CREATE TRIGGER IF NOT EXISTS user_admin_audit_events_no_update BEFORE UPDATE ON ${auditTable} BEGIN SELECT RAISE(ABORT, 'user admin audit events are append-only'); END`, { transaction });
    await queryInterface.sequelize.query(`CREATE TRIGGER IF NOT EXISTS user_admin_audit_events_no_delete BEFORE DELETE ON ${auditTable} BEGIN SELECT RAISE(ABORT, 'user admin audit events are append-only'); END`, { transaction });
  } else throw new Error(`APP-108 audit guard does not support ${dialect}.`);
};

const ensureAuditSequence = async (queryInterface, Sequelize, transaction) => {
  const dialect = queryInterface.sequelize.getDialect();
  if (dialect === 'postgres') {
    await queryInterface.sequelize.query(`CREATE SEQUENCE IF NOT EXISTS ${auditSequenceName}`, { transaction });
    if (!(await hasColumn(queryInterface, auditTable, auditSequenceColumn, transaction))) {
      await queryInterface.addColumn(auditTable, auditSequenceColumn, { type: Sequelize.BIGINT, allowNull: true }, { transaction });
    }
    await queryInterface.sequelize.query(`ALTER TABLE ${auditTable} ALTER COLUMN ${auditSequenceColumn} SET DEFAULT nextval('${auditSequenceName}')`, { transaction });
    await queryInterface.sequelize.query(`UPDATE ${auditTable} SET ${auditSequenceColumn} = nextval('${auditSequenceName}') WHERE ${auditSequenceColumn} IS NULL`, { transaction });
    await queryInterface.sequelize.query(
      `SELECT setval('${auditSequenceName}', GREATEST(COALESCE((SELECT MAX(${auditSequenceColumn}) FROM ${auditTable}), 1), 1), EXISTS (SELECT 1 FROM ${auditTable}))`,
      { transaction },
    );
    await queryInterface.sequelize.query(`ALTER TABLE ${auditTable} ALTER COLUMN ${auditSequenceColumn} SET NOT NULL`, { transaction });
  } else if (dialect === 'sqlite') {
    if (!(await hasColumn(queryInterface, auditTable, auditSequenceColumn, transaction))) {
      await queryInterface.addColumn(auditTable, auditSequenceColumn, { type: Sequelize.BIGINT, allowNull: true }, { transaction });
    }
    await queryInterface.sequelize.query(`UPDATE ${auditTable} SET ${auditSequenceColumn} = rowid WHERE ${auditSequenceColumn} IS NULL`, { transaction });
    if (!(await hasTable(queryInterface, auditSequenceTable, transaction))) {
      await queryInterface.createTable(auditSequenceTable, {
        singleton: { type: Sequelize.INTEGER, primaryKey: true, allowNull: false },
        next_value: { type: Sequelize.BIGINT, allowNull: false },
      }, { transaction });
    }
    await queryInterface.sequelize.query(
      `INSERT OR IGNORE INTO ${auditSequenceTable} (singleton, next_value)
       VALUES (1, COALESCE((SELECT MAX(${auditSequenceColumn}) FROM ${auditTable}), 0))`,
      { transaction },
    );
    await queryInterface.sequelize.query(
      `UPDATE ${auditSequenceTable}
       SET next_value = CASE
         WHEN next_value < COALESCE((SELECT MAX(${auditSequenceColumn}) FROM ${auditTable}), 0)
         THEN COALESCE((SELECT MAX(${auditSequenceColumn}) FROM ${auditTable}), 0)
         ELSE next_value END
       WHERE singleton = 1`,
      { transaction },
    );
    await queryInterface.sequelize.query(
      `CREATE TRIGGER IF NOT EXISTS user_admin_audit_events_require_sequence
       BEFORE INSERT ON ${auditTable}
       FOR EACH ROW WHEN NEW.${auditSequenceColumn} IS NULL
       BEGIN SELECT RAISE(ABORT, 'user admin audit sequence is required'); END`,
      { transaction },
    );
  } else throw new Error(`APP-108 audit sequence does not support ${dialect}.`);

  const nullRows = await queryInterface.sequelize.query(
    `SELECT COUNT(*) AS count FROM ${auditTable} WHERE ${auditSequenceColumn} IS NULL`,
    { transaction, type: QueryTypes.SELECT },
  );
  if (Number(nullRows[0].count) !== 0) throw new Error('APP-108 audit sequence backfill left null values.');
  if (!(await hasIndex(queryInterface, auditTable, auditSequenceIndex, transaction))) {
    await queryInterface.addIndex(auditTable, [auditSequenceColumn], { name: auditSequenceIndex, unique: true, transaction });
  }
};

module.exports = {
  async up(queryInterface, Sequelize) {
    await queryInterface.sequelize.transaction(async (transaction) => {
      await requireTable(queryInterface, auditTable, transaction);
      // Only the two guards owned by APP-108 are removed, within this one
      // transaction. Any failure restores the pre-upgrade guarded schema.
      await dropKnownAuditGuards(queryInterface, transaction);
      await ensureAuditSequence(queryInterface, Sequelize, transaction);
      await ensureAppendOnlyAuditGuards(queryInterface, transaction);
    });
  },
  async down() {
    // Non-destructive: retain sequence data, uniqueness, and append-only evidence.
  },
};
