import bcrypt from 'bcrypt';
import { UserAdministrationService, USER_ADMIN_BCRYPT_COST, type AdminActor } from './userAdministration';
import { Franchisee, User, UserAdminAuditEvent, sequelize } from '../models';

const tenantA = '10000000-0000-4000-8000-000000000001';
const tenantB = '20000000-0000-4000-8000-000000000002';
const actor: AdminActor = { actor: 'operator-a', uid: 1001, authMode: 'test', franchiseeIds: [tenantA] };
const key = (suffix: string) => `40000000-0000-4000-8000-${suffix.padStart(12, '0')}`;
const request = (action: 'create' | 'deactivate' | 'reactivate' | 'revoke-all-tokens' | 'reset-password', suffix: string, extra = {}) => ({
  action, franchiseeId: tenantA, email: '  Operator@Example.COM ', reason: 'APP-108 test', idempotencyKey: key(suffix), name: 'Operator Name', ...extra,
});

describe('APP-108 user administration', () => {
  const service = new UserAdministrationService('test');
  beforeEach(async () => { await User.destroy({ where: {} }); await Franchisee.destroy({ where: {} }); await Franchisee.bulkCreate([{ id: tenantA, name: 'A' }, { id: tenantB, name: 'B' }]); });

  it('creates once with normalized email, bcrypt 12, immutable success audit, and exact-key retry', async () => {
    const first = await service.execute(actor, request('create', '1'));
    expect(first.generatedPassword).toHaveLength(32);
    const user = await User.findByPk(first.user.id);
    expect(user!.email).toBe('operator@example.com');
    expect(await bcrypt.compare(first.generatedPassword!, user!.password)).toBe(true);
    expect(bcrypt.getRounds(user!.password)).toBe(USER_ADMIN_BCRYPT_COST);
    const retry = await service.execute(actor, request('create', '1'));
    expect(retry.user.id).toBe(first.user.id);
    expect(retry.generatedPassword).toBeUndefined();
    const audit = await UserAdminAuditEvent.findOne();
    expect(audit!.toJSON()).not.toHaveProperty('password');
    expect(JSON.stringify(audit!.toJSON())).not.toContain(first.generatedPassword!);
    await expect(audit!.update({ reason: 'no' })).rejects.toThrow();
    await expect(audit!.destroy()).rejects.toThrow();
  });

  it('regenerates a random credential when it would contain the supplied name', async () => {
    const created = await service.execute(actor, request('create', '20', { email: 'single@example.com', name: 'A' }));
    expect(created.generatedPassword!.toLowerCase()).not.toContain('a');
  });

  it('isolates foreign email and records rejection without revealing the other tenant', async () => {
    await User.create({ name: 'Foreign', email: 'operator@example.com', password: 'hash', franchiseeId: tenantB, isActive: true, tokenVersion: 0 });
    await expect(service.execute(actor, request('deactivate', '2'))).rejects.toMatchObject({ code: 'TARGET_NOT_FOUND_IN_FRANCHISEE' });
    expect(await UserAdminAuditEvent.count({ where: { outcome: 'rejected', reasonCode: 'TARGET_NOT_FOUND_IN_FRANCHISEE' } })).toBe(1);
  });

  it('applies lifecycle state changes exactly once and reset does not reactivate', async () => {
    const created = await service.execute(actor, request('create', '3'));
    const token = created.user.tokenVersion;
    await service.execute(actor, request('deactivate', '4'));
    let user = await User.findByPk(created.user.id); expect(user!.isActive).toBe(false); expect(user!.tokenVersion).toBe(token + 1);
    const reset = await service.execute(actor, request('reset-password', '5'));
    user = await User.findByPk(created.user.id); expect(user!.isActive).toBe(false); expect(user!.tokenVersion).toBe(token + 2); expect(await bcrypt.compare(reset.generatedPassword!, user!.password)).toBe(true);
    await service.execute(actor, request('reactivate', '6'));
    const revoke = await service.execute(actor, request('revoke-all-tokens', '7'));
    expect(revoke.user.tokenVersion).toBe(token + 3);
    const noop = await service.execute(actor, request('reactivate', '8'));
    expect(noop.outcome).toBe('noop');
  });

  it('rejects unsafe credentials, scope, changed idempotency payload, and token overflow', async () => {
    await expect(service.execute(actor, request('create', '9', { password: 'passwordpassword' }))).rejects.toMatchObject({ code: 'WEAK_CREDENTIAL' });
    await expect(service.execute({ ...actor, franchiseeIds: [] }, request('create', '10'))).rejects.toMatchObject({ code: 'OUT_OF_SCOPE' });
    await service.execute(actor, request('create', '11'));
    await expect(service.execute(actor, request('create', '11', { reason: 'changed' }))).rejects.toMatchObject({ code: 'IDEMPOTENCY_CONFLICT' });
    await service.execute(actor, request('create', '16', { email: 'credential@example.com', password: 'first-supplied-secret' }));
    await expect(service.execute(actor, request('create', '16', { email: 'credential@example.com', password: 'second-supplied-secret' }))).rejects.toMatchObject({ code: 'IDEMPOTENCY_CONFLICT' });
    await expect(service.execute(actor, request('create', '17', { email: 'not-an-email' }))).rejects.toMatchObject({ code: 'INVALID_EMAIL' });
    const user = await User.findOne({ where: { franchiseeId: tenantA } }); await user!.update({ tokenVersion: 2147483647 });
    await expect(service.execute(actor, request('revoke-all-tokens', '12'))).rejects.toMatchObject({ code: 'TOKEN_VERSION_EXHAUSTED' });
  });

  it('retries the same key without another token mutation and rejects duplicate normalized creates', async () => {
    const both = [await service.execute(actor, request('create', '13')), await service.execute(actor, request('create', '13'))];
    expect(both[0].user.id).toBe(both[1].user.id);
    await service.execute(actor, request('create', '14', { email: 'mixed@Example.com' }));
    await expect(service.execute(actor, request('create', '15', { email: ' MIXED@example.COM ' }))).rejects.toMatchObject({ code: 'EMAIL_ALREADY_EXISTS' });
    expect(await sequelize.getQueryInterface().showIndex('users')).toEqual(expect.arrayContaining([expect.objectContaining({ name: 'users_normalized_email_unique', unique: true })]));
  });

  it('scopes audit queries to the authorized tenant and clamps pagination', async () => {
    await service.execute(actor, request('create', '18'));
    await service.execute(actor, request('deactivate', '19'));
    const events = await service.auditEvents(actor, tenantA, 999);
    expect(events).toHaveLength(Math.min(await UserAdminAuditEvent.count({ where: { franchiseeId: tenantA } }), 100));
    expect(events.map((event) => event.get('idempotencyKey'))).toEqual(expect.arrayContaining([key('18'), key('19')]));
    expect(events.every((event) => event.get('franchiseeId') === tenantA)).toBe(true);
    await expect(service.auditEvents(actor, tenantB)).rejects.toMatchObject({ code: 'OUT_OF_SCOPE' });
  });
});
