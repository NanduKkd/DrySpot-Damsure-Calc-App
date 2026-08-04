import { randomUUID } from 'crypto';
import { Op, Transaction, ValidationError } from 'sequelize';
import {
	Client,
	DefaultPrice,
	Item,
	Proposal,
	Rectangle,
	SyncV2ChangeReceipt,
	SyncV2Request,
	Warranty,
	WarrantyDeletionSequence,
} from '../models';
import {
	queueManagedFileCleanup,
	reconcileManagedFileCleanupByStorageKeys,
} from './managedFileCleanup';
import { tombstoneClientWarranties, warrantyTombstonesAfter } from './warrantyLifecycle';
import {
	lockTenantSyncState,
	MAX_TENANT_SYNC_CURSOR,
	nextTenantSyncCursor,
	TenantCursorExhaustedError,
} from './tenantSyncCursor';
import { terminalizeClientPhotoUploadReceipts } from './clientPhotoUploadReceipt';

export const MAX_SYNC_BIGINT = MAX_TENANT_SYNC_CURSOR;
export const MAX_BRANCH_SEQUENCE = 1_000_000;
export const MAX_PRICE = 99_999_999.99;
export const MAX_IMAGE_DATA_BYTES = 15 * 1024 * 1024;
export const MAX_CLIENT_PHOTOS = 100;
export const MAX_SYNC_RESPONSE_RECORDS = 1_000;
const MAX_CHANGES_PER_COLLECTION = 100;
const MAX_CHANGES_PER_REQUEST = 300;
const MAX_SYNC_REQUEST_BYTES = 20 * 1024 * 1024;
const COLLECTIONS = ['clients', 'items', 'rectangles', 'default_prices'] as const;
const UUID_V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const MANAGED_PHOTO = /^\/api\/photos\/client\/[0-9a-f-]{36}\/([0-9a-f-]{36}\.(?:jpg|png|webp))$/i;

type Collection = (typeof COLLECTIONS)[number];
type SyncVisibleCollection = Collection | 'warranties' | 'proposals';
type Operation = 'upsert' | 'delete';
type OutcomeStatus =
	| 'applied'
	| 'already_applied'
	| 'superseded'
	| 'rejected'
	| 'permanently_deleted'
	| 'unauthorized';

type JsonObject = Record<string, unknown>;

// Shared CommonJS canonicalization is also consumed directly by Sequelize CLI migrations.
// eslint-disable-next-line @typescript-eslint/no-var-requires
const canonicalPayload = require('../../config/lww-payload-canonical.js') as {
	canonicalJson: (value: unknown) => string;
	canonicalMutablePayload: (collection: Collection, payload: JsonObject) => JsonObject;
	canonicalStorageReal: (value: number | null) => number | null;
	payloadHash: (value: unknown) => string;
	storageRealCurrencyRoundTrips: (value: number) => boolean;
};

export const canonicalJson = canonicalPayload.canonicalJson;
export const payloadHash = canonicalPayload.payloadHash;
const canonicalMutablePayload = canonicalPayload.canonicalMutablePayload;
const canonicalStorageReal = canonicalPayload.canonicalStorageReal;
const storageRealCurrencyRoundTrips = canonicalPayload.storageRealCurrencyRoundTrips;

export interface ParsedChange {
	collection: Collection;
	remoteId: string;
	operation: Operation;
	baseGeneration: bigint;
	generation: bigint;
	branchSeq: number;
	writerId: string;
	changeId: string;
	parentId?: string;
	payload: JsonObject;
	payloadHash: string;
	changeHash: string;
	media?: JsonObject;
	deviceTimestamp?: string;
}

export interface ParsedEnvelope {
	requestId: string;
	requestCursor: bigint;
	warrantyTombstoneCursor: bigint;
	changes: Record<Collection, ParsedChange[]>;
	requestHash: string;
	warnings: Array<Record<string, string>>;
}

export interface SyncV2Response {
	protocol_version: 2;
	request_id: string;
	response_cursor: string;
	warranty_tombstone_cursor: string;
	outcomes: Record<Collection, Array<Record<string, unknown>>>;
	warnings: Array<Record<string, string>>;
	updates: Record<string, unknown[]>;
}

export class SyncEnvelopeError extends Error {
	constructor(
		public readonly code: string,
		message: string,
		public readonly status = 400,
	) {
		super(message);
	}
}

export class SyncTenantAuthorizationError extends Error {
	constructor(public readonly outcomes: Record<Collection, Array<Record<string, unknown>>>) {
		super('The sync request is not authorized.');
	}
}

const isObject = (value: unknown): value is JsonObject =>
	value !== null && typeof value === 'object' && !Array.isArray(value);

const exactKeys = (
	value: JsonObject,
	allowed: readonly string[],
	required: readonly string[],
	label: string,
) => {
	for (const key of Object.keys(value)) {
		if (!allowed.includes(key)) {
			throw new SyncEnvelopeError('malformed_envelope', `${label} contains ${key}.`);
		}
	}
	for (const key of required) {
		if (!(key in value)) {
			throw new SyncEnvelopeError('malformed_envelope', `${label} is missing ${key}.`);
		}
	}
};

export const parseDecimalBigint = (value: unknown, label: string, allowZero: boolean) => {
	if (typeof value !== 'string' || !/^(0|[1-9]\d*)$/.test(value)) {
		throw new SyncEnvelopeError(
			'invalid_integer',
			`${label} must be a canonical decimal string.`,
		);
	}
	const parsed = BigInt(value);
	if ((!allowZero && parsed === 0n) || parsed > MAX_SYNC_BIGINT) {
		throw new SyncEnvelopeError(
			'invalid_integer',
			`${label} is outside the PostgreSQL BIGINT range.`,
		);
	}
	return parsed;
};

const canonicalUuidV4 = (value: unknown, label: string) => {
	if (typeof value !== 'string' || !UUID_V4.test(value)) {
		throw new SyncEnvelopeError('invalid_uuid', `${label} must be a UUIDv4.`);
	}
	return value.toLowerCase();
};

const warningForDeviceTimestamp = (
	value: unknown,
	changeId: string,
	now: Date,
): Record<string, string> | undefined => {
	if (value === undefined || value === null) return undefined;
	if (typeof value !== 'string') {
		return {
			code: 'device_timestamp_discarded',
			change_id: changeId,
			reason: 'invalid',
		};
	}
	const parsed = new Date(value);
	if (Number.isNaN(parsed.getTime())) {
		return {
			code: 'device_timestamp_discarded',
			change_id: changeId,
			reason: 'invalid',
		};
	}
	if (parsed.getTime() > now.getTime() + 5 * 60 * 1000) {
		return {
			code: 'device_timestamp_discarded',
			change_id: changeId,
			reason: 'future',
		};
	}
	return undefined;
};

