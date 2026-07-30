import { randomUUID } from 'crypto';
import jwt from 'jsonwebtoken';
import request from 'supertest';
import app from '../app';
import {
	Client,
	DefaultPrice,
	Franchisee,
	Item,
	Rectangle,
	SyncV2ChangeReceipt,
	TenantSyncState,
	User,
} from '../models';
import { payloadHash } from '../services/lwwSync';
import { irreversibleWarrantyConfirmation } from '../services/warrantyLifecycle';

const JWT_SECRET = process.env.JWT_SECRET!;
const writerA = '10000000-0000-4000-8000-000000000001';
const writerB = '10000000-0000-4000-8000-000000000002';

type Collection = 'clients' | 'items' | 'rectangles' | 'default_prices';

const payloads: Record<Collection, Record<string, unknown>> = {
	clients: {
		name: 'Client',
		address: null,
		site_address: null,
		email: null,
		phone: null,
		latitude: null,
		longitude: null,
		discounted_price: null,
	},
	items: { name: 'Item', price: 10, enabled: true },
	rectangles: { length: 10, width: 20 },
	default_prices: { price: 12, enabled: true },
};

describe('APP-111 sync protocol v2', () => {
	const tenantA = '20000000-0000-4000-8000-000000000001';
	const tenantB = '20000000-0000-4000-8000-000000000002';
	const userA = '20000000-0000-4000-8000-000000000003';
	const userB = '20000000-0000-4000-8000-000000000004';
	const parentClientA = '20000000-0000-4000-8000-000000000005';
	const parentClientB = '20000000-0000-4000-8000-000000000006';
	const parentItemA = '20000000-0000-4000-8000-000000000007';
	const parentItemB = '20000000-0000-4000-8000-000000000008';
	let tokenA: string;
	let tokenB: string;

	beforeAll(async () => {
		await Franchisee.bulkCreate([
			{ id: tenantA, name: 'APP-111 A' },
			{ id: tenantB, name: 'APP-111 B' },
		]);
		await User.bulkCreate([
			{
				id: userA,
				name: 'A',
				email: 'app111-a@example.com',
				password: 'password',
				franchiseeId: tenantA,
			},
			{
				id: userB,
				name: 'B',
				email: 'app111-b@example.com',
				password: 'password',
				franchiseeId: tenantB,
			},
		]);
		await Client.bulkCreate([
			{
				id: parentClientA,
				franchiseeId: tenantA,
				name: 'Parent A',
			},
			{
				id: parentClientB,
				franchiseeId: tenantB,
				name: 'Parent B',
			},
		]);
		await Item.bulkCreate([
			{
				id: parentItemA,
				clientId: parentClientA,
				name: 'Parent item A',
				price: 1,
			},
			{
				id: parentItemB,
				clientId: parentClientB,
				name: 'Parent item B',
				price: 1,
			},
		]);
		tokenA = jwt.sign({ id: userA, franchiseeId: tenantA }, JWT_SECRET);
		tokenB = jwt.sign({ id: userB, franchiseeId: tenantB }, JWT_SECRET);
	});

	const parentFor = (collection: Collection, tenant = 'a') => {
		if (collection === 'items') {
			return tenant === 'a' ? parentClientA : parentClientB;
		}
		if (collection === 'rectangles') {
			return tenant === 'a' ? parentItemA : parentItemB;
		}
		return undefined;
	};

	const change = ({
		collection,
		remoteId,
		operation = 'upsert',
		base = '0',
		generation = '1',
		branch = 1,
		writerId = writerA,
		changeId = randomUUID(),
		payload = operation === 'delete' ? {} : payloads[collection],
		parentId = parentFor(collection),
		media,
		deviceTimestamp,
	}: {
		collection: Collection;
		remoteId: string;
		operation?: 'upsert' | 'delete';
		base?: string;
		generation?: string;
		branch?: number;
		writerId?: string;
		changeId?: string;
		payload?: Record<string, unknown>;
		parentId?: string;
		media?: Record<string, unknown>;
		deviceTimestamp?: unknown;
	}) => ({
		remote_id: remoteId,
		operation,
		base_generation: base,
		generation,
		branch_seq: branch,
		writer_id: writerId,
		change_id: changeId,
		...(parentId ? { parent_id: parentId } : {}),
		payload,
		...(media !== undefined ? { media } : {}),
		...(deviceTimestamp !== undefined ? { device_timestamp: deviceTimestamp } : {}),
	});

	const envelope = (
		entries: Partial<Record<Collection, Array<Record<string, unknown>>>>,
		cursor = '0',
		requestId: string = randomUUID(),
	) => ({
		protocol_version: 2,
		request_id: requestId,
		request_cursor: cursor,
		warranty_tombstone_cursor: '0',
		changes: {
			clients: entries.clients ?? [],
			items: entries.items ?? [],
			rectangles: entries.rectangles ?? [],
			default_prices: entries.default_prices ?? [],
		},
	});

	const send = (
		entries: Partial<Record<Collection, Array<Record<string, unknown>>>>,
		cursor = '0',
		requestId?: string,
		token = tokenA,
	) =>
		request(app)
			.post('/api/sync/v2')
			.set('Authorization', `Bearer ${token}`)
			.send(envelope(entries, cursor, requestId));

	const modelRecord = async (collection: Collection, id: string) => {
		const model = {
			clients: Client,
			items: Item,
			rectangles: Rectangle,
			default_prices: DefaultPrice,
		}[collection] as any;
		return model.findByPk(id, { paranoid: false });
	};

	for (const collection of ['clients', 'items', 'rectangles', 'default_prices'] as const) {
		it(`${collection}: deterministically resolves opposite arrival order, delete ties, restore, retry, and older changes`, async () => {
			const firstId = randomUUID();
			const secondId = randomUUID();
			const upsertIdA = randomUUID();
			const deleteIdA = randomUUID();
			const upsertIdB = randomUUID();
			const deleteIdB = randomUUID();

			expect(
				(
					await send({
						[collection]: [
							change({
								collection,
								remoteId: firstId,
								changeId: upsertIdA,
							}),
						],
					})
				).body.outcomes[collection][0].status,
			).toBe('applied');
			expect(
				(
					await send({
						[collection]: [
							change({
								collection,
								remoteId: firstId,
								operation: 'delete',
								writerId: writerB,
								changeId: deleteIdA,
							}),
						],
					})
				).body.outcomes[collection][0].status,
			).toBe('applied');

			expect(
				(
					await send({
						[collection]: [
							change({
								collection,
								remoteId: secondId,
								operation: 'delete',
								writerId: writerA,
								changeId: deleteIdB,
							}),
						],
					})
				).body.outcomes[collection][0].status,
			).toBe('applied');
			expect(
				(
					await send({
						[collection]: [
							change({
								collection,
								remoteId: secondId,
								writerId: writerB,
								changeId: upsertIdB,
							}),
						],
					})
				).body.outcomes[collection][0],
			).toMatchObject({ status: 'superseded', reason_code: 'delete_wins' });

			expect((await modelRecord(collection, firstId)).deletedAt).not.toBeNull();
			expect((await modelRecord(collection, secondId)).deletedAt).not.toBeNull();

			const restoreId = randomUUID();
			const restore = change({
				collection,
				remoteId: firstId,
				base: '1',
				generation: '2',
				changeId: restoreId,
				payload: {
					...payloads[collection],
					...(collection === 'clients' ? { name: 'Restored' } : {}),
				},
			});
			expect(
				(await send({ [collection]: [restore] })).body.outcomes[collection][0].status,
			).toBe('applied');
			expect((await modelRecord(collection, firstId)).deletedAt).toBeNull();

			expect(
				(await send({ [collection]: [restore] })).body.outcomes[collection][0].status,
			).toBe('applied');
			const reused = {
				...restore,
				payload: {
					...restore.payload,
					...(collection === 'clients'
						? { name: 'Different' }
						: collection === 'items'
							? { name: 'Different' }
							: { enabled: false }),
				},
			};
			expect(
				(await send({ [collection]: [reused] })).body.outcomes[collection][0],
			).toMatchObject({ status: 'rejected', reason_code: 'change_id_reused' });

			expect(
				(
					await send({
						[collection]: [
							change({
								collection,
								remoteId: firstId,
								operation: 'delete',
								changeId: randomUUID(),
							}),
						],
					})
				).body.outcomes[collection][0].status,
			).toBe('superseded');
		});
	}

	it('rejects future logical bases and discards invalid/far-future clocks with warnings', async () => {
		const remoteId = randomUUID();
		const future = await send({
			clients: [
				change({
					collection: 'clients',
					remoteId,
					base: '2',
					generation: '3',
					deviceTimestamp: '2999-01-01T00:00:00.000Z',
				}),
			],
		});
		expect(future.status).toBe(200);
		expect(future.body.outcomes.clients[0]).toMatchObject({
			status: 'rejected',
			reason_code: 'future_base_version',
		});
		expect(future.body.warnings[0]).toMatchObject({
			code: 'device_timestamp_discarded',
			reason: 'future',
		});

		const invalid = await send({
			clients: [
				change({
					collection: 'clients',
					remoteId,
					deviceTimestamp: 'not-a-date',
				}),
			],
		});
		expect(invalid.body.outcomes.clients[0].status).toBe('applied');
		expect(invalid.body.warnings[0].reason).toBe('invalid');

		const sameChangeId = randomUUID();
		const diagnosticRetry = change({
			collection: 'clients',
			remoteId: randomUUID(),
			changeId: sameChangeId,
			deviceTimestamp: 'not-a-date',
		});
		const first = await send({ clients: [diagnosticRetry] });
		const retry = await send({
			clients: [
				{
					...diagnosticRetry,
					device_timestamp: new Date(Date.now() + 4 * 60 * 1000).toISOString(),
				},
			],
		});
		expect(first.body.outcomes.clients[0].status).toBe('applied');
		expect(retry.body.outcomes.clients[0]).toEqual(first.body.outcomes.clients[0]);
		expect(retry.body.warnings).toEqual([]);
	});

	it('returns deterministic invalid_payload outcomes for PostgreSQL-aligned bounds', async () => {
		const invalidCases: Array<{
			collection: Collection;
			payload: Record<string, unknown>;
			media?: Record<string, unknown>;
		}> = [
			{
				collection: 'clients',
				payload: { ...payloads.clients, name: 'x'.repeat(256) },
			},
			{
				collection: 'clients',
				payload: { ...payloads.clients, address: 'x'.repeat(256) },
			},
			{
				collection: 'clients',
				payload: { ...payloads.clients, site_address: 'x'.repeat(256) },
			},
			{
				collection: 'clients',
				payload: { ...payloads.clients, phone: 'x'.repeat(256) },
			},
			{
				collection: 'clients',
				payload: { ...payloads.clients, email: 'invalid-email' },
			},
			{
				collection: 'clients',
				payload: { ...payloads.clients, latitude: 90.0001 },
			},
			{
				collection: 'clients',
				payload: { ...payloads.clients, longitude: -180.0001 },
			},
			{
				collection: 'clients',
				payload: { ...payloads.clients, discounted_price: 1.001 },
			},
			{
				collection: 'clients',
				payload: {
					...payloads.clients,
					discounted_price: 99_999_999.99,
				},
			},
			{
				collection: 'items',
				payload: { ...payloads.items, name: 'x'.repeat(256) },
			},
			{
				collection: 'items',
				payload: { ...payloads.items, price: 100000000 },
			},
			{
				collection: 'items',
				payload: { ...payloads.items, price: 1.001 },
			},
			{
				collection: 'rectangles',
				payload: { length: 0, width: 1 },
			},
			{
				collection: 'rectangles',
				payload: { length: 1, width: 10000.0001 },
			},
			{
				collection: 'rectangles',
				payload: payloads.rectangles,
				media: { image_data: 'data:image/png;base64,not-valid***' },
			},
			{
				collection: 'default_prices',
				payload: { ...payloads.default_prices, price: 100000000 },
			},
			{
				collection: 'default_prices',
				payload: { ...payloads.default_prices, price: 1.001 },
			},
		];
		for (const invalidCase of invalidCases) {
			const remoteId = randomUUID();
			const response = await send({
				[invalidCase.collection]: [
					change({
						collection: invalidCase.collection,
						remoteId,
						payload: invalidCase.payload,
						media: invalidCase.media,
					}),
				],
			});
			expect(response.status).toBe(200);
			expect(response.body.outcomes[invalidCase.collection][0]).toMatchObject({
				status: 'rejected',
				reason_code: 'invalid_payload',
			});
			expect(await modelRecord(invalidCase.collection, remoteId)).toBeNull();
		}
	});

	it('canonicalizes nullable email and storage-backed numeric representations before commit', async () => {
		const clientId = randomUUID();
		const rectangleId = randomUUID();
		const rawClientPayload = {
			...payloads.clients,
			address: '',
			site_address: '',
			email: '',
			phone: '',
			latitude: 11.123456789,
			longitude: -0,
			discounted_price: 44.44,
		};
		const rawRectanglePayload = {
			length: 11.123456789,
			width: 0.0000001,
		};
		const response = await send({
			clients: [
				change({
					collection: 'clients',
					remoteId: clientId,
					payload: rawClientPayload,
				}),
			],
			rectangles: [
				change({
					collection: 'rectangles',
					remoteId: rectangleId,
					payload: rawRectanglePayload,
				}),
			],
		});
		expect(response.status).toBe(200);
		const expectedClientPayload = {
			...rawClientPayload,
			email: null,
			latitude: Math.fround(rawClientPayload.latitude),
			longitude: 0,
		};
		const expectedRectanglePayload = {
			length: Math.fround(rawRectanglePayload.length),
			width: Math.fround(rawRectanglePayload.width),
		};
		const clientAuthoritative = response.body.outcomes.clients[0].authoritative;
		const rectangleAuthoritative = response.body.outcomes.rectangles[0].authoritative;
		expect(clientAuthoritative.payload).toEqual(expectedClientPayload);
		expect(clientAuthoritative.payload_hash).toBe(payloadHash(expectedClientPayload));
		expect(rectangleAuthoritative.payload).toEqual(expectedRectanglePayload);
		expect(rectangleAuthoritative.payload_hash).toBe(payloadHash(expectedRectanglePayload));
		expect(await modelRecord('clients', clientId)).toMatchObject({
			email: null,
			lwwPayloadHash: clientAuthoritative.payload_hash,
		});
		expect(await modelRecord('rectangles', rectangleId)).toMatchObject({
			lwwPayloadHash: rectangleAuthoritative.payload_hash,
		});

		const nullEmail = await send({
			clients: [
				change({
					collection: 'clients',
					remoteId: randomUUID(),
					payload: { ...rawClientPayload, email: null },
				}),
			],
		});
		expect(nullEmail.body.outcomes.clients[0].authoritative.payload_hash).toBe(
			clientAuthoritative.payload_hash,
		);
	});

	it('durably replays rejected and superseded change outcomes by full fingerprint', async () => {
		const rejectedId = randomUUID();
		const rejectedChangeId = randomUUID();
		const rejectedChange = change({
			collection: 'clients',
			remoteId: rejectedId,
			changeId: rejectedChangeId,
			payload: { ...payloads.clients, email: 'bad' },
		});
		const rejected = await send({ clients: [rejectedChange] });
		expect(rejected.body.outcomes.clients[0]).toMatchObject({
			status: 'rejected',
			reason_code: 'invalid_payload',
		});
		expect(
			await SyncV2ChangeReceipt.findOne({
				where: { franchiseeId: tenantA, changeId: rejectedChangeId },
			}),
		).toMatchObject({
			changeHash: expect.stringMatching(/^[0-9a-f]{64}$/),
			outcomeJson: expect.stringContaining('"status":"rejected"'),
		});
		expect((await send({ clients: [rejectedChange] })).body.outcomes.clients[0]).toEqual(
			rejected.body.outcomes.clients[0],
		);
		expect(
			(
				await send({
					clients: [
						{
							...rejectedChange,
							payload: { ...payloads.clients, name: 'Changed reuse' },
						},
					],
				})
			).body.outcomes.clients[0],
		).toMatchObject({ status: 'rejected', reason_code: 'change_id_reused' });

		const remoteId = randomUUID();
		await send({
			clients: [
				change({
					collection: 'clients',
					remoteId,
					writerId: writerB,
				}),
			],
		});
		const loser = change({
			collection: 'clients',
			remoteId,
			writerId: writerA,
			changeId: randomUUID(),
		});
		const superseded = await send({ clients: [loser] });
		expect(superseded.body.outcomes.clients[0].status).toBe('superseded');
		await send({
			clients: [
				change({
					collection: 'clients',
					remoteId,
					base: '1',
					generation: '2',
				}),
			],
		});
		expect((await send({ clients: [loser] })).body.outcomes.clients[0]).toEqual(
			superseded.body.outcomes.clients[0],
		);
	});

	it('rejects a future warranty tombstone cursor before any mutation', async () => {
		const remoteId = randomUUID();
		const body = envelope({
			clients: [change({ collection: 'clients', remoteId })],
		});
		body.warranty_tombstone_cursor = '9223372036854775807';
		const response = await request(app)
			.post('/api/sync/v2')
			.set('Authorization', `Bearer ${tokenA}`)
			.send(body);
		expect(response.status).toBe(409);
		expect(response.body.error.code).toBe('future_warranty_tombstone_cursor');
		expect(await Client.findByPk(remoteId)).toBeNull();
	});

	it('rejects a future v1 warranty tombstone cursor before any mutation', async () => {
		const remoteId = randomUUID();
		const response = await request(app)
			.post('/api/sync')
			.set('Authorization', `Bearer ${tokenA}`)
			.send({
				last_sync_time: null,
				warranty_tombstone_cursor: '1',
				changes: {
					clients: [{ remote_id: remoteId, name: 'Must not write' }],
				},
			});
		expect(response.status).toBe(409);
		expect(response.body.code).toBe('future_warranty_tombstone_cursor');
		expect(await Client.findByPk(remoteId)).toBeNull();
	});

	it('rolls back the whole request for hostile record IDs and parents without disclosure', async () => {
		const hostileIds: Record<Collection, string> = {
			clients: randomUUID(),
			items: randomUUID(),
			rectangles: randomUUID(),
			default_prices: randomUUID(),
		};
		await Client.create({
			id: hostileIds.clients,
			franchiseeId: tenantB,
			name: 'foreign',
		});
		await Item.create({
			id: hostileIds.items,
			clientId: parentClientB,
			name: 'foreign',
			price: 1,
		});
		await Rectangle.create({
			id: hostileIds.rectangles,
			itemId: parentItemB,
			length: 1,
			width: 1,
		});
		await DefaultPrice.create({
			id: hostileIds.default_prices,
			franchiseeId: tenantB,
			price: 1,
			enabled: true,
		});

		for (const collection of Object.keys(hostileIds) as Collection[]) {
			const localId = randomUUID();
			const hostileBatch: Partial<Record<Collection, Array<Record<string, unknown>>>> = {
				clients: [
					change({
						collection: 'clients',
						remoteId: localId,
					}),
				],
			};
			(hostileBatch[collection] ??= []).push(
				change({
					collection,
					remoteId: hostileIds[collection],
					parentId: parentFor(collection, 'b'),
				}),
			);
			const response = await send(hostileBatch);
			expect(response.status).toBe(403);
			expect(response.body.error).toEqual({
				code: 'unauthorized',
				message: 'The sync request is not authorized.',
			});
			expect(await Client.findByPk(localId)).toBeNull();
		}

		const hostileParent = await send({
			items: [
				change({
					collection: 'items',
					remoteId: randomUUID(),
					parentId: parentClientB,
				}),
			],
		});
		expect(hostileParent.status).toBe(403);
	});

	it('enforces immutable parents, active parents, and server-field exclusion', async () => {
		const itemId = randomUUID();
		expect(
			(
				await send({
					items: [change({ collection: 'items', remoteId: itemId })],
				})
			).body.outcomes.items[0].status,
		).toBe('applied');

		const otherParent = randomUUID();
		await Client.create({ id: otherParent, franchiseeId: tenantA, name: 'Other' });
		const immutable = await send({
			items: [
				change({
					collection: 'items',
					remoteId: itemId,
					base: '1',
					generation: '2',
					parentId: otherParent,
				}),
			],
		});
		expect(immutable.body.outcomes.items[0]).toMatchObject({
			status: 'rejected',
			reason_code: 'immutable_parent',
		});

		await Client.destroy({ where: { id: otherParent } });
		const deletedParent = await send({
			items: [
				change({
					collection: 'items',
					remoteId: randomUUID(),
					parentId: otherParent,
				}),
			],
		});
		expect(deletedParent.body.outcomes.items[0]).toMatchObject({
			status: 'rejected',
			reason_code: 'parent_unavailable',
		});

		const restoredChildId = randomUUID();
		const restoreThenChild = await send({
			clients: [
				change({
					collection: 'clients',
					remoteId: otherParent,
					base: '1',
					generation: '2',
				}),
			],
			items: [
				change({
					collection: 'items',
					remoteId: restoredChildId,
					parentId: otherParent,
				}),
			],
		});
		expect(restoreThenChild.body.outcomes.clients[0].status).toBe('applied');
		expect(restoreThenChild.body.outcomes.items[0].status).toBe('applied');

		const forbiddenFields: Array<[Collection, Record<string, unknown>]> = [
			['clients', { ...payloads.clients, photos: ['/foreign.jpg'] }],
			['items', { ...payloads.items, client_id: parentClientA }],
			['rectangles', { ...payloads.rectangles, image_data: 'forged' }],
			['default_prices', { ...payloads.default_prices, franchisee_id: tenantB }],
		];
		for (const [collection, payload] of forbiddenFields) {
			const forbidden = await send({
				[collection]: [
					change({
						collection,
						remoteId: randomUUID(),
						payload,
					}),
				],
			});
			expect(forbidden.body.outcomes[collection][0]).toMatchObject({
				status: 'rejected',
				reason_code: 'server_field_forbidden',
			});
		}
	});

	it('orders tenant commits with monotonic decimal-string cursors', async () => {
		await TenantSyncState.update({ cursor: '100' }, { where: { franchiseeId: tenantA } });
		const first = await send(
			{
				clients: [change({ collection: 'clients', remoteId: randomUUID() })],
			},
			'100',
		);
		const second = await send(
			{
				default_prices: [change({ collection: 'default_prices', remoteId: randomUUID() })],
			},
			first.body.response_cursor,
		);
		const responses = [first, second];
		expect(responses.map((response) => response.status)).toEqual([200, 200]);
		const cursors = responses
			.map((response) => BigInt(response.body.response_cursor))
			.sort((left, right) => (left < right ? -1 : 1));
		expect(cursors).toEqual([101n, 102n]);
	});

	it('replays identical request IDs, rejects changed request IDs, and cuts v1 off before mutation', async () => {
		const requestId = randomUUID();
		const remoteId = randomUUID();
		const entry = change({ collection: 'clients', remoteId });
		const first = await send({ clients: [entry] }, '0', requestId);
		const retry = await send({ clients: [entry] }, '0', requestId);
		expect(retry.body).toEqual(first.body);
		const changed = await send(
			{
				clients: [
					{
						...entry,
						payload: { ...entry.payload, name: 'Changed request' },
					},
				],
			},
			'0',
			requestId,
		);
		expect(changed.status).toBe(409);
		expect(changed.body.error.code).toBe('request_id_reused');

		const oldMinimum = process.env.SYNC_MIN_PROTOCOL_VERSION;
		process.env.SYNC_MIN_PROTOCOL_VERSION = '2';
		const v1Id = randomUUID();
		const v1 = await request(app)
			.post('/api/sync')
			.set('Authorization', `Bearer ${tokenA}`)
			.send({
				last_sync_time: null,
				changes: { clients: [{ remote_id: v1Id, name: 'Must not write' }] },
			});
		if (oldMinimum === undefined) delete process.env.SYNC_MIN_PROTOCOL_VERSION;
		else process.env.SYNC_MIN_PROTOCOL_VERSION = oldMinimum;
		expect(v1.status).toBe(426);
		expect(await Client.findByPk(v1Id)).toBeNull();
	});

	it('propagates photo/image media plus live, replacement, and deleted PDF resources by cursor', async () => {
		const clientId = randomUUID();
		const itemId = randomUUID();
		const rectangleId = randomUUID();
		const imageData = 'data:image/png;base64,iVBORw0KGgo=';
		const core = await send({
			clients: [
				change({
					collection: 'clients',
					remoteId: clientId,
					payload: { ...payloads.clients, name: 'Media client' },
				}),
			],
			items: [
				change({
					collection: 'items',
					remoteId: itemId,
					parentId: clientId,
				}),
			],
			rectangles: [
				change({
					collection: 'rectangles',
					remoteId: rectangleId,
					parentId: itemId,
					media: { image_data: imageData },
				}),
			],
		});
		expect(core.status).toBe(200);
		const coreCursor = core.body.response_cursor as string;

		const photo = await request(app)
			.post(`/api/photos/client/${clientId}`)
			.set('Authorization', `Bearer ${tokenA}`)
			.attach('file', Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00]), {
				filename: 'camera.jpg',
				contentType: 'image/jpeg',
			});
		expect(photo.status).toBe(201);
		expect(BigInt(photo.body.response_cursor)).toBeGreaterThan(BigInt(coreCursor));

		const samplePdf = Buffer.from('%PDF-1.4\nAPP-111\n%%EOF');
		const warranty = await request(app)
			.post('/api/warranty/upload')
			.set('Authorization', `Bearer ${tokenA}`)
			.field('client_id', clientId)
			.field('start_date', '2026-07-30T00:00:00.000Z')
			.field('duration_years', '5')
			.field('warranty_card_number', 'APP-111-W1')
			.attach('file', samplePdf, {
				filename: 'warranty.pdf',
				contentType: 'application/pdf',
			});
		expect(warranty.status).toBe(201);
		const proposal = await request(app)
			.post('/api/proposal/upload')
			.set('Authorization', `Bearer ${tokenA}`)
			.field('client_id', clientId)
			.attach('file', samplePdf, {
				filename: 'proposal.pdf',
				contentType: 'application/pdf',
			});
		expect(proposal.status).toBe(201);

		const fresh = await send({}, '0');
		const freshClient = fresh.body.updates.clients.find(
			(record: any) => record.remote_id === clientId,
		);
		expect(freshClient.media.photos).toEqual([photo.body.url]);
		expect(
			fresh.body.updates.rectangles.find((record: any) => record.remote_id === rectangleId)
				.media.image_data,
		).toBe(imageData);
		expect(
			fresh.body.updates.warranties.find(
				(record: any) => record.remote_id === warranty.body.id,
			),
		).toMatchObject({
			client_id: clientId,
			pdf_url: `/api/warranty/${warranty.body.id}/download`,
		});
		expect(
			fresh.body.updates.proposals.find(
				(record: any) => record.remote_id === proposal.body.id,
			),
		).toMatchObject({
			client_id: clientId,
			pdf_url: `/api/proposal/${proposal.body.id}/download`,
		});

		const secondDevice = await send({}, coreCursor);
		expect(
			secondDevice.body.updates.clients.find((record: any) => record.remote_id === clientId)
				.media.photos,
		).toEqual([photo.body.url]);
		expect(
			secondDevice.body.updates.warranties.some(
				(record: any) => record.remote_id === warranty.body.id,
			),
		).toBe(true);
		expect(
			secondDevice.body.updates.proposals.some(
				(record: any) => record.remote_id === proposal.body.id,
			),
		).toBe(true);

		const beforeReplacementCursor = secondDevice.body.response_cursor as string;
		const replacementId = randomUUID();
		const replacement = await request(app)
			.post('/api/warranty/upload')
			.set('Authorization', `Bearer ${tokenA}`)
			.set('Idempotency-Key', 'app-111-replacement-proof')
			.field('client_id', clientId)
			.field('start_date', '2026-08-01T00:00:00.000Z')
			.field('duration_years', '7')
			.field('warranty_card_number', 'APP-111-W2')
			.field('replacement_warranty_id', replacementId)
			.field('confirmed_warranty_id', warranty.body.id)
			.field('confirmed_warranty_card_number', warranty.body.warrantyCardNumber)
			.field('confirmed_warranty_version', warranty.body.version.toString())
			.field(
				'irreversible_confirmation',
				irreversibleWarrantyConfirmation(warranty.body.warrantyCardNumber),
			)
			.attach('file', samplePdf, {
				filename: 'replacement.pdf',
				contentType: 'application/pdf',
			});
		expect(replacement.status).toBe(201);
		expect(replacement.body.id).toBe(replacementId);
		expect(
			(
				await request(app)
					.delete(`/api/proposal/${proposal.body.id}`)
					.set('Authorization', `Bearer ${tokenA}`)
			).status,
		).toBe(204);

		const replacementPull = await send({}, beforeReplacementCursor);
		expect(replacementPull.body.updates.warranty_tombstones).toEqual([
			expect.objectContaining({ warranty_id: warranty.body.id }),
		]);
		expect(
			replacementPull.body.updates.warranties.find(
				(record: any) => record.remote_id === replacementId,
			),
		).toMatchObject({
			client_id: clientId,
			warranty_card_number: 'APP-111-W2',
		});
		expect(
			replacementPull.body.updates.proposals.find(
				(record: any) => record.remote_id === proposal.body.id,
			).deleted_at,
		).not.toBeNull();
	});

	it('isolates tenant snapshots and rejects malformed protocol values before mutation', async () => {
		const foreignId = randomUUID();
		await Client.create({ id: foreignId, franchiseeId: tenantB, name: 'Foreign' });
		const bootstrap = await send({}, '0');
		expect(
			bootstrap.body.updates.clients.some(
				(record: Record<string, unknown>) => record.remote_id === foreignId,
			),
		).toBe(false);

		const malformed = envelope({
			clients: [
				change({
					collection: 'clients',
					remoteId: randomUUID(),
					base: '9007199254740992',
					generation: '9007199254740993',
				}),
			],
		});
		malformed.request_cursor = '9223372036854775808';
		const response = await request(app)
			.post('/api/sync/v2')
			.set('Authorization', `Bearer ${tokenB}`)
			.send(malformed);
		expect(response.status).toBe(400);
		expect(response.body.error.code).toBe('invalid_integer');
	});
});
