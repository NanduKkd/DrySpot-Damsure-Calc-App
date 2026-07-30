import { getJwtSecret } from './jwt';

describe('JWT configuration', () => {
	const originalSecret = process.env.JWT_SECRET;

	afterEach(() => {
		process.env.JWT_SECRET = originalSecret;
	});

	it.each([
		'',
		'secret',
		'your_jwt_secret',
		'your-super-secret-jwt-key-change-in-production',
		'short-but-not-a-known-default',
	])('rejects missing, known, or short secrets', (secret) => {
		process.env.JWT_SECRET = secret;
		expect(() => getJwtSecret()).toThrow(/at least 32 characters/);
	});

	it('accepts a sufficiently long non-default secret', () => {
		process.env.JWT_SECRET = '0123456789abcdef0123456789abcdef';
		expect(getJwtSecret()).toBe('0123456789abcdef0123456789abcdef');
	});
});
