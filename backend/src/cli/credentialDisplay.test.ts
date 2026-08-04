import { displayNewGeneratedCredential } from './credentialDisplay';

describe('APP-108 credential display', () => {
  it('writes exactly one newly generated credential and never echoes supplied or replayed secrets', () => {
    const display = jest.fn();
    const user = { id: '10000000-0000-4000-8000-000000000001', email: 'user@example.com', franchiseeId: '20000000-0000-4000-8000-000000000002', isActive: true, tokenVersion: 0 };
    displayNewGeneratedCredential({ outcome: 'succeeded', reasonCode: 'APPLIED', user, generatedPassword: 'generated-secret' }, display);
    displayNewGeneratedCredential({ outcome: 'succeeded', reasonCode: 'APPLIED', user }, display);
    expect(display).toHaveBeenCalledTimes(1);
    expect(display).toHaveBeenCalledWith('generated-secret');
  });
});