export const parseSyncV2Envelope = (body: unknown, now = new Date()): ParsedEnvelope => {
	if (!isObject(body)) {
		throw new SyncEnvelopeError('malformed_envelope', 'The request body must be an object.');
	}
	if (Buffer.byteLength(canonicalJson(body), 'utf8') > MAX_SYNC_REQUEST_BYTES) {
		throw new SyncEnvelopeError(
			'request_too_large',
			'Sync protocol v2 requests are limited to 20 MiB.',
			413,
		);
	}
	exactKeys(
		body,
		[
			'protocol_version',
			'request_id',
			'request_cursor',
			'warranty_tombstone_cursor',
			'changes',
		],
		['protocol_version', 'request_id', 'request_cursor', 'changes'],
		'request',
	);
	if (body.protocol_version !== 2) {
		throw new SyncEnvelopeError('unsupported_protocol', 'protocol_version must be exactly 2.');
	}
	const requestId = canonicalUuidV4(body.request_id, 'request_id');
	const requestCursor = parseDecimalBigint(body.request_cursor, 'request_cursor', true);
	const warrantyTombstoneCursor = parseDecimalBigint(
		body.warranty_tombstone_cursor ?? '0',
		'warranty_tombstone_cursor',
		true,
	);
	if (!isObject(body.changes)) {
		throw new SyncEnvelopeError('malformed_envelope', 'changes must be an object.');
	}
	exactKeys(body.changes, COLLECTIONS, [], 'changes');

	const changes: Record<Collection, ParsedChange[]> = {
		clients: [],
		items: [],
		rectangles: [],
		default_prices: [],
	};
	const warnings: Array<Record<string, string>> = [];
	const seenChangeIds = new Set<string>();
	let total = 0;

	for (const collection of COLLECTIONS) {
		const rawCollection = body.changes[collection] ?? [];
		if (!Array.isArray(rawCollection)) {
			throw new SyncEnvelopeError('malformed_envelope', `${collection} must be an array.`);
		}
		if (rawCollection.length > MAX_CHANGES_PER_COLLECTION) {
			throw new SyncEnvelopeError(
				'collection_too_large',
				`${collection} exceeds ${MAX_CHANGES_PER_COLLECTION} changes.`,
			);
		}
		total += rawCollection.length;
		for (let index = 0; index < rawCollection.length; index += 1) {
			const raw = rawCollection[index];
			if (!isObject(raw)) {
				throw new SyncEnvelopeError(
					'malformed_envelope',
					`${collection}[${index}] must be an object.`,
				);
			}
			exactKeys(
				raw,
				[
					'remote_id',
					'operation',
					'base_generation',
					'generation',
					'branch_seq',
					'writer_id',
					'change_id',
					'parent_id',
					'payload',
					'media',
					'device_timestamp',
				],
				[
					'remote_id',
					'operation',
					'base_generation',
					'generation',
					'branch_seq',
					'writer_id',
					'change_id',
					'payload',
				],
				`${collection}[${index}]`,
			);
			if (raw.operation !== 'upsert' && raw.operation !== 'delete') {
				throw new SyncEnvelopeError(
					'invalid_operation',
					`${collection}[${index}].operation is invalid.`,
				);
			}
			const remoteId = canonicalUuidV4(raw.remote_id, `${collection}.remote_id`);
			const writerId = canonicalUuidV4(raw.writer_id, `${collection}.writer_id`);
			const changeId = canonicalUuidV4(raw.change_id, `${collection}.change_id`);
			if (seenChangeIds.has(changeId)) {
				throw new SyncEnvelopeError(
					'duplicate_change_id',
					'A change_id may occur only once per request.',
				);
			}
			seenChangeIds.add(changeId);
			const baseGeneration = parseDecimalBigint(
				raw.base_generation,
				`${collection}.base_generation`,
				true,
			);
			const generation = parseDecimalBigint(
				raw.generation,
				`${collection}.generation`,
				false,
			);
			if (baseGeneration === MAX_SYNC_BIGINT || generation !== baseGeneration + 1n) {
				throw new SyncEnvelopeError(
					'invalid_generation',
					'generation must be exactly base_generation + 1.',
				);
			}
			if (
				!Number.isInteger(raw.branch_seq) ||
				(raw.branch_seq as number) < 1 ||
				(raw.branch_seq as number) > MAX_BRANCH_SEQUENCE
			) {
				throw new SyncEnvelopeError(
					'invalid_branch_sequence',
					`branch_seq must be between 1 and ${MAX_BRANCH_SEQUENCE}.`,
				);
			}
			if (!isObject(raw.payload)) {
				throw new SyncEnvelopeError('invalid_payload', 'payload must be an object.');
			}
			if (raw.operation === 'delete' && Object.keys(raw.payload).length !== 0) {
				throw new SyncEnvelopeError('invalid_payload', 'A delete payload must be empty.');
			}
			if (raw.media !== undefined && !isObject(raw.media)) {
				throw new SyncEnvelopeError('invalid_payload', 'media must be an object.');
			}
			if (
				raw.operation === 'delete' &&
				raw.media !== undefined &&
				Object.keys(raw.media).length !== 0
			) {
				throw new SyncEnvelopeError(
					'invalid_payload',
					'A delete media payload must be empty.',
				);
			}
			const parentId =
				raw.parent_id === undefined || raw.parent_id === null
					? undefined
					: canonicalUuidV4(raw.parent_id, `${collection}.parent_id`);
			if ((collection === 'clients' || collection === 'default_prices') && parentId) {
				throw new SyncEnvelopeError(
					'invalid_parent',
					`${collection} changes cannot carry parent_id.`,
				);
			}
			const warning = warningForDeviceTimestamp(raw.device_timestamp, changeId, now);
			if (warning) warnings.push(warning);
			changes[collection].push({
				collection,
				remoteId,
				operation: raw.operation,
				baseGeneration,
				generation,
				branchSeq: raw.branch_seq as number,
				writerId,
				changeId,
				parentId,
				payload: raw.payload,
				payloadHash: payloadHash(raw.payload),
				changeHash: payloadHash({
					collection,
					remote_id: remoteId,
					operation: raw.operation,
					base_generation: baseGeneration.toString(),
					generation: generation.toString(),
					branch_seq: raw.branch_seq,
					writer_id: writerId,
					change_id: changeId,
					parent_id: parentId ?? null,
					payload: raw.payload,
					media: raw.media ?? null,
				}),
				media: raw.media,
				deviceTimestamp: warning ? undefined : (raw.device_timestamp as string | undefined),
			});
		}
	}
	if (total > MAX_CHANGES_PER_REQUEST) {
		throw new SyncEnvelopeError(
			'request_too_large',
			`A sync request may contain at most ${MAX_CHANGES_PER_REQUEST} changes.`,
		);
	}

	return {
		requestId,
		requestCursor,
		warrantyTombstoneCursor,
		changes,
		requestHash: payloadHash(body),
		warnings,
	};
};

