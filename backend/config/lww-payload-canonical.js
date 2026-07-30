'use strict';

const { createHash } = require('crypto');

const stableValue = (value) => {
	if (Array.isArray(value)) return value.map(stableValue);
	if (value && typeof value === 'object') {
		return Object.fromEntries(
			Object.keys(value)
				.sort()
				.map((key) => [key, stableValue(value[key])]),
		);
	}
	return value;
};

const canonicalJson = (value) => JSON.stringify(stableValue(value));
const payloadHash = (value) => createHash('sha256').update(canonicalJson(value)).digest('hex');

const canonicalJsonNumber = (value) => (Object.is(value, -0) ? 0 : value);

const canonicalStorageReal = (value) => {
	if (value === null || value === undefined) return null;
	return canonicalJsonNumber(Math.fround(Number(value)));
};

const canonicalCurrency = (value) => {
	if (value === null || value === undefined) return null;
	return canonicalJsonNumber(Math.round(Number(value) * 100) / 100);
};

const storageRealCurrencyRoundTrips = (value) => {
	const cents = Math.round(Number(value) * 100);
	return Math.round(Math.fround(cents / 100) * 100) === cents;
};

const canonicalMutablePayload = (collection, payload) => {
	if (Object.keys(payload).length === 0) return {};
	switch (collection) {
		case 'clients':
			return {
				address: payload.address,
				discounted_price: canonicalCurrency(payload.discounted_price),
				email: payload.email === '' ? null : payload.email,
				latitude: canonicalStorageReal(payload.latitude),
				longitude: canonicalStorageReal(payload.longitude),
				name: payload.name,
				phone: payload.phone,
				site_address: payload.site_address,
			};
		case 'items':
			return {
				enabled: payload.enabled,
				name: payload.name,
				price: canonicalCurrency(payload.price),
			};
		case 'rectangles':
			return {
				length: canonicalStorageReal(payload.length),
				width: canonicalStorageReal(payload.width),
			};
		case 'default_prices':
			return {
				enabled: payload.enabled,
				price: canonicalCurrency(payload.price),
			};
		default:
			throw new Error(`Unknown LWW entity ${collection}`);
	}
};

module.exports = {
	canonicalCurrency,
	canonicalJson,
	canonicalMutablePayload,
	canonicalStorageReal,
	payloadHash,
	storageRealCurrencyRoundTrips,
};
