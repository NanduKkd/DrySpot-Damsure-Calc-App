import { operatorConfigPath, resolveOperator } from './operatorAuthorization';

const tenant = '10000000-0000-4000-8000-000000000001';
const environment = { SUDO_USER: 'named-operator', SUDO_UID: '1001' } as NodeJS.ProcessEnv;
const access = (config: unknown, overrides: Partial<{ uid: number; mode: number; symlink: boolean }> = {}) => ({
  lstatSync: jest.fn(() => ({ uid: overrides.uid ?? 0, mode: overrides.mode ?? 0o100640, isSymbolicLink: () => overrides.symlink ?? false })),
  readFileSync: jest.fn(() => JSON.stringify(config)),
});
const expectCode = (fn: () => unknown, code: string) => expect(fn).toThrow(expect.objectContaining({ code }));

describe('APP-108 operator authorization', () => {
  it('derives actor solely from root/sudo identity and a root-owned allow-list', () => {
    const actor = resolveOperator(0, environment, access({ operators: { 'named-operator': { franchiseeIds: [tenant] } } }));
    expect(actor).toEqual({ actor: 'named-operator', uid: 1001, authMode: 'sudo-wrapper', franchiseeIds: [tenant] });
  });

  it('rejects direct and forged operator contexts before service invocation', () => {
    expectCode(() => resolveOperator(501, environment, access({})), 'DIRECT_INVOCATION_DENIED');
    expectCode(() => resolveOperator(0, { ...environment, SUDO_USER: 'forged!' }, access({})), 'UNVERIFIED_OPERATOR');
    expectCode(() => resolveOperator(0, { ...environment, SUDO_UID: '0' }, access({})), 'UNVERIFIED_OPERATOR');
  });

  it('rejects unsafe ownership/mode/symlink and unknown or malformed allow-lists', () => {
    const config = { operators: { 'named-operator': { franchiseeIds: [tenant] } } };
    expectCode(() => resolveOperator(0, environment, access(config, { uid: 501 })), 'OPERATOR_CONFIG_UNSAFE');
    expectCode(() => resolveOperator(0, environment, access(config, { mode: 0o100666 })), 'OPERATOR_CONFIG_UNSAFE');
    expectCode(() => resolveOperator(0, environment, access(config, { symlink: true })), 'OPERATOR_CONFIG_UNSAFE');
    expectCode(() => resolveOperator(0, environment, access({ operators: {} })), 'UNAUTHORIZED_OPERATOR');
    expectCode(() => resolveOperator(0, environment, access({ operators: { 'named-operator': { franchiseeIds: ['not-a-uuid'] } } })), 'UNAUTHORIZED_OPERATOR');
  });

  it('keeps the production config path fixed despite caller environment', () => {
    expect(operatorConfigPath({ DAMSURE_USER_ADMIN_CONFIG: '/tmp/forged' })).toBe('/etc/damsure/user-admin-operators.json');
    expect(operatorConfigPath({ NODE_ENV: 'test', DAMSURE_USER_ADMIN_CONFIG: '/tmp/test-config' })).toBe('/tmp/test-config');
  });
});