const nullableString = (payload: JsonObject, key: string, maxLength: number): string | null => {
	const value = payload[key];
	if (value === null || value === undefined) return null;
	if (typeof value !== 'string' || value.length > maxLength) {
		throw new BusinessRejection('invalid_payload');
	}
	return value;
};

const finiteNumber = (
	payload: JsonObject,
	key: string,
	minimum: number,
	maximum: number,
	nullable = false,
): number | null => {
	const value = payload[key];
	if (nullable && (value === null || value === undefined)) return null;
	if (
		typeof value !== 'number' ||
		!Number.isFinite(value) ||
		value < minimum ||
		value > maximum
	) {
		throw new BusinessRejection('invalid_payload');
	}
	return value;
};

const currencyNumber = (payload: JsonObject, key: string, nullable = false): number | null => {
	const value = finiteNumber(payload, key, 0, MAX_PRICE, nullable);
	if (value === null) return null;
	if (Math.round(value * 100) / 100 !== value) {
		throw new BusinessRejection('invalid_payload');
	}
	return value;
};

const storageRealNumber = (
	payload: JsonObject,
	key: string,
	minimum: number,
	maximum: number,
	nullable = false,
): number | null => {
	const value = finiteNumber(payload, key, minimum, maximum, nullable);
	if (value === null) return null;
	const canonical = canonicalStorageReal(value);
	if (
		canonical === null ||
		!Number.isFinite(canonical) ||
		canonical < minimum ||
		canonical > maximum
	) {
		throw new BusinessRejection('invalid_payload');
	}
	return canonical;
};

const storageRealCurrencyNumber = (
	payload: JsonObject,
	key: string,
	nullable = false,
): number | null => {
	const value = currencyNumber(payload, key, nullable);
	if (value === null) return null;
	if (!storageRealCurrencyRoundTrips(value)) {
		throw new BusinessRejection('invalid_payload');
	}
	return value;
};

class BusinessRejection extends Error {
	constructor(public readonly reasonCode: string) {
		super(reasonCode);
	}
}

const assertPayloadKeys = (
	payload: JsonObject,
	required: readonly string[],
	optional: readonly string[],
) => {
	const allowed = [...required, ...optional];
	const forbidden = [
		'franchisee_id',
		'franchiseeId',
		'client_id',
		'clientId',
		'item_id',
		'itemId',
		'photos',
		'image_data',
		'imageData',
		'pdf_url',
		'pdfUrl',
		'pdf_file_name',
		'pdfFileName',
		'deleted_at',
		'updated_at',
		'created_at',
		'is_dirty',
		'local_id',
		'sync_cursor',
		'lww_generation',
	];
	for (const key of Object.keys(payload)) {
		if (!allowed.includes(key)) {
			throw new BusinessRejection(
				forbidden.includes(key) ? 'server_field_forbidden' : 'unknown_field',
			);
		}
	}
	for (const key of required) {
		if (!(key in payload)) throw new BusinessRejection('invalid_payload');
	}
};

const canonicalizePayload = (change: ParsedChange): JsonObject => {
	if (change.operation === 'delete') return {};
	const payload = change.payload;
	switch (change.collection) {
		case 'clients': {
			assertPayloadKeys(
				payload,
				[
					'name',
					'address',
					'site_address',
					'email',
					'phone',
					'latitude',
					'longitude',
					'discounted_price',
				],
				[],
			);
			if (
				typeof payload.name !== 'string' ||
				payload.name.trim().length === 0 ||
				payload.name.length > 255
			) {
				throw new BusinessRejection('invalid_payload');
			}
			let email = nullableString(payload, 'email', 255);
			if (email === '') email = null;
			if (email && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) {
				throw new BusinessRejection('invalid_payload');
			}
			return canonicalMutablePayload('clients', {
				address: nullableString(payload, 'address', 255),
				discounted_price: storageRealCurrencyNumber(payload, 'discounted_price', true),
				email,
				latitude: storageRealNumber(payload, 'latitude', -90, 90, true),
				longitude: storageRealNumber(payload, 'longitude', -180, 180, true),
				name: payload.name,
				phone: nullableString(payload, 'phone', 255),
				site_address: nullableString(payload, 'site_address', 255),
			});
		}
		case 'items':
			assertPayloadKeys(payload, ['name', 'price', 'enabled'], []);
			if (
				typeof payload.name !== 'string' ||
				payload.name.trim().length === 0 ||
				payload.name.length > 255 ||
				typeof payload.enabled !== 'boolean'
			) {
				throw new BusinessRejection('invalid_payload');
			}
			return canonicalMutablePayload('items', {
				enabled: payload.enabled,
				name: payload.name,
				price: currencyNumber(payload, 'price'),
			});
		case 'rectangles':
			assertPayloadKeys(payload, ['length', 'width'], []);
			return canonicalMutablePayload('rectangles', {
				length: storageRealNumber(payload, 'length', Number.MIN_VALUE, 10_000),
				width: storageRealNumber(payload, 'width', Number.MIN_VALUE, 10_000),
			});
		case 'default_prices':
			assertPayloadKeys(payload, ['price', 'enabled'], []);
			if (typeof payload.enabled !== 'boolean') {
				throw new BusinessRejection('invalid_payload');
			}
			return canonicalMutablePayload('default_prices', {
				enabled: payload.enabled,
				price: currencyNumber(payload, 'price'),
			});
	}
};

