// Shared CommonJS canonicalization is also consumed directly by Sequelize CLI migrations.
// eslint-disable-next-line @typescript-eslint/no-var-requires
const { canonicalMutablePayload, payloadHash } = require('../config/lww-payload-canonical.js') as {
	canonicalMutablePayload: (
		collection: string,
		payload: Record<string, unknown>,
	) => Record<string, unknown>;
	payloadHash: (payload: Record<string, unknown>) => string;
};

describe('APP-111 canonical mutable payloads', () => {
	const vectors: Record<string, Record<string, unknown>> = {
		clients: {
			name: 'Café 😀 \u2028',
			address: '',
			site_address: null,
			email: '',
			phone: '',
			latitude: 11.123456789,
			longitude: -0,
			discounted_price: 44.44,
		},
		items: {
			name: 'Boundary item',
			price: 99_999_999.99,
			enabled: true,
		},
		rectangles: {
			length: 11.123456789,
			width: 0.0000001,
		},
		default_prices: {
			price: 0.1,
			enabled: false,
		},
	};
	const hashes: Record<string, string> = {
		clients: 'df08a015b04e3521edaadb46197aa5ce26fd4e0fae03544d3df0db58de950f3d',
		items: 'd8ce3a82b06f7ffc13b99e76425887a03fdcd0386ffb2f8ff37d054eeef6c6df',
		rectangles: 'd734c8f3c1f3d7d2446e5d4542767f2f1a51294569e46930007a2b2f922a4d73',
		default_prices: '58014b4238e9973e2d73add9c382cc33d07c6d7ce20fbb9e016f9d666b78badc',
	};

	it('pins cross-language hashes for every LWW entity', () => {
		for (const [collection, raw] of Object.entries(vectors)) {
			expect(payloadHash(canonicalMutablePayload(collection, raw))).toBe(hashes[collection]);
		}
	});

	it('collapses only values normalized by the production storage contract', () => {
		const raw = vectors.clients;
		const canonical = canonicalMutablePayload('clients', raw);
		expect(canonical).toMatchObject({
			address: '',
			email: null,
			phone: '',
			site_address: null,
			latitude: Math.fround(11.123456789),
			longitude: 0,
		});
		const hash = (payload: Record<string, unknown>) =>
			payloadHash(canonicalMutablePayload('clients', payload));
		expect(hash({ ...raw, email: null })).toBe(hash(raw));
		expect(hash({ ...raw, longitude: 0 })).toBe(hash(raw));
		expect(hash({ ...raw, address: null })).not.toBe(hash(raw));
		expect(hash({ ...raw, site_address: '' })).not.toBe(hash(raw));
		expect(hash({ ...raw, email: 'intent@example.com' })).not.toBe(hash(raw));
	});
});
