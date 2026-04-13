import path from 'path';
import request from 'supertest';
import jwt from 'jsonwebtoken';
import app from '../app';
import { Client, Franchisee, Proposal, User } from '../models';

const JWT_SECRET = process.env.JWT_SECRET || 'your_jwt_secret';
const samplePdfPath = path.resolve(__dirname, '../../../artifacts/proposal_emulator_sample.pdf');

describe('proposalController', () => {
	let franchisee: any;
	let user: any;
	let client: any;
	let token: string;

	beforeAll(async () => {
		franchisee = await Franchisee.create({
			id: 'f2-id',
			name: 'Franchisee 2',
			default_prices: {},
		});
		user = await User.create({
			id: 'u2-id',
			name: 'User 2',
			email: 'user2@example.com',
			password: 'password',
			franchiseeId: franchisee.id,
		});
		client = await Client.create({
			id: 'c2-id',
			name: 'Client 2',
			franchiseeId: franchisee.id,
		});

		token = jwt.sign({ id: user.id, franchiseeId: franchisee.id }, JWT_SECRET);
	});

	describe('POST /api/proposal/upload', () => {
		it('accepts generated PDFs uploaded as application/octet-stream', async () => {
			const response = await request(app)
				.post('/api/proposal/upload')
				.set('Authorization', `Bearer ${token}`)
				.field('client_id', client.id)
				.attach('file', samplePdfPath, {
					contentType: 'application/octet-stream',
				});

			expect(response.status).toBe(201);
			expect(response.body.pdfUrl).toContain('/uploads/');

			const proposal = await Proposal.findOne({ where: { clientId: client.id } });
			expect(proposal).toBeDefined();
			expect((proposal as any).pdfUrl).toContain('/uploads/');
		});
	});
});