const validateMedia = (change: ParsedChange): JsonObject | undefined => {
	if (change.operation === 'delete') return undefined;
	const media = change.media;
	if (change.collection !== 'rectangles') {
		if (media !== undefined && Object.keys(media).length) {
			throw new BusinessRejection('server_field_forbidden');
		}
		return undefined;
	}
	if (media === undefined) return undefined;
	assertPayloadKeys(media, ['image_data'], []);
	const imageData = media.image_data;
	if (imageData === null) return { image_data: null };
	if (
		typeof imageData !== 'string' ||
		Buffer.byteLength(imageData, 'utf8') > MAX_IMAGE_DATA_BYTES ||
		!/^data:image\/(?:jpeg|png|webp|gif);base64,[A-Za-z0-9+/]+={0,2}$/.test(imageData)
	) {
		throw new BusinessRejection('invalid_payload');
	}
	return { image_data: imageData };
};

const operationRank = (operation: Operation) => (operation === 'delete' ? 1 : 0);

const compareText = (left: string, right: string) => (left < right ? -1 : left > right ? 1 : 0);

const compareCandidate = (change: ParsedChange, existing: any) => {
	const generation = BigInt(existing.lwwGeneration);
	if (change.generation !== generation) return change.generation < generation ? -1 : 1;
	if (change.branchSeq !== existing.lwwBranchSeq) {
		return change.branchSeq < existing.lwwBranchSeq ? -1 : 1;
	}
	const rank = operationRank(change.operation);
	if (rank !== existing.lwwOperationRank) {
		return rank < existing.lwwOperationRank ? -1 : 1;
	}
	const writerComparison = compareText(change.writerId, existing.lwwWriterId);
	if (writerComparison !== 0) return writerComparison;
	return compareText(change.changeId, existing.lwwChangeId);
};

const outcome = (
	change: ParsedChange,
	status: OutcomeStatus,
	reasonCode?: string,
	authoritative?: Record<string, unknown>,
) => ({
	change_id: change.changeId,
	remote_id: change.remoteId,
	status,
	...(reasonCode ? { reason_code: reasonCode } : {}),
	...(authoritative ? { authoritative } : {}),
});

const activeClient = async (
	id: string | undefined,
	franchiseeId: string,
	transaction: Transaction,
) => {
	if (!id) throw new BusinessRejection('parent_required');
	const client = await Client.findByPk(id, {
		paranoid: false,
		transaction,
		lock: transaction.LOCK.UPDATE,
	});
	if (!client || client.franchiseeId !== franchiseeId || client.deletedAt) {
		throw new BusinessRejection('parent_unavailable');
	}
	return client;
};

const activeItem = async (
	id: string | undefined,
	franchiseeId: string,
	transaction: Transaction,
) => {
	if (!id) throw new BusinessRejection('parent_required');
	const item = await Item.findByPk(id, {
		paranoid: false,
		transaction,
		lock: transaction.LOCK.UPDATE,
	});
	if (!item || item.deletedAt) throw new BusinessRejection('parent_unavailable');
	await activeClient(item.clientId, franchiseeId, transaction);
	return item;
};

const tenantForExisting = async (
	collection: Collection,
	existing: any,
	transaction: Transaction,
) => {
	switch (collection) {
		case 'clients':
		case 'default_prices':
			return existing.franchiseeId as string;
		case 'items': {
			const client = await Client.findByPk(existing.clientId, {
				paranoid: false,
				transaction,
			});
			if (!client) throw new Error('Existing item has no client.');
			return client.franchiseeId;
		}
		case 'rectangles': {
			const item = await Item.findByPk(existing.itemId, {
				paranoid: false,
				transaction,
			});
			if (!item) throw new Error('Existing rectangle has no item.');
			const client = await Client.findByPk(item.clientId, {
				paranoid: false,
				transaction,
			});
			if (!client) throw new Error('Existing rectangle has no tenant-owned client.');
			return client.franchiseeId;
		}
	}
};

const modelFor = (collection: Collection): any => {
	switch (collection) {
		case 'clients':
			return Client;
		case 'items':
			return Item;
		case 'rectangles':
			return Rectangle;
		case 'default_prices':
			return DefaultPrice;
	}
};

const canonicalClientPhotos = (record: any): string[] => {
	let raw: unknown = record.photos;
	if (typeof raw === 'string') {
		try {
			raw = JSON.parse(raw);
		} catch {
			throw new SyncEnvelopeError(
				'invalid_authoritative_state',
				'Stored client photo metadata is malformed.',
				500,
			);
		}
	}
	if (!Array.isArray(raw) || raw.length > MAX_CLIENT_PHOTOS) {
		throw new SyncEnvelopeError(
			'invalid_authoritative_state',
			'Stored client photo metadata exceeds protocol bounds.',
			500,
		);
	}
	const pattern = new RegExp(
		`^/api/photos/client/${record.id}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\.(?:jpg|png|webp)$`,
		'i',
	);
	const photos = raw.filter(
		(value): value is string => typeof value === 'string' && pattern.test(value),
	);
	if (photos.length !== raw.length || new Set(photos).size !== photos.length) {
		throw new SyncEnvelopeError(
			'invalid_authoritative_state',
			'Stored client photo metadata is not canonical.',
			500,
		);
	}
	return photos;
};

export const serializeLwwRecord = (collection: Collection, record: any) => {
	const common = {
		remote_id: record.id,
		generation: record.lwwGeneration.toString(),
		branch_seq: record.lwwBranchSeq,
		operation: record.lwwOperationRank === 1 ? 'delete' : 'upsert',
		writer_id: record.lwwWriterId,
		change_id: record.lwwChangeId,
		payload_hash: record.lwwPayloadHash,
		row_cursor: record.syncCursor.toString(),
		server_timestamp: record.updatedAt.toISOString(),
		deleted_at: record.deletedAt ? record.deletedAt.toISOString() : null,
	};
	switch (collection) {
		case 'clients':
			return {
				...common,
				franchisee_id: record.franchiseeId,
				payload: record.deletedAt
					? {}
					: canonicalMutablePayload('clients', {
							address: record.address ?? null,
							discounted_price:
								record.discountedPrice === null
									? null
									: Number(record.discountedPrice),
							email: record.email ?? null,
							latitude: record.latitude === null ? null : Number(record.latitude),
							longitude: record.longitude === null ? null : Number(record.longitude),
							name: record.name,
							phone: record.phone ?? null,
							site_address: record.siteAddress ?? null,
						}),
				media: {
					photos: record.deletedAt ? [] : canonicalClientPhotos(record),
				},
			};
		case 'items':
			return {
				...common,
				parent_id: record.clientId,
				payload: record.deletedAt
					? {}
					: canonicalMutablePayload('items', {
							enabled: Boolean(record.enabled),
							name: record.name,
							price: Number(record.price),
						}),
			};
		case 'rectangles':
			if (
				record.imageData !== null &&
				Buffer.byteLength(String(record.imageData), 'utf8') > MAX_IMAGE_DATA_BYTES
			) {
				throw new SyncEnvelopeError(
					'invalid_authoritative_state',
					'Stored rectangle image data exceeds protocol bounds.',
					500,
				);
			}
			return {
				...common,
				parent_id: record.itemId,
				payload: record.deletedAt
					? {}
					: canonicalMutablePayload('rectangles', {
							length: Number(record.length),
							width: Number(record.width),
						}),
				media: {
					image_data: record.deletedAt ? null : (record.imageData ?? null),
				},
			};
		case 'default_prices':
			return {
				...common,
				franchisee_id: record.franchiseeId,
				payload: record.deletedAt
					? {}
					: canonicalMutablePayload('default_prices', {
							enabled: Boolean(record.enabled),
							price: Number(record.price),
						}),
			};
	}
};

