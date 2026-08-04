import bcrypt from 'bcrypt';
import { UserAdministrationService, USER_ADMIN_BCRYPT_COST, type AdminActor, type LifecycleRequest } from './userAdministration';
import { Franchisee, User, UserAdminAuditEvent, sequelize } from '../models';

const tenantA = '10000000-0000-4000-8000-000000000001';
const tenantB = '20000000-0000-4000-8000-000000000002';
const actor: AdminActor = { actor: 'operator-a', uid: 1001, authMode: 'test', franchiseeIds: [tenantA] };
const tenantBActor: AdminActor = { actor: 'operator-b', uid: 1002, authMode: 'test', franchiseeIds: [tenantB] };
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

  it('rejects whitespace, control, repeated, and low-entropy supplied credentials', async () => {
    for (const [suffix, password] of [
      ['21', ' leading-secret-123'], ['22', '                '], ['23', 'a'.repeat(16)],
      ['24', 'strong-secret\u0000value'], ['25', 'abababababababab'],
    ]) {
      await expect(service.execute(actor, request('create', suffix, { email: `${suffix}@example.com`, password }))).rejects.toMatchObject({ code: 'WEAK_CREDENTIAL' });
    }
  });

  it('rejects unsupported runtime actions before changing user state', async () => {
    const created = await service.execute(actor, request('create', '28'));
    const before = await User.findByPk(created.user.id);
    const unsupported = {
      action: 'delete', franchiseeId: tenantA, email: 'operator@example.com', reason: 'APP-108 test', idempotencyKey: key('29'),
    } as unknown as LifecycleRequest;
    await expect(service.execute(actor, unsupported)).rejects.toMatchObject({ code: 'UNSUPPORTED_ACTION' });
    const after = await User.findByPk(created.user.id);
    expect(after!.isActive).toBe(before!.isActive);
    expect(after!.tokenVersion).toBe(before!.tokenVersion);
    expect(after!.password).toBe(before!.password);
    const audit = await UserAdminAuditEvent.findOne({ where: { idempotencyKey: key('29') } });
    expect(audit!.get('outcome')).toBe('rejected');
    expect(audit!.get('reasonCode')).toBe('UNSUPPORTED_ACTION');
  });

  it('fails fast on overlong UTF-8 reasons while preserving a redacted rejected audit event', async () => {
    for (const [suffix, reason] of [['26', 'x'.repeat(256)], ['27', 'é'.repeat(150)]]) {
      await expect(service.execute(actor, request('create', suffix, { email: `${suffix}@example.com`, reason }))).rejects.toMatchObject({ code: 'REASON_TOO_LONG' });
      const audit = await UserAdminAuditEvent.findOne({ where: { idempotencyKey: key(suffix) } });
      expect(audit!.get('reason')).toBe('[redacted:reason-too-long]');
      expect(audit!.get('reasonCode')).toBe('REASON_TOO_LONG');
    }
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
    const page = await service.auditEvents(actor, tenantA, 999);
    expect(page.events).toHaveLength(Math.min(await UserAdminAuditEvent.count({ where: { franchiseeId: tenantA } }), 100));
    expect(page.events.map((event) => event.idempotencyKey)).toEqual(expect.arrayContaining([key('18'), key('19')]));
    expect(page.events.every((event) => event.franchiseeId === tenantA)).toBe(true);
    await expect(service.auditEvents(actor, tenantB)).rejects.toMatchObject({ code: 'OUT_OF_SCOPE' });
  });

  it('uses a tenant-bound decimal sequence cursor without tenant leakage, skips, or precision loss', async () => {
    const createAudit = (id: string, idempotencyKey: string, franchiseeId: string, auditSequence: string) => UserAdminAuditEvent.create({
      id, idempotencyKey, canonicalRequestSha256: 'a'.repeat(64), auditSequence, actor: 'cursor-test', actorUid: 1001, authMode: 'test', scopeSnapshot: { franchiseeIds: [franchiseeId] }, action: 'create', targetUserId: null, normalizedEmail: `${id}@example.com`, franchiseeId, reason: 'cursor test', outcome: 'succeeded', reasonCode: 'APPLIED', beforeState: null, afterState: { isActive: true, tokenVersion: 0 }, hostname: 'test', appVersion: 'test', createdAt: new Date('2035-01-01T00:00:00.123Z'),
    });
    const latest = '90000000-0000-4000-8000-000000000003';
    const sameLow = '90000000-0000-4000-8000-000000000001';
    const sameHigh = '90000000-0000-4000-8000-000000000002';
    await createAudit(latest, key('30'), tenantA, '9007199254740995');
    await createAudit(sameLow, key('31'), tenantA, '9007199254740993');
    await createAudit(sameHigh, key('32'), tenantA, '9007199254740994');
    const foreignLatest = '90000000-0000-4000-8000-000000000004';
    await createAudit(foreignLatest, key('33'), tenantB, '9007199254740992');
    await createAudit('90000000-0000-4000-8000-000000000005', key('34'), tenantB, '9007199254740991');
    const first = await service.auditEvents(actor, tenantA, 1);
    expect(Buffer.from(first.nextCursor!, 'base64url').toString('utf8')).toBe(`{"franchiseeId":"${tenantA}","sequence":"9007199254740995"}`);
    const second = await service.auditEvents(actor, tenantA, 1, first.nextCursor);
    const third = await service.auditEvents(actor, tenantA, 1, second.nextCursor);
    expect([first.events[0].id, second.events[0].id, third.events[0].id]).toEqual([latest, sameHigh, sameLow]);
    expect(new Set([first.events[0].id, second.events[0].id, third.events[0].id]).size).toBe(3);
    expect(first.events[0].auditSequence).toBe('9007199254740995');
    const legacyCursor = Buffer.from(JSON.stringify({ sequence: '9007199254740994' })).toString('base64url');
    expect((await service.auditEvents(actor, tenantA, 1, legacyCursor)).events[0].id).toBe(sameLow);
    const foreignCursor = (await service.auditEvents(tenantBActor, tenantB, 1)).nextCursor;
    expect(Buffer.from(foreignCursor!, 'base64url').toString('utf8')).toContain(tenantB);
    await expect(service.auditEvents(actor, tenantA, 1, foreignCursor)).rejects.toMatchObject({ code: 'INVALID_AUDIT_CURSOR' });
    const foreignLegacyCursor = Buffer.from(JSON.stringify({ sequence: '9007199254740992' })).toString('base64url');
    await expect(service.auditEvents(actor, tenantA, 1, foreignLegacyCursor)).rejects.toMatchObject({ code: 'INVALID_AUDIT_CURSOR' });
    await expect(service.auditEvents(actor, tenantA, 1, 'not-a-cursor')).rejects.toMatchObject({ code: 'INVALID_AUDIT_CURSOR' });
    const future = Buffer.from(JSON.stringify({ sequence: '9223372036854775807' })).toString('base64url');
    await expect(service.auditEvents(actor, tenantA, 1, future)).rejects.toMatchObject({ code: 'INVALID_AUDIT_CURSOR' });
  });

  it('requires an explicit deployed version for production audit operations', () => {
    const previousNodeEnv = process.env.NODE_ENV;
    const previousVersion = process.env.APP_VERSION;
    process.env.NODE_ENV = 'production'; delete process.env.APP_VERSION;
    expect(() => new UserAdministrationService()).toThrow(expect.objectContaining({ code: 'APP_VERSION_REQUIRED' }));
    expect(() => new UserAdministrationService('abcdef1')).not.toThrow();
    process.env.NODE_ENV = previousNodeEnv;
    if (previousVersion === undefined) delete process.env.APP_VERSION; else process.env.APP_VERSION = previousVersion;
  });
});
