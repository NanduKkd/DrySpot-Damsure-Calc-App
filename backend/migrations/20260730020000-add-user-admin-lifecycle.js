'use strict';

const auditTable = 'user_admin_audit_events';
const emailIndex = 'users_normalized_email_unique';
const auditSequenceColumn = 'audit_sequence';
const auditSequenceIndex = 'user_admin_audit_events_audit_sequence_unique';
const auditSequenceTable = 'user_admin_audit_event_sequence';
const auditSequenceName = 'user_admin_audit_events_audit_sequence_seq';

const hasTable = async (queryInterface, table) => (await queryInterface.showAllTables()).includes(table);
const hasIndex = async (queryInterface, table, name) =>
  (await queryInterface.showIndex(table)).some((index) => index.name === name);

const requireTable = async (queryInterface, table) => {
  if (!(await hasTable(queryInterface, table))) {
    throw new Error(`Required table "${table}" does not exist. This is a delta migration for an existing Damsure database; do not use it to initialise an empty database.`);
  }
};

const hasColumn = async (queryInterface, table, column) =>
  Object.prototype.hasOwnProperty.call(await queryInterface.describeTable(table), column);

const ensureAuditSequence = async (queryInterface, Sequelize, transaction) => {
  const dialect = queryInterface.sequelize.getDialect();
  if (dialect === 'postgres') {
    await queryInterface.sequelize.query(`CREATE SEQUENCE IF NOT EXISTS ${auditSequenceName}`, { transaction });
    if (!(await hasColumn(queryInterface, auditTable, auditSequenceColumn))) {
      await queryInterface.addColumn(auditTable, auditSequenceColumn, { type: Sequelize.BIGINT, allowNull: true }, { transaction });
    }
    await queryInterface.sequelize.query(
      `ALTER TABLE ${auditTable} ALTER COLUMN ${auditSequenceColumn}
       SET DEFAULT nextval('${auditSequenceName}')`,
      { transaction },
    );
    await queryInterface.sequelize.query(
      `UPDATE ${auditTable}
       SET ${auditSequenceColumn} = nextval('${auditSequenceName}')
       WHERE ${auditSequenceColumn} IS NULL`,
      { transaction },
    );
    await queryInterface.sequelize.query(
      `SELECT setval('${auditSequenceName}',
        GREATEST(COALESCE((SELECT MAX(${auditSequenceColumn}) FROM ${auditTable}), 1), 1),
        EXISTS (SELECT 1 FROM ${auditTable}))`,
      { transaction },
    );
    await queryInterface.sequelize.query(
      `ALTER TABLE ${auditTable} ALTER COLUMN ${auditSequenceColumn} SET NOT NULL`,
      { transaction },
    );
  } else if (dialect === 'sqlite') {
    if (!(await hasColumn(queryInterface, auditTable, auditSequenceColumn))) {
      await queryInterface.addColumn(auditTable, auditSequenceColumn, { type: Sequelize.BIGINT, allowNull: true }, { transaction });
    }
    await queryInterface.sequelize.query(
      `UPDATE ${auditTable} SET ${auditSequenceColumn} = rowid WHERE ${auditSequenceColumn} IS NULL`,
      { transaction },
    );
    if (!(await hasTable(queryInterface, auditSequenceTable))) {
      await queryInterface.createTable(auditSequenceTable, {
        singleton: { type: Sequelize.INTEGER, primaryKey: true, allowNull: false },
        next_value: { type: Sequelize.BIGINT, allowNull: false },
      }, { transaction });
      await queryInterface.sequelize.query(
        `INSERT INTO ${auditSequenceTable} (singleton, next_value)
         VALUES (1, COALESCE((SELECT MAX(${auditSequenceColumn}) FROM ${auditTable}), 0))`,
        { transaction },
      );
    } else {
      await queryInterface.sequelize.query(
        `UPDATE ${auditSequenceTable}
         SET next_value = CASE
           WHEN next_value < COALESCE((SELECT MAX(${auditSequenceColumn}) FROM ${auditTable}), 0)
           THEN COALESCE((SELECT MAX(${auditSequenceColumn}) FROM ${auditTable}), 0)
           ELSE next_value END
         WHERE singleton = 1`,
        { transaction },
      );
    }
    await queryInterface.sequelize.query(
      `CREATE TRIGGER IF NOT EXISTS user_admin_audit_events_require_sequence
       BEFORE INSERT ON ${auditTable}
       FOR EACH ROW WHEN NEW.${auditSequenceColumn} IS NULL
       BEGIN SELECT RAISE(ABORT, 'user admin audit sequence is required'); END`,
      { transaction },
    );
  } else {
    throw new Error(`APP-108 audit sequence does not support ${dialect}.`);
  }
  if (!(await hasIndex(queryInterface, auditTable, auditSequenceIndex))) {
    await queryInterface.addIndex(auditTable, [auditSequenceColumn], { name: auditSequenceIndex, unique: true, transaction });
  }
};