const findExisting = async (change: ParsedChange, transaction: Transaction, lock = true) =>
	modelFor(change.collection).findByPk(change.remoteId, {
		paranoid: false,
		transaction,
		...(lock ? { lock: transaction.LOCK.UPDATE } : {}),
	});

const unauthorizedOutcomes = (envelope: ParsedEnvelope) => {
	const outcomes: Record<Collection, Array<Record<string, unknown>>> = {
		clients: [],
		items: [],
		rectangles: [],
		default_prices: [],
	};
	for (const collection of COLLECTIONS) {
		outcomes[collection] = envelope.changes[collection].map((change) =>
			outcome(change, 'unauthorized', 'not_authorized'),
		);
	}
	return outcomes;
};

const preflightTenant = async (
	envelope: ParsedEnvelope,
	franchiseeId: string,
	transaction: Transaction,
) => {
	for (const collection of COLLECTIONS) {
		for (const change of envelope.changes[collection]) {
			const existing = await findExisting(change, transaction, false);
			if (
				existing &&
				(await tenantForExisting(collection, existing, transaction)) !== franchiseeId
			) {
				throw new SyncTenantAuthorizationError(unauthorizedOutcomes(envelope));
			}
			if (change.parentId) {
				if (collection === 'items') {
					const parent = await Client.findByPk(change.parentId, {
						paranoid: false,
						transaction,
					});
					if (parent && parent.franchiseeId !== franchiseeId) {
						throw new SyncTenantAuthorizationError(unauthorizedOutcomes(envelope));
					}
				}
				if (collection === 'rectangles') {
					const parent = await Item.findByPk(change.parentId, {
						paranoid: false,
						transaction,
					});
					if (
						parent &&
						(await tenantForExisting('items', parent, transaction)) !== franchiseeId
					) {
						throw new SyncTenantAuthorizationError(unauthorizedOutcomes(envelope));
					}
				}
			}
		}
	}
};

const applyRecord = async (
	change: ParsedChange,
	normalizedPayload: JsonObject,
	normalizedMedia: JsonObject | undefined,
	existing: any,
	franchiseeId: string,
	nextCursor: bigint,
	transaction: Transaction,
	cleanupKeys: string[],
) => {
	let parentId = change.parentId;
	if (change.collection === 'items') {
		if (existing && parentId && existing.clientId !== parentId) {
			throw new BusinessRejection('immutable_parent');
		}
		parentId = existing?.clientId ?? parentId;
		await activeClient(parentId, franchiseeId, transaction);
	}
	if (change.collection === 'rectangles') {
		if (existing && parentId && existing.itemId !== parentId) {
			throw new BusinessRejection('immutable_parent');
		}
		parentId = existing?.itemId ?? parentId;
		await activeItem(parentId, franchiseeId, transaction);
	}

	const metadata = {
		lwwGeneration: change.generation.toString(),
		lwwBranchSeq: change.branchSeq,
		lwwOperationRank: operationRank(change.operation),
		lwwWriterId: change.writerId,
		lwwChangeId: change.changeId,
		lwwPayloadHash: change.payloadHash,
		syncCursor: nextCursor.toString(),
	};
	const now = new Date();

	if (change.operation === 'delete') {
		if (change.collection === 'clients' && existing && !existing.deletedAt) {
			const rawPhotos =
				typeof existing.photos === 'string'
					? (() => {
							try {
								return JSON.parse(existing.photos);
							} catch {
								return [];
							}
						})()
					: [];
			for (const photo of Array.isArray(rawPhotos) ? rawPhotos : []) {
				const match = typeof photo === 'string' && photo.match(MANAGED_PHOTO);
				if (match) {
					await queueManagedFileCleanup('photo', match[1], transaction);
					cleanupKeys.push(match[1]);
				}
			}
			await terminalizeClientPhotoUploadReceipts({
				franchiseeId,
				clientId: existing.id,
				canonicalUrls: (Array.isArray(rawPhotos) ? rawPhotos : []).filter(
					(photo): photo is string =>
						typeof photo === 'string' && MANAGED_PHOTO.test(photo),
				),
				transaction,
			});
			cleanupKeys.push(
				...(await tombstoneClientWarranties({
					clientId: existing.id,
					franchiseeId,
					transaction,
				})),
			);
			const proposals = await Proposal.findAll({
				where: { clientId: existing.id },
				transaction,
				lock: transaction.LOCK.UPDATE,
			});
			for (const proposal of proposals) {
				if (
					proposal.pdfFileName &&
					!proposal.pdfFileName.includes('/') &&
					!proposal.pdfFileName.includes('\\')
				) {
					await queueManagedFileCleanup('pdf', proposal.pdfFileName, transaction);
					cleanupKeys.push(proposal.pdfFileName);
				}
				await proposal.update({ syncCursor: nextCursor.toString() }, { transaction });
				await proposal.destroy({ transaction });
			}
		}

		const deleteValues: JsonObject = {
			...metadata,
			deletedAt: now,
			...(change.collection === 'clients' ? { photos: '[]' } : {}),
			...(change.collection === 'rectangles' ? { imageData: null } : {}),
		};
		if (existing) {
			await modelFor(change.collection).update(deleteValues, {
				where: { id: change.remoteId },
				paranoid: false,
				transaction,
			});
		} else {
			switch (change.collection) {
				case 'clients':
					await Client.create(
						{
							id: change.remoteId,
							franchiseeId,
							name: '',
							photos: '[]',
							...deleteValues,
						},
						{ transaction },
					);
					break;
				case 'items':
					await Item.create(
						{
							id: change.remoteId,
							clientId: parentId!,
							name: '',
							price: 0,
							enabled: false,
							...deleteValues,
						},
						{ transaction },
					);
					break;
				case 'rectangles':
					await Rectangle.create(
						{
							id: change.remoteId,
							itemId: parentId!,
							length: 1,
							width: 1,
							imageData: null,
							...deleteValues,
						},
						{ transaction },
					);
					break;
				case 'default_prices':
					await DefaultPrice.create(
						{
							id: change.remoteId,
							franchiseeId,
							price: 0,
							enabled: false,
							...deleteValues,
						},
						{ transaction },
					);
					break;
			}
		}
	} else {
		const upsertValues: JsonObject = { ...metadata, deletedAt: null };
		switch (change.collection) {
			case 'clients':
				Object.assign(upsertValues, {
					name: normalizedPayload.name,
					address: normalizedPayload.address,
					siteAddress: normalizedPayload.site_address,
					email: normalizedPayload.email,
					phone: normalizedPayload.phone,
					latitude: normalizedPayload.latitude,
					longitude: normalizedPayload.longitude,
					discountedPrice: normalizedPayload.discounted_price,
				});
				break;
			case 'items':
				Object.assign(upsertValues, {
					clientId: parentId,
					name: normalizedPayload.name,
					price: normalizedPayload.price,
					enabled: normalizedPayload.enabled,
				});
				break;
			case 'rectangles':
				Object.assign(upsertValues, {
					itemId: parentId,
					length: normalizedPayload.length,
					width: normalizedPayload.width,
					...(normalizedMedia ? { imageData: normalizedMedia.image_data } : {}),
				});
				break;
			case 'default_prices':
				Object.assign(upsertValues, {
					franchiseeId,
					price: normalizedPayload.price,
					enabled: normalizedPayload.enabled,
				});
				break;
		}
		if (existing) {
			await modelFor(change.collection).update(upsertValues, {
				where: { id: change.remoteId },
				paranoid: false,
				transaction,
			});
		} else {
			await modelFor(change.collection).create(
				{
					id: change.remoteId,
					...(change.collection === 'clients' ? { franchiseeId, photos: '[]' } : {}),
					...upsertValues,
				},
				{ transaction },
			);
		}
	}
	return modelFor(change.collection).findByPk(change.remoteId, {
		paranoid: false,
		transaction,
	});
};

