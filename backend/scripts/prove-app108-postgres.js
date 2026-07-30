'use strict';

const assert = require('assert/strict');
const { DataTypes, QueryTypes, Sequelize } = require('sequelize');
const migration = require('../migrations/20260730020000-add-user-admin-lifecycle.js');

const databaseUrl = process.env.APP108_POSTGRES_URL;
if (!databaseUrl) throw new Error('APP108_POSTGRES_URL is required.');
const databaseName = new URL(databaseUrl).pathname.slice(1);
if (!databaseName.startsWith('app108_proof_')) throw new Error('Refusing destructive proof outside a disposable app108_proof_* database.');
process.env.DATABASE_URL = databaseUrl;
process.env.NODE_ENV = 'production';

const database = new Sequelize(databaseUrl, { logging: false, pool: { min: 0, max: 8 } });
const tenantA = '10000000-0000-4000-8000-000000000001';
const tenantB = '20000000-0000-4000-8000-000000000002';
const actor = { actor: 'proof-operator', uid: 1001, authMode: 'proof', franchiseeIds: [tenantA] };
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
  let queryInterface = await createBaseSchema();
  await database.query(`INSERT INTO users (id, name, email, password, franchisee_id, is_active, token_version) VALUES
    ('30000000-0000-4000-8000-000000000001', 'One', 'Case@Example.com', 'x', :tenant, true, 0),
    ('30000000-0000-4000-8000-000000000002', 'Two', 'case@example.com', 'x', :tenant, true, 0)`, { replacements: { tenant: tenantA } });
  const collision = await expectReject(migration.up(queryInterface, Sequelize), 'collision preflight');
  assert(!String(collision.message).includes('Case@Example.com'), 'collision output must be redacted');
  assert.equal(Number((await database.query('SELECT COUNT(*) AS count FROM users', { type: QueryTypes.SELECT }))[0].count), 2, 'collision abort must retain users');

  await reset(); queryInterface = await createBaseSchema();
  await migration.up(queryInterface, Sequelize); await migration.up(queryInterface, Sequelize);
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
  await expectReject(database.query('UPDATE user_admin_audit_events SET reason = :reason', { replacements: { reason: 'mutated' } }), 'append-only update trigger');
  await expectReject(database.query('DELETE FROM user_admin_audit_events'), 'append-only delete trigger');
  const audits = await database.query('SELECT actor, before_state, after_state, outcome FROM user_admin_audit_events WHERE franchisee_id = :tenant', { replacements: { tenant: tenantA }, type: QueryTypes.SELECT });
  assert(audits.length >= 4 && audits.every((event) => event.actor === 'proof-operator'), 'audit records must be complete and attributed');
  await migration.down(queryInterface);
  assert((await queryInterface.showAllTables()).includes('user_admin_audit_events'), 'down must retain audit data');
  await migration.up(queryInterface, Sequelize);
  process.stdout.write(`${JSON.stringify({ dialect: database.getDialect(), collision_redacted: 'passed', normalized_legacy_login: 'passed', forward: 'passed', idempotent: 'passed', advisory_idempotency: 'passed', tenancy: 'passed', lifecycle: 'passed', append_only: 'passed', down_non_destructive: 'passed', reapply: 'passed' })}\n`);
};

main().finally(() => database.close()).catch((error) => { console.error(error); process.exitCode = 1; });