module.exports = {
  async up(queryInterface, Sequelize) {
    await Promise.all(['users', 'franchisees'].map((table) => requireTable(queryInterface, table)));
    const dialect = queryInterface.sequelize.getDialect();
    const trimExpression = dialect === 'postgres' ? 'lower(btrim(email))' : 'lower(trim(email))';
    const collisions = await queryInterface.sequelize.query(
      `SELECT ${trimExpression} AS normalized FROM users GROUP BY ${trimExpression} HAVING COUNT(*) > 1 LIMIT 1`,
    );
    if (collisions[0].length) {
      // Do not disclose the conflicting address in migration output.
      throw new Error('User email normalization preflight failed: case-fold collisions exist; resolve them manually before retrying.');
    }
    await queryInterface.sequelize.transaction(async (transaction) => {
      if (!(await hasTable(queryInterface, auditTable))) {
        await queryInterface.createTable(auditTable, {
          id: { type: Sequelize.UUID, primaryKey: true, allowNull: false },
          idempotency_key: { type: Sequelize.UUID, allowNull: false, unique: true },
          canonical_request_sha256: { type: Sequelize.STRING(64), allowNull: false },
          audit_sequence: { type: Sequelize.BIGINT, allowNull: true },
          occurred_at: { type: Sequelize.DATE, allowNull: false, defaultValue: Sequelize.literal('CURRENT_TIMESTAMP') },
          actor: { type: Sequelize.STRING, allowNull: false }, actor_uid: { type: Sequelize.INTEGER, allowNull: false },
          auth_mode: { type: Sequelize.STRING, allowNull: false }, scope_snapshot: { type: Sequelize.JSON, allowNull: false },
          action: { type: Sequelize.STRING, allowNull: false }, target_user_id: { type: Sequelize.UUID, allowNull: true },
          normalized_email: { type: Sequelize.STRING, allowNull: false }, franchisee_id: { type: Sequelize.UUID, allowNull: false },
          reason: { type: Sequelize.STRING(255), allowNull: false }, outcome: { type: Sequelize.STRING, allowNull: false },
          reason_code: { type: Sequelize.STRING, allowNull: false }, before_state: { type: Sequelize.JSON, allowNull: true },
          after_state: { type: Sequelize.JSON, allowNull: true }, hostname: { type: Sequelize.STRING, allowNull: false },
          app_version: { type: Sequelize.STRING, allowNull: false },
        }, { transaction });
      }
      await ensureAuditSequence(queryInterface, Sequelize, transaction);
      if (!(await hasIndex(queryInterface, 'users', emailIndex))) {
        await queryInterface.sequelize.query(`CREATE UNIQUE INDEX ${emailIndex} ON users (${trimExpression})`, { transaction });
      }
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
    });
  },
  async down(queryInterface) {
    // Audit evidence and lifecycle data are deliberately retained. Only the reversible email guard is removed.
    if (await hasIndex(queryInterface, 'users', emailIndex)) await queryInterface.removeIndex('users', emailIndex);
  },
};
