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
	TenantSyncState,
	User,
} from '../models';

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

	for (const collection of [
		'clients',
		'items',
		'rectangles',
		'default_prices',
	] as const) {
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
				(await send({ [collection]: [restore] })).body.outcomes[collection][0]
					.status,
			).toBe('applied');
			expect((await modelRecord(collection, firstId)).deletedAt).toBeNull();

			expect(
				(await send({ [collection]: [restore] })).body.outcomes[collection][0]
					.status,
			).toBe('already_applied');
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
			const hostileBatch: Partial<
				Record<Collection, Array<Record<string, unknown>>>
			> = {
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

		const forbiddenFields: Array<
			[Collection, Record<string, unknown>]
		> = [
			['clients', { ...payloads.clients, photos: ['/foreign.jpg'] }],
			['items', { ...payloads.items, client_id: parentClientA }],
			['rectangles', { ...payloads.rectangles, image_data: 'forged' }],
			[
				'default_prices',
				{ ...payloads.default_prices, franchisee_id: tenantB },
			],
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
		await TenantSyncState.update(
			{ cursor: '100' },
			{ where: { franchiseeId: tenantA } },
		);
		const first = await send(
			{
				clients: [
					change({ collection: 'clients', remoteId: randomUUID() }),
				],
			},
			'100',
		);
		const second = await send(
			{
				default_prices: [
					change({ collection: 'default_prices', remoteId: randomUUID() }),
				],
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
