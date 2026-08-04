'use strict';

const assert = require('assert/strict');
const { execFileSync } = require('child_process');
const path = require('path');
const { DataTypes, QueryTypes, Sequelize } = require('sequelize');
const lifecycleMigration = require('../migrations/20260730020000-add-user-admin-lifecycle.js');

const lifecycleMigrationName = '20260730020000-add-user-admin-lifecycle.js';
const auditSequenceMigrationName = '20260730021000-add-user-admin-audit-sequence.js';
const priorMigrationNames = [
  '20260725000000-add-auth-and-pdf-schema.js', '20260730000000-add-managed-file-cleanups.js',
  '20260730010000-add-warranty-deletion-tombstones.js', lifecycleMigrationName,
];
const databaseUrl = process.env.APP108_POSTGRES_URL;
if (!databaseUrl) throw new Error('APP108_POSTGRES_URL is required.');
const databaseName = new URL(databaseUrl).pathname.slice(1);
if (!databaseName.startsWith('app108_proof_')) throw new Error('Refusing destructive proof outside a disposable app108_proof_* database.');
process.env.DATABASE_URL = databaseUrl;
process.env.NODE_ENV = 'production';
const cliDatabaseUrl = new URL(databaseUrl);
cliDatabaseUrl.searchParams.set('options', '-c lock_timeout=1000 -c statement_timeout=5000');
const sequelizeCli = require.resolve('sequelize-cli/lib/sequelize');
const runSequelizeCli = (command) => execFileSync(process.execPath, [sequelizeCli, command, '--env', 'production'], {
  cwd: path.resolve(__dirname, '..'), env: { ...process.env, DATABASE_URL: cliDatabaseUrl.toString(), NODE_ENV: 'production' }, stdio: 'pipe',
});

// A migration catalog read that escapes its DDL transaction would wait on its
// own ALTER TABLE lock. These startup timeouts make that regression fail fast.
const database = new Sequelize(databaseUrl, {
  logging: false, pool: { min: 0, max: 8 }, dialectOptions: { lock_timeout: 1000, statement_timeout: 5000 },
});
const tenantA = '10000000-0000-4000-8000-000000000001';
const tenantB = '20000000-0000-4000-8000-000000000002';
const actor = { actor: 'proof-operator', uid: 1001, authMode: 'proof', franchiseeIds: [tenantA] };
const tenantBActor = { actor: 'proof-operator-b', uid: 1002, authMode: 'proof', franchiseeIds: [tenantB] };
const request = (action, key, extra = {}) => ({ action, franchiseeId: tenantA, email: 'proof@example.com', reason: 'APP-108 PostgreSQL proof', idempotencyKey: key, name: 'Proof User', ...extra });

const expectReject = async (promise, label) => {
  try { await promise; assert.fail(`${label}: expected rejection`); } catch (error) { if (error?.name === 'AssertionError') throw error; return error; }
};
const reset = async () => { await database.query('DROP SCHEMA public CASCADE'); await database.query('CREATE SCHEMA public'); };
const createBaseSchema = async () => {
  const queryInterface = database.getQueryInterface();
  await queryInterface.createTable('franchisees', { id: { type: DataTypes.UUID, primaryKey: true }, name: { type: DataTypes.STRING, allowNull: false }, created_at: DataTypes.DATE, updated_at: DataTypes.DATE });
  await queryInterface.createTable('users', {
    id: { type: DataTypes.UUID, primaryKey: true }, name: { type: DataTypes.STRING, allowNull: false }, email: { type: DataTypes.STRING, allowNull: false }, password: { type: DataTypes.STRING, allowNull: false }, franchisee_id: { type: DataTypes.UUID, allowNull: false }, is_active: { type: DataTypes.BOOLEAN, allowNull: false, defaultValue: true }, token_version: { type: DataTypes.INTEGER, allowNull: false, defaultValue: 0 }, created_at: DataTypes.DATE, updated_at: DataTypes.DATE,
  });
  await queryInterface.bulkInsert('franchisees', [{ id: tenantA, name: 'A' }, { id: tenantB, name: 'B' }]);
  return queryInterface;
};

