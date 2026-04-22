import request from 'supertest';
import app from '../app';
import { User, Franchisee, Client, Item, Rectangle } from '../models';
import jwt from 'jsonwebtoken';

const JWT_SECRET = process.env.JWT_SECRET || 'your_jwt_secret';

describe('syncController', () => {
	let franchisee1: any, franchisee2: any;
	let user1: any, user2: any;
	let token1: string, token2: string;

	beforeAll(async () => {
		// Setup Franchisees
		franchisee1 = await Franchisee.create({
			id: 'f1-id',
			name: 'Franchisee 1',
			default_prices: {},
		});
		franchisee2 = await Franchisee.create({
			id: 'f2-id',
			name: 'Franchisee 2',
			default_prices: {},
		});

		// Setup Users
		user1 = await User.create({
			id: 'u1-id',
			name: 'User 1',
			email: 'user1@example.com',
			password: 'password',
			franchiseeId: franchisee1.id,
		});
		user2 = await User.create({
			id: 'u2-id',
			name: 'User 2',
			email: 'user2@example.com',
			password: 'password',
			franchiseeId: franchisee2.id,
		});

		// Generate tokens
		token1 = jwt.sign({ id: user1.id, franchiseeId: franchisee1.id }, JWT_SECRET);
		token2 = jwt.sign({ id: user2.id, franchiseeId: franchisee2.id }, JWT_SECRET);
	});

	describe('POST /api/sync', () => {
		it('uploads new data and returns it for the same franchisee', async () => {
			const syncData = {
				last_sync_time: null,
				changes: {
					clients: [
						{
							remote_id: 'c1-id',
							name: 'Client 1',
							address: 'Address 1',
							siteAddress: 'Site 1',
							is_dirty: true,
							updated_at: new Date().toISOString(),
						},
					],
				},
			};

			const response = await request(app)
				.post('/api/sync')
				.set('Authorization', `Bearer ${token1}`)
				.send(syncData);

			expect(response.status).toBe(200);
			expect(response.body.updates.clients).toHaveLength(1);
			expect(response.body.updates.clients[0].remote_id).toBe('c1-id');

			// Verify DB
			const client = await Client.findOne({ where: { id: 'c1-id' } });
			expect(client).toBeDefined();
			expect(client?.franchiseeId).toBe(franchisee1.id);
			expect((client as any).siteAddress).toBe('Site 1');
		});

		it('isolates data by franchisee', async () => {
			const response = await request(app)
				.post('/api/sync')
				.set('Authorization', `Bearer ${token2}`)
				.send({ last_sync_time: null, changes: null });

			expect(response.status).toBe(200);
			// User 2 should NOT see Client 1 from Franchisee 1
			expect(response.body.updates.clients).toHaveLength(0);
		});

		it('processes items and rectangles', async () => {
			const syncData = {
				last_sync_time: null,
				changes: {
					items: [
						{
							remote_id: 'i1-id',
							client_id: 'c1-id',
							name: 'Roof',
							price: 10,
							enabled: true,
							updated_at: new Date().toISOString(),
						},
					],
					rectangles: [
						{
							remote_id: 'r1-id',
							item_id: 'i1-id',
							length: 10,
							width: 20,
							image_data: 'data:image/png;base64,ZmFrZQ==',
							updated_at: new Date().toISOString(),
						},
					],
				},
			};

			const response = await request(app)
				.post('/api/sync')
				.set('Authorization', `Bearer ${token1}`)
				.send(syncData);

			expect(response.status).toBe(200);

			const item = await Item.findOne({ where: { id: 'i1-id' } });
			expect(item).toBeDefined();
			expect(item?.clientId).toBe('c1-id');

			const rect = await Rectangle.findOne({ where: { id: 'r1-id' } });
			expect(rect).toBeDefined();
			expect(rect?.itemId).toBe('i1-id');
			expect(rect?.imageData).toBe('data:image/png;base64,ZmFrZQ==');
			expect(response.body.updates.rectangles[0].image_data).toBe(
				'data:image/png;base64,ZmFrZQ==',
			);
		});

		it('returns updates after last_sync_time', async () => {
			const lastSync = new Date().toISOString();

			// Wait a bit to ensure updatedAt is later
			await new Promise((resolve) => setTimeout(resolve, 1000));

			await Client.update({ name: 'Updated Client 1' }, { where: { id: 'c1-id' } });

			const response = await request(app)
				.post('/api/sync')
				.set('Authorization', `Bearer ${token1}`)
				.send({ last_sync_time: lastSync, changes: null });

			expect(response.status).toBe(200);
			expect(response.body.updates.clients).toHaveLength(1);
			expect(response.body.updates.clients[0].name).toBe('Updated Client 1');
		});
	});
});
