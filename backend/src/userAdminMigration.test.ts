import { DataTypes, QueryTypes, Sequelize } from 'sequelize';
import { Franchisee, User, sequelize } from './models';

// eslint-disable-next-line @typescript-eslint/no-var-requires
const lifecycleMigration = require('../migrations/20260730020000-add-user-admin-lifecycle.js');
// eslint-disable-next-line @typescript-eslint/no-var-requires
const auditSequenceMigration = require('../migrations/20260730021000-add-user-admin-audit-sequence.js');

const lifecycleMigrationName = '20260730020000-add-user-admin-lifecycle.js';
const auditSequenceMigrationName = '20260730021000-add-user-admin-audit-sequence.js';

describe('APP-108 migrations', () => {
  it('redacts normalization collisions and preserves data on non-destructive lifecycle down/reapply', async () => {
    const queryInterface = sequelize.getQueryInterface();
    await Franchisee.findOrCreate({ where: { id: '10000000-0000-4000-8000-000000000001' }, defaults: { name: 'migration tenant' } });
    await lifecycleMigration.down(queryInterface);
    await User.create({ id: '50000000-0000-4000-8000-000000000001', name: 'One', email: 'Case@Example.com', password: 'hash', franchiseeId: '10000000-0000-4000-8000-000000000001', isActive: true, tokenVersion: 0 });
    await User.create({ id: '50000000-0000-4000-8000-000000000002', name: 'Two', email: 'case@example.com', password: 'hash', franchiseeId: '10000000-0000-4000-8000-000000000001', isActive: true, tokenVersion: 0 });
    await expect(lifecycleMigration.up(queryInterface, Sequelize)).rejects.toThrow('case-fold collisions');
    await User.destroy({ where: { id: '50000000-0000-4000-8000-000000000002' } });
    await lifecycleMigration.up(queryInterface, Sequelize);
    await lifecycleMigration.down(queryInterface);
    expect(await User.findByPk('50000000-0000-4000-8000-000000000001')).not.toBeNull();
    await lifecycleMigration.up(queryInterface, Sequelize);
    await User.destroy({ where: { id: '50000000-0000-4000-8000-000000000001' } });
  });

  it('applies the additive sequence migration after recorded lifecycle migration and restores guards on failure', async () => {
    const legacy = new Sequelize('sqlite::memory:', { logging: false });
    const queryInterface = legacy.getQueryInterface();
    const applyPending = async (name: string, implementation: { up: (q: typeof queryInterface, s: typeof Sequelize) => Promise<void> }) => {
      const recorded = await legacy.query('SELECT 1 AS recorded FROM SequelizeMeta WHERE name = :name', { replacements: { name }, type: QueryTypes.SELECT });
      if (recorded.length) return false;
      await implementation.up(queryInterface, Sequelize);
      await queryInterface.bulkInsert('SequelizeMeta', [{ name }]);
      return true;
    };
    try {
      await queryInterface.createTable('franchisees', { id: { type: DataTypes.UUID, primaryKey: true }, name: DataTypes.STRING });
      await queryInterface.createTable('users', { id: { type: DataTypes.UUID, primaryKey: true }, email: { type: DataTypes.STRING, allowNull: false } });
      await queryInterface.createTable('SequelizeMeta', { name: { type: DataTypes.STRING, primaryKey: true, allowNull: false } });
      await queryInterface.bulkInsert('franchisees', [{ id: '10000000-0000-4000-8000-000000000099', name: 'legacy tenant' }]);
      await queryInterface.bulkInsert('users', [{ id: '20000000-0000-4000-8000-000000000099', email: 'legacy@example.com' }]);
      expect(await applyPending(lifecycleMigrationName, lifecycleMigration)).toBe(true);
      expect(await queryInterface.describeTable('user_admin_audit_events')).not.toHaveProperty('audit_sequence');
      await queryInterface.bulkInsert('user_admin_audit_events', [{
        id: '30000000-0000-4000-8000-000000000099', idempotency_key: '40000000-0000-4000-8000-000000000099', canonical_request_sha256: 'a'.repeat(64), occurred_at: new Date('2035-01-01T00:00:00.123Z'), actor: 'legacy', actor_uid: 1, auth_mode: 'legacy', scope_snapshot: '{}', action: 'create', normalized_email: 'legacy@example.com', franchisee_id: '10000000-0000-4000-8000-000000000099', reason: 'legacy evidence', outcome: 'succeeded', reason_code: 'APPLIED', hostname: 'test', app_version: 'abcdef1',
      }]);
      await legacy.query(`CREATE TRIGGER legacy_audit_backfill_blocker BEFORE UPDATE ON user_admin_audit_events BEGIN SELECT RAISE(ABORT, 'legacy backfill blocker'); END`);

      await expect(applyPending(auditSequenceMigrationName, auditSequenceMigration)).rejects.toThrow();
      expect(await queryInterface.describeTable('user_admin_audit_events')).not.toHaveProperty('audit_sequence');
      const failedTriggers = await legacy.query(`SELECT name FROM sqlite_master WHERE type = 'trigger' AND tbl_name = 'user_admin_audit_events'`, { type: QueryTypes.SELECT }) as Array<{ name: string }>;
      expect(failedTriggers.map((trigger) => trigger.name)).toEqual(expect.arrayContaining(['user_admin_audit_events_no_update', 'user_admin_audit_events_no_delete', 'legacy_audit_backfill_blocker']));
      expect(await legacy.query('SELECT name FROM SequelizeMeta ORDER BY name', { type: QueryTypes.SELECT })).toEqual([{ name: lifecycleMigrationName }]);
      await expect(legacy.query(`UPDATE user_admin_audit_events SET reason = 'changed'`)).rejects.toThrow();

      await legacy.query('DROP TRIGGER legacy_audit_backfill_blocker');
      expect(await applyPending(auditSequenceMigrationName, auditSequenceMigration)).toBe(true);
      expect(await applyPending(auditSequenceMigrationName, auditSequenceMigration)).toBe(false);
      const upgraded = await legacy.query(`SELECT CAST(audit_sequence AS TEXT) AS audit_sequence FROM user_admin_audit_events`, { type: QueryTypes.SELECT }) as Array<{ audit_sequence: string }>;
      expect(upgraded[0].audit_sequence).toMatch(/^[1-9]\d*$/);
      await expect(legacy.query(`UPDATE user_admin_audit_events SET reason = 'changed'`)).rejects.toThrow();
      await expect(legacy.query('DELETE FROM user_admin_audit_events')).rejects.toThrow();

      await auditSequenceMigration.down(queryInterface);
      await queryInterface.bulkDelete('SequelizeMeta', { name: auditSequenceMigrationName });
      expect(await legacy.query('SELECT COUNT(*) AS count FROM user_admin_audit_events', { type: QueryTypes.SELECT })).toEqual([{ count: 1 }]);
      expect(await applyPending(auditSequenceMigrationName, auditSequenceMigration)).toBe(true);
      await expect(legacy.query(`UPDATE user_admin_audit_events SET reason = 'changed again'`)).rejects.toThrow();
      await expect(legacy.query('DELETE FROM user_admin_audit_events')).rejects.toThrow();
    } finally {
      await legacy.close();
    }
  });
});