const main = async () => {
  await database.authenticate();
  const timeouts = await database.query(`SELECT current_setting('lock_timeout') AS lock_timeout, current_setting('statement_timeout') AS statement_timeout`, { type: QueryTypes.SELECT });
  assert.equal(timeouts[0].lock_timeout, '1s', 'proof must fail quickly if migration metadata opens a second locked connection');
  assert.equal(timeouts[0].statement_timeout, '5s', 'proof must bound migration statement waits');
  let queryInterface = await createBaseSchema();
  await database.query(`INSERT INTO users (id, name, email, password, franchisee_id, is_active, token_version) VALUES
    ('30000000-0000-4000-8000-000000000001', 'One', 'Case@Example.com', 'x', :tenant, true, 0),
    ('30000000-0000-4000-8000-000000000002', 'Two', 'case@example.com', 'x', :tenant, true, 0)`, { replacements: { tenant: tenantA } });
  const collision = await expectReject(lifecycleMigration.up(queryInterface, Sequelize), 'collision preflight');
  assert(!String(collision.message).includes('Case@Example.com'), 'collision output must be redacted');
  assert.equal(Number((await database.query('SELECT COUNT(*) AS count FROM users', { type: QueryTypes.SELECT }))[0].count), 2, 'collision abort must retain users');

  await reset(); queryInterface = await createBaseSchema();
  await queryInterface.createTable('SequelizeMeta', { name: { type: DataTypes.STRING, primaryKey: true, allowNull: false } });
  const lifecycleStarted = Date.now();
  await lifecycleMigration.up(queryInterface, Sequelize);
  assert(Date.now() - lifecycleStarted < 5000, 'original migration must not self-deadlock on a transactional catalog read');
  await queryInterface.bulkInsert('SequelizeMeta', priorMigrationNames.map((name) => ({ name })));
  assert(!Object.hasOwn(await queryInterface.describeTable('user_admin_audit_events'), 'audit_sequence'), 'recorded original migration must remain pre-sequence');
  await database.query(`INSERT INTO user_admin_audit_events
    (id, idempotency_key, canonical_request_sha256, occurred_at, actor, actor_uid, auth_mode, scope_snapshot,
     action, normalized_email, franchisee_id, reason, outcome, reason_code, hostname, app_version)
    VALUES ('30000000-0000-4000-8000-000000000010', '40000000-0000-4000-8000-000000000010', repeat('a', 64),
      '2035-01-01T00:00:00.123900Z', 'legacy', 1, 'legacy', '{}'::jsonb, 'create', 'legacy@example.com', :tenant,
      'legacy audit', 'succeeded', 'APPLIED', 'proof', 'abcdef1')`, { replacements: { tenant: tenantA } });
  await database.query(`CREATE FUNCTION legacy_user_admin_backfill_blocker() RETURNS trigger AS $$ BEGIN RAISE EXCEPTION 'legacy audit backfill blocker'; END; $$ LANGUAGE plpgsql`);
  await database.query(`CREATE TRIGGER legacy_user_admin_backfill_blocker BEFORE UPDATE ON user_admin_audit_events FOR EACH ROW EXECUTE FUNCTION legacy_user_admin_backfill_blocker()`);
  await expectReject(Promise.resolve().then(() => runSequelizeCli('db:migrate')), 'guarded legacy backfill failure');
  assert(!Object.hasOwn(await queryInterface.describeTable('user_admin_audit_events'), 'audit_sequence'), 'failed additive migration must roll back the added column');
  assert.equal((await database.query(`SELECT to_regclass('user_admin_audit_events_audit_sequence_seq') AS sequence_name`, { type: QueryTypes.SELECT }))[0].sequence_name, null, 'failed additive migration must roll back its sequence');
  const rolledBackGuards = await database.query(`SELECT tgname FROM pg_trigger WHERE tgrelid = 'user_admin_audit_events'::regclass AND NOT tgisinternal`, { type: QueryTypes.SELECT });
  assert.deepEqual(rolledBackGuards.map((trigger) => trigger.tgname).sort(), ['legacy_user_admin_backfill_blocker', 'user_admin_audit_events_no_delete', 'user_admin_audit_events_no_update'], 'failed additive migration must restore known guards and leave unknown guards intact');
  assert.deepEqual(await database.query('SELECT name FROM "SequelizeMeta" ORDER BY name', { type: QueryTypes.SELECT }), priorMigrationNames.map((name) => ({ name })), 'failed additive migration must not be recorded');
  await database.query('DROP TRIGGER legacy_user_admin_backfill_blocker ON user_admin_audit_events');
  await expectReject(database.query(`UPDATE user_admin_audit_events SET reason = 'changed'`), 'restored legacy update guard');
  await expectReject(database.query('DELETE FROM user_admin_audit_events'), 'restored legacy delete guard');
  const sequenceStarted = Date.now();
  runSequelizeCli('db:migrate');
  assert(Date.now() - sequenceStarted < 5000, 'additive migration must not self-deadlock on transactional catalog reads');
  runSequelizeCli('db:migrate');
  assert.match(String((await database.query(`SELECT audit_sequence::text AS sequence FROM user_admin_audit_events WHERE id = '30000000-0000-4000-8000-000000000010'`, { type: QueryTypes.SELECT }))[0].sequence), /^[1-9]\d*$/, 'existing audit must receive a sequence');
  await expectReject(database.query('UPDATE user_admin_audit_events SET reason = :reason', { replacements: { reason: 'mutated' } }), 'append-only update trigger');
  await expectReject(database.query('DELETE FROM user_admin_audit_events'), 'append-only delete trigger');
  const { UserAdministrationService } = require('../dist/services/userAdministration.js');
  const { User } = require('../dist/models');
  const { normalizedEmailWhere } = require('../dist/utils/userEmail.js');
  await database.query(`INSERT INTO users (id, name, email, password, franchisee_id, is_active, token_version)
    VALUES ('30000000-0000-4000-8000-000000000003', 'Legacy', 'Legacy@Example.COM', 'x', :tenant, true, 0)`, { replacements: { tenant: tenantA } });
  assert.equal((await User.findOne({ where: normalizedEmailWhere(' legacy@example.com ') })).id, '30000000-0000-4000-8000-000000000003', 'legacy mixed-case login lookup must use normalized expression');
  const service = new UserAdministrationService('abcdef1');
  const createKey = '40000000-0000-4000-8000-000000000001';
  const created = await service.execute(actor, request('create', createKey));
  assert.equal(created.user.email, 'proof@example.com');
  const sameKey = await Promise.all([service.execute(actor, request('create', createKey)), service.execute(actor, request('create', createKey))]);
  assert.equal(sameKey[0].user.id, created.user.id, 'same key retry must retain one target');
  await expectReject(service.execute(actor, request('create', '40000000-0000-4000-8000-000000000002', { email: 'PROOF@example.com' })), 'normalized duplicate');
  await expectReject(service.execute(actor, request('create', '40000000-0000-4000-8000-000000000003', { franchiseeId: tenantB })), 'out of scope');
  await service.execute(actor, request('deactivate', '40000000-0000-4000-8000-000000000004'));
  const resetResult = await service.execute(actor, request('reset-password', '40000000-0000-4000-8000-000000000005'));
  assert(resetResult.generatedPassword, 'reset must generate a credential');
  const state = (await database.query('SELECT is_active, token_version FROM users WHERE id = :id', { replacements: { id: created.user.id }, type: QueryTypes.SELECT }))[0];
  assert.equal(state.is_active, false, 'reset must not reactivate'); assert.equal(Number(state.token_version), 2, 'deactivate and reset increment once each');
  const audits = await database.query('SELECT actor, before_state, after_state, outcome FROM user_admin_audit_events WHERE franchisee_id = :tenant', { replacements: { tenant: tenantA }, type: QueryTypes.SELECT });
  const proofAudits = audits.filter((event) => event.actor === 'proof-operator');
  assert(proofAudits.length >= 4, 'audit records must be complete and attributed');
  await database.query(`INSERT INTO user_admin_audit_events
    (id, idempotency_key, canonical_request_sha256, audit_sequence, occurred_at, actor, actor_uid, auth_mode, scope_snapshot,
     action, normalized_email, franchisee_id, reason, outcome, reason_code, hostname, app_version)
    VALUES
    ('30000000-0000-4000-8000-000000000020', '40000000-0000-4000-8000-000000000020', repeat('b', 64), 9007199254740993, '2035-01-01T00:00:00.123700Z', 'proof-operator', 1001, 'proof', '{}'::jsonb, 'create', 'cursor-a@example.com', :tenant, 'cursor', 'succeeded', 'APPLIED', 'proof', 'abcdef1'),
    ('30000000-0000-4000-8000-000000000021', '40000000-0000-4000-8000-000000000021', repeat('c', 64), 9007199254740994, '2035-01-01T00:00:00.123800Z', 'proof-operator', 1001, 'proof', '{}'::jsonb, 'create', 'cursor-b@example.com', :tenant, 'cursor', 'succeeded', 'APPLIED', 'proof', 'abcdef1'),
    ('30000000-0000-4000-8000-000000000022', '40000000-0000-4000-8000-000000000022', repeat('d', 64), 9007199254740995, '2035-01-01T00:00:00.123900Z', 'proof-operator', 1001, 'proof', '{}'::jsonb, 'create', 'cursor-c@example.com', :tenant, 'cursor', 'succeeded', 'APPLIED', 'proof', 'abcdef1'),
    ('30000000-0000-4000-8000-000000000023', '40000000-0000-4000-8000-000000000023', repeat('e', 64), 9007199254740992, '2035-01-01T00:00:00.123950Z', 'proof-operator-b', 1002, 'proof', '{}'::jsonb, 'create', 'foreign-cursor@example.com', :tenantB, 'cursor', 'succeeded', 'APPLIED', 'proof', 'abcdef1'),
    ('30000000-0000-4000-8000-000000000024', '40000000-0000-4000-8000-000000000024', repeat('f', 64), 9007199254740991, '2035-01-01T00:00:00.123960Z', 'proof-operator-b', 1002, 'proof', '{}'::jsonb, 'create', 'foreign-cursor-old@example.com', :tenantB, 'cursor', 'succeeded', 'APPLIED', 'proof', 'abcdef1')`, { replacements: { tenant: tenantA, tenantB } });
  const cursorA = await service.auditEvents(actor, tenantA, 1);
  const cursorB = await service.auditEvents(actor, tenantA, 1, cursorA.nextCursor);
  const cursorC = await service.auditEvents(actor, tenantA, 1, cursorB.nextCursor);
  assert.deepEqual(cursorA.events.map((event) => event.id).concat(cursorB.events.map((event) => event.id), cursorC.events.map((event) => event.id)), [
    '30000000-0000-4000-8000-000000000022', '30000000-0000-4000-8000-000000000021', '30000000-0000-4000-8000-000000000020',
  ], 'microsecond-distinct events must page without skips or duplicates');
  assert.equal(cursorA.events[0].auditSequence, '9007199254740995', 'audit sequence must serialize safely above 2^53');
  const cursorForTenantB = await service.auditEvents(tenantBActor, tenantB, 1);
  await expectReject(service.auditEvents(actor, tenantA, 1, cursorForTenantB.nextCursor), 'foreign tenant-bound cursor must not skip tenant A events');
  const foreignLegacyCursor = Buffer.from(JSON.stringify({ sequence: '9007199254740992' })).toString('base64url');
  await expectReject(service.auditEvents(actor, tenantA, 1, foreignLegacyCursor), 'foreign legacy cursor must not skip tenant A events');
  runSequelizeCli('db:migrate:undo');
  assert.equal(Number((await database.query('SELECT COUNT(*) AS count FROM user_admin_audit_events', { type: QueryTypes.SELECT }))[0].count) > 0, true, 'additive down must retain audit data');
  runSequelizeCli('db:migrate');
  await expectReject(database.query(`UPDATE user_admin_audit_events SET reason = 'mutated after reapply'`), 'append-only update trigger after reapply');
  await expectReject(database.query('DELETE FROM user_admin_audit_events'), 'append-only delete trigger after reapply');
  assert.deepEqual(await database.query('SELECT name FROM "SequelizeMeta" ORDER BY name', { type: QueryTypes.SELECT }), [...priorMigrationNames, auditSequenceMigrationName].map((name) => ({ name })));
  process.stdout.write(`${JSON.stringify({ dialect: database.getDialect(), collision_redacted: 'passed', sequelize_meta_additive_path: 'passed', guarded_legacy_rollback: 'passed', guarded_legacy_upgrade: 'passed', transactional_catalog_reads: 'passed', normalized_legacy_login: 'passed', audit_sequence_backfill: 'passed', microsecond_cursor: 'passed', tenant_bound_cursor: 'passed', forward: 'passed', idempotent: 'passed', advisory_idempotency: 'passed', tenancy: 'passed', lifecycle: 'passed', append_only: 'passed', down_non_destructive: 'passed', reapply: 'passed' })}\n`);
};

main().finally(() => database.close()).catch((error) => { console.error(error); process.exitCode = 1; });
