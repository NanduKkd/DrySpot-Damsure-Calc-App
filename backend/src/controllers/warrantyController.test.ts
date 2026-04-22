import path from 'path';
import request from 'supertest';
import jwt from 'jsonwebtoken';
import app from '../app';
import { Client, Franchisee, User, Warranty } from '../models';

const JWT_SECRET = process.env.JWT_SECRET || 'your_jwt_secret';
const samplePdfPath = path.resolve(__dirname, '../../../artifacts/proposal_emulator_sample.pdf');

describe('warrantyController', () => {
	let franchisee: any;
	let otherFranchisee: any;
	let user: any;
	let client: any;
	let otherClient: any;
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
		otherFranchisee = await Franchisee.create({
			id: 'f2-id',
			name: 'Franchisee 2',
			default_prices: {},
		});
		otherClient = await Client.create({
			id: 'c2-id',
			name: 'Client 2',
			franchiseeId: otherFranchisee.id,
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

		it('returns 400 when client_id is missing', async () => {
			const response = await request(app)
				.post('/api/warranty/upload')
				.set('Authorization', `Bearer ${token}`)
				.field('start_date', new Date().toISOString())
				.field('duration_years', '5')
				.field('warranty_card_number', 'WARR-002')
				.attach('file', samplePdfPath, {
					contentType: 'application/octet-stream',
				});

			expect(response.status).toBe(400);
			expect(response.body.error).toBe('client_id is required');
		});

		it('returns 404 when client_id does not exist on server', async () => {
			const response = await request(app)
				.post('/api/warranty/upload')
				.set('Authorization', `Bearer ${token}`)
				.field('client_id', '11111111-1111-1111-1111-111111111111')
				.field('start_date', new Date().toISOString())
				.field('duration_years', '5')
				.field('warranty_card_number', 'WARR-003')
				.attach('file', samplePdfPath, {
					contentType: 'application/octet-stream',
				});

			expect(response.status).toBe(404);
			expect(response.body.error).toBe(
				'Client not found. Please sync client data and try again',
			);
		});

		it('returns 403 when client belongs to another franchisee', async () => {
			const response = await request(app)
				.post('/api/warranty/upload')
				.set('Authorization', `Bearer ${token}`)
				.field('client_id', otherClient.id)
				.field('start_date', new Date().toISOString())
				.field('duration_years', '5')
				.field('warranty_card_number', 'WARR-004')
				.attach('file', samplePdfPath, {
					contentType: 'application/octet-stream',
				});

			expect(response.status).toBe(403);
			expect(response.body.error).toBe(
				'Unauthorized: Client does not belong to your franchisee',
			);
		});
	});
	});