const processChange = async (
	change: ParsedChange,
	franchiseeId: string,
	nextCursor: bigint,
	transaction: Transaction,
	cleanupKeys: string[],
) => {
	const receipt = await SyncV2ChangeReceipt.findOne({
		where: { franchiseeId, changeId: change.changeId },
		transaction,
		lock: transaction.LOCK.UPDATE,
	});
	if (receipt) {
		const legacySame =
			receipt.changeHash === null &&
			receipt.entityType === change.collection &&
			receipt.entityId === change.remoteId &&
			BigInt(receipt.generation) === change.generation &&
			receipt.branchSeq === change.branchSeq &&
			receipt.operationRank === operationRank(change.operation) &&
			receipt.writerId === change.writerId &&
			receipt.payloadHash === change.payloadHash;
		const same = receipt.changeHash === change.changeHash || legacySame;
		if (!same) {
			return {
				applied: false,
				outcome: outcome(change, 'rejected', 'change_id_reused'),
			};
		}
		if (receipt.outcomeJson) {
			return {
				applied: false,
				outcome: JSON.parse(receipt.outcomeJson) as Record<string, unknown>,
			};
		}
		const current = await findExisting(change, transaction);
		return {
			applied: false,
			outcome: outcome(
				change,
				'applied',
				change.operation === 'delete' ? 'delete_applied' : 'upsert_applied',
				current ? serializeLwwRecord(change.collection, current) : undefined,
			),
		};
	}

	const persistTerminal = async (
		result: Record<string, unknown>,
		effectivePayloadHash: string,
	) => {
		await SyncV2ChangeReceipt.create(
			{
				franchiseeId,
				changeId: change.changeId,
				entityType: change.collection,
				entityId: change.remoteId,
				generation: change.generation.toString(),
				branchSeq: change.branchSeq,
				operationRank: operationRank(change.operation),
				writerId: change.writerId,
				payloadHash: effectivePayloadHash,
				changeHash: change.changeHash,
				outcomeJson: JSON.stringify(result),
			},
			{ transaction },
		);
		return result;
	};

	try {
		const normalizedPayload = canonicalizePayload(change);
		const normalizedMedia = validateMedia(change);
		const candidate = {
			...change,
			payload: normalizedPayload,
			payloadHash: payloadHash(normalizedPayload),
			media: normalizedMedia,
		};
		const existing = await findExisting(candidate, transaction);
		const authoritativeGeneration = existing ? BigInt(existing.lwwGeneration) : 0n;
		if (candidate.baseGeneration > authoritativeGeneration) {
			return {
				applied: false,
				outcome: await persistTerminal(
					outcome(candidate, 'rejected', 'future_base_version'),
					candidate.payloadHash,
				),
			};
		}
		if (
			existing?.deletedAt &&
			candidate.operation === 'upsert' &&
			candidate.generation <= authoritativeGeneration
		) {
			return {
				applied: false,
				outcome: await persistTerminal(
					outcome(
						candidate,
						'superseded',
						'delete_wins',
						serializeLwwRecord(candidate.collection, existing),
					),
					candidate.payloadHash,
				),
			};
		}
		if (existing) {
			const comparison = compareCandidate(candidate, existing);
			if (comparison === 0) {
				const result =
					existing.lwwPayloadHash === candidate.payloadHash
						? outcome(
								candidate,
								'already_applied',
								'already_applied',
								serializeLwwRecord(candidate.collection, existing),
							)
						: outcome(candidate, 'rejected', 'change_id_reused');
				return {
					applied: false,
					outcome: await persistTerminal(result, candidate.payloadHash),
				};
			}
			if (comparison < 0) {
				return {
					applied: false,
					outcome: await persistTerminal(
						outcome(
							candidate,
							'superseded',
							'version_superseded',
							serializeLwwRecord(candidate.collection, existing),
						),
						candidate.payloadHash,
					),
				};
			}
		}
		const record = await applyRecord(
			candidate,
			normalizedPayload,
			normalizedMedia,
			existing,
			franchiseeId,
			nextCursor,
			transaction,
			cleanupKeys,
		);
		const appliedOutcome = outcome(
			candidate,
			'applied',
			candidate.operation === 'delete' ? 'delete_applied' : 'upsert_applied',
			serializeLwwRecord(candidate.collection, record),
		);
		return {
			applied: true,
			outcome: await persistTerminal(appliedOutcome, candidate.payloadHash),
		};
	} catch (error) {
		if (error instanceof BusinessRejection) {
			return {
				applied: false,
				outcome: await persistTerminal(
					outcome(change, 'rejected', error.reasonCode),
					change.payloadHash,
				),
			};
		}
		if (error instanceof ValidationError) {
			return {
				applied: false,
				outcome: await persistTerminal(
					outcome(change, 'rejected', 'invalid_payload'),
					change.payloadHash,
				),
			};
		}
		throw error;
	}
};

