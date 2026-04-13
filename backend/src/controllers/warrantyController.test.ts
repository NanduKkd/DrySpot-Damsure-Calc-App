import path from 'path';
import request from 'supertest';
import jwt from 'jsonwebtoken';
import app from '../app';
import { Client, Franchisee, User, Warranty } from '../models';

const JWT_SECRET = process.env.JWT_SECRET || 'your_jwt_secret';
const samplePdfPath = path.resolve(__dirname, '../../../artifacts/proposal_emulator_sample.pdf');

describe('warrantyController', () => {
	let franchisee: any;
	let user: any;
	let client: any;
	let token: string;

	beforeAll(async () => {
		franchisee = await Franchisee.create({
			id: 'f1-id',
			name: 'Franchisee 1',
			default_prices: {},
		});
		user = await User.create({
			id: 'u1-id',
			name: 'User 1',
			email: 'user1@example.com',
			password: 'password',
			franchiseeId: franchisee.id,
		});
		client = await Client.create({
			id: 'c1-id',
			name: 'Client 1',
			franchiseeId: franchisee.id,
		});

		token = jwt.sign({ id: user.id, franchiseeId: franchisee.id }, JWT_SECRET);
	});

	describe('POST /api/warranty/upload', () => {
		it('accepts generated PDFs uploaded as application/octet-stream', async () => {
			const response = await request(app)
				.post('/api/warranty/upload')
				.set('Authorization', `Bearer ${token}`)
				.field('client_id', client.id)
				.field('start_date', new Date().toISOString())
				.field('duration_years', '5')
				.field('warranty_card_number', 'WARR-001')
				.attach('file', samplePdfPath, {
					contentType: 'application/octet-stream',
				});

			expect(response.status).toBe(201);
			expect(response.body.pdfUrl).toContain('/uploads/');
			expect(response.body.warrantyCardNumber).toBe('WARR-001');

			const warranty = await Warranty.findOne({ where: { clientId: client.id } });
			expect(warranty).toBeDefined();
			expect((warranty as any).warrantyCardNumber).toBe('WARR-001');
		});
	});
});