const serializeWarranty = (record: Warranty) => ({
	remote_id: record.id,
	client_id: record.clientId,
	version: record.version,
	start_date: record.startDate.toISOString(),
	duration_years: record.durationYears,
	pdf_url: record.pdfUrl,
	warranty_card_number: record.warrantyCardNumber,
	row_cursor: record.syncCursor.toString(),
	server_timestamp: record.updatedAt.toISOString(),
	deleted_at: null,
});

const serializeProposal = (record: Proposal) => ({
	remote_id: record.id,
	client_id: record.clientId,
	pdf_url: record.pdfUrl,
	row_cursor: record.syncCursor.toString(),
	server_timestamp: record.updatedAt.toISOString(),
	deleted_at: record.deletedAt ? record.deletedAt.toISOString() : null,
});

const assertSnapshotBounds = (collections: Record<string, unknown[]>) => {
	for (const [collection, records] of Object.entries(collections)) {
		if (records.length > MAX_SYNC_RESPONSE_RECORDS) {
			throw new SyncEnvelopeError(
				'snapshot_too_large',
				`${collection} exceeds the bounded sync snapshot size.`,
				409,
			);
		}
	}
};

const snapshot = async (
	franchiseeId: string,
	requestCursor: bigint,
	responseCursor: bigint,
	transaction: Transaction,
) => {
	const range = {
		[Op.gt]: requestCursor.toString(),
		[Op.lte]: responseCursor.toString(),
	};
	const clients = await Client.findAll({
		where: { franchiseeId, syncCursor: range },
		paranoid: false,
		transaction,
		order: [
			['syncCursor', 'ASC'],
			['id', 'ASC'],
		],
		limit: MAX_SYNC_RESPONSE_RECORDS + 1,
	});
	const allClients = await Client.findAll({
		where: { franchiseeId },
		attributes: ['id'],
		paranoid: false,
		transaction,
	});
	const clientIds = allClients.map((client) => client.id);
	const items = clientIds.length
		? await Item.findAll({
				where: { clientId: { [Op.in]: clientIds }, syncCursor: range },
				paranoid: false,
				transaction,
				order: [
					['syncCursor', 'ASC'],
					['id', 'ASC'],
				],
				limit: MAX_SYNC_RESPONSE_RECORDS + 1,
			})
		: [];
	const allItems = clientIds.length
		? await Item.findAll({
				where: { clientId: { [Op.in]: clientIds } },
				attributes: ['id'],
				paranoid: false,
				transaction,
			})
		: [];
	const itemIds = allItems.map((item) => item.id);
	const rectangles = itemIds.length
		? await Rectangle.findAll({
				where: { itemId: { [Op.in]: itemIds }, syncCursor: range },
				paranoid: false,
				transaction,
				order: [
					['syncCursor', 'ASC'],
					['id', 'ASC'],
				],
				limit: MAX_SYNC_RESPONSE_RECORDS + 1,
			})
		: [];
	const defaultPrices = await DefaultPrice.findAll({
		where: { franchiseeId, syncCursor: range },
		paranoid: false,
		transaction,
		order: [
			['syncCursor', 'ASC'],
			['id', 'ASC'],
		],
		limit: MAX_SYNC_RESPONSE_RECORDS + 1,
	});
	const warranties = clientIds.length
		? await Warranty.findAll({
				where: { clientId: { [Op.in]: clientIds }, syncCursor: range },
				transaction,
				order: [
					['syncCursor', 'ASC'],
					['id', 'ASC'],
				],
				limit: MAX_SYNC_RESPONSE_RECORDS + 1,
			})
		: [];
	const proposals = clientIds.length
		? await Proposal.findAll({
				where: { clientId: { [Op.in]: clientIds }, syncCursor: range },
				paranoid: false,
				transaction,
				order: [
					['syncCursor', 'ASC'],
					['id', 'ASC'],
				],
				limit: MAX_SYNC_RESPONSE_RECORDS + 1,
			})
		: [];
	const result = {
		clients: clients.map((record) => serializeLwwRecord('clients', record)),
		items: items.map((record) => serializeLwwRecord('items', record)),
		rectangles: rectangles.map((record) => serializeLwwRecord('rectangles', record)),
		default_prices: defaultPrices.map((record) => serializeLwwRecord('default_prices', record)),
		warranties: warranties.map(serializeWarranty),
		proposals: proposals.map(serializeProposal),
	};
	assertSnapshotBounds(result);
	return result;
};

export const executeSyncV2 = async (
	envelope: ParsedEnvelope,
	franchiseeId: string,
	sequelize: any,
): Promise<SyncV2Response> => {
	const cleanupKeys: string[] = [];
	const response = await sequelize.transaction(
		{ isolationLevel: Transaction.ISOLATION_LEVELS.READ_COMMITTED },
		async (transaction: Transaction) => {
			const state = await lockTenantSyncState(franchiseeId, transaction);
			const receipt = await SyncV2Request.findOne({
				where: { franchiseeId, requestId: envelope.requestId },
				transaction,
				lock: transaction.LOCK.UPDATE,
			});
			if (receipt) {
				if (receipt.requestHash !== envelope.requestHash) {
					throw new SyncEnvelopeError(
						'request_id_reused',
						'request_id was already used for a different request.',
						409,
					);
				}
				return JSON.parse(receipt.responseJson) as SyncV2Response;
			}

			const currentCursor = BigInt(state.cursor);
			if (envelope.requestCursor > currentCursor) {
				throw new SyncEnvelopeError(
					'future_cursor',
					'request_cursor is ahead of the authoritative tenant cursor.',
					409,
				);
			}
			const warrantySequence = await WarrantyDeletionSequence.findByPk(1, {
				transaction,
			});
			const authoritativeWarrantyCursor = BigInt(warrantySequence?.lastValue ?? '0');
			if (envelope.warrantyTombstoneCursor > authoritativeWarrantyCursor) {
				throw new SyncEnvelopeError(
					'future_warranty_tombstone_cursor',
					'warranty_tombstone_cursor is ahead of the authoritative sequence.',
					409,
				);
			}
			await preflightTenant(envelope, franchiseeId, transaction);

			const hasCandidates = COLLECTIONS.some(
				(collection) => envelope.changes[collection].length > 0,
			);
			let nextCursor = currentCursor;
			if (hasCandidates) {
				try {
					nextCursor = nextTenantSyncCursor(state.cursor);
				} catch (error) {
					if (error instanceof TenantCursorExhaustedError) {
						throw new SyncEnvelopeError('cursor_exhausted', error.message, 409);
					}
					throw error;
				}
			}
			const outcomes: Record<Collection, Array<Record<string, unknown>>> = {
				clients: [],
				items: [],
				rectangles: [],
				default_prices: [],
			};
			let applied = false;
			for (const collection of COLLECTIONS) {
				for (const change of envelope.changes[collection]) {
					const result = await processChange(
						change,
						franchiseeId,
						nextCursor,
						transaction,
						cleanupKeys,
					);
					outcomes[collection].push(result.outcome);
					applied ||= result.applied;
				}
			}
			const responseCursor = applied ? nextCursor : currentCursor;
			if (applied) {
				await state.update({ cursor: responseCursor.toString() }, { transaction });
			}
			const updates = await snapshot(
				franchiseeId,
				envelope.requestCursor,
				responseCursor,
				transaction,
			);
			const warrantyTombstones = await warrantyTombstonesAfter(
				franchiseeId,
				envelope.warrantyTombstoneCursor.toString(),
				transaction,
			);
			const warrantyCursor = warrantyTombstones.length
				? warrantyTombstones.at(-1)!.deletionSequence.toString()
				: envelope.warrantyTombstoneCursor.toString();
			const result: SyncV2Response = {
				protocol_version: 2,
				request_id: envelope.requestId,
				response_cursor: responseCursor.toString(),
				warranty_tombstone_cursor: warrantyCursor,
				outcomes,
				warnings: envelope.warnings,
				updates: {
					...updates,
					warranty_tombstones: warrantyTombstones.map((tombstone) => ({
						warranty_id: tombstone.warrantyId,
						deletion_sequence: tombstone.deletionSequence.toString(),
						deleted_at: tombstone.deletedAt.toISOString(),
					})),
				},
			};
			await SyncV2Request.create(
				{
					franchiseeId,
					requestId: envelope.requestId,
					requestHash: envelope.requestHash,
					responseCursor: responseCursor.toString(),
					responseJson: JSON.stringify(result),
				},
				{ transaction },
			);
			return result;
		},
	);
	if (cleanupKeys.length) {
		void reconcileManagedFileCleanupByStorageKeys([...new Set(cleanupKeys)]).catch((error) =>
			console.error('Unable to reconcile APP-111 cleanup:', error),
		);
	}
	return response;
};

const legacyPayload = (collection: Collection, record: any) => {
	if (record.deletedAt) return {};
	switch (collection) {
		case 'clients':
			return serializeLwwRecord(collection, record).payload as JsonObject;
		case 'items':
			return serializeLwwRecord(collection, record).payload as JsonObject;
		case 'rectangles':
			return serializeLwwRecord(collection, record).payload as JsonObject;
		case 'default_prices':
			return serializeLwwRecord(collection, record).payload as JsonObject;
	}
};

export const stampLegacySyncChanges = async (
	franchiseeId: string,
	appliedIds: Partial<Record<SyncVisibleCollection, string[]>>,
	transaction: Transaction,
) => {
	const visibleCollections: SyncVisibleCollection[] = [...COLLECTIONS, 'warranties', 'proposals'];
	const hasChanges = visibleCollections.some((collection) => appliedIds[collection]?.length);
	if (!hasChanges) return;
	const state = await lockTenantSyncState(franchiseeId, transaction);
	let cursor: bigint;
	try {
		cursor = nextTenantSyncCursor(state.cursor);
	} catch (error) {
		if (error instanceof TenantCursorExhaustedError) {
			throw new SyncEnvelopeError('cursor_exhausted', error.message, 409);
		}
		throw error;
	}
	for (const collection of COLLECTIONS) {
		for (const id of [...new Set(appliedIds[collection] ?? [])]) {
			const record = await modelFor(collection).findByPk(id, {
				paranoid: false,
				transaction,
				lock: transaction.LOCK.UPDATE,
			});
			if (!record) continue;
			const tenant = await tenantForExisting(collection, record, transaction);
			if (tenant !== franchiseeId) {
				throw new SyncTenantAuthorizationError({
					clients: [],
					items: [],
					rectangles: [],
					default_prices: [],
				});
			}
			const generation = BigInt(record.lwwGeneration ?? '0');
			if (generation === MAX_SYNC_BIGINT) {
				throw new SyncEnvelopeError(
					'generation_exhausted',
					'Record generation exhausted.',
					409,
				);
			}
			const writerId = randomUUID();
			const changeId = randomUUID();
			const payload = legacyPayload(collection, record);
			await modelFor(collection).update(
				{
					lwwGeneration: (generation + 1n).toString(),
					lwwBranchSeq: 1,
					lwwOperationRank: record.deletedAt ? 1 : 0,
					lwwWriterId: writerId,
					lwwChangeId: changeId,
					lwwPayloadHash: payloadHash(payload),
					syncCursor: cursor.toString(),
				},
				{
					where: { id },
					paranoid: false,
					transaction,
				},
			);
		}
	}
	for (const collection of ['warranties', 'proposals'] as const) {
		const model = collection === 'warranties' ? Warranty : Proposal;
		for (const id of [...new Set(appliedIds[collection] ?? [])]) {
			const record = await model.findByPk(id, {
				paranoid: false,
				transaction,
				lock: transaction.LOCK.UPDATE,
			});
			if (!record) continue;
			const client = await Client.findByPk(record.clientId, {
				paranoid: false,
				transaction,
			});
			if (!client || client.franchiseeId !== franchiseeId) {
				throw new SyncTenantAuthorizationError({
					clients: [],
					items: [],
					rectangles: [],
					default_prices: [],
				});
			}
			await model.update(
				{ syncCursor: cursor.toString() },
				{
					where: { id },
					paranoid: false,
					transaction,
				},
			);
		}
	}
	await state.update({ cursor: cursor.toString() }, { transaction });
};
