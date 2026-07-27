import request from 'supertest';
import jwt from 'jsonwebtoken';
import app from '../app';
import { Client, Franchisee, Proposal, User } from '../models';

const JWT_SECRET = process.env.JWT_SECRET!;
const samplePdf = Buffer.from('%PDF-1.4\nminimal test PDF\n%%EOF');

describe('proposalController', () => {
	let franchisee: any;
	let otherFranchisee: any;
	let user: any;
	let otherUser: any;
	let client: any;
	let token: string;
	let otherToken: string;

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
		otherFranchisee = await Franchisee.create({ id: 'f3-id', name: 'Franchisee 3', default_prices: {} });
		otherUser = await User.create({
			id: 'u3-id', name: 'User 3', email: 'user3@example.com', password: 'password', franchiseeId: otherFranchisee.id,
		});

		token = jwt.sign({ id: user.id, franchiseeId: franchisee.id }, JWT_SECRET);
		otherToken = jwt.sign({ id: otherUser.id, franchiseeId: otherFranchisee.id }, JWT_SECRET);
	});

	describe('POST /api/proposal/upload', () => {
		it('accepts generated PDFs uploaded as application/octet-stream', async () => {
			const response = await request(app)
				.post('/api/proposal/upload')
				.set('Authorization', `Bearer ${token}`)
				.set('Host', 'attacker.invalid')
				.field('client_id', client.id)
				.attach('file', samplePdf, {
					filename: 'proposal.pdf',
					contentType: 'application/octet-stream',
				});

			expect(response.status).toBe(201);
			expect(response.body.pdfUrl).toMatch(/^\/api\/proposal\/[0-9a-f-]+\/download$/);
			expect(response.body.pdfUrl).not.toContain('attacker.invalid');

			const proposal = await Proposal.findOne({ where: { clientId: client.id } });
			expect(proposal).toBeDefined();
			expect((proposal as any).pdfUrl).toContain('/api/proposal/');
		});

		it('serves the PDF only to the owning authenticated franchisee', async () => {
			const upload = await request(app)
				.post('/api/proposal/upload')
				.set('Authorization', `Bearer ${token}`)
				.field('client_id', client.id)
				.attach('file', samplePdf, { filename: 'proposal.pdf', contentType: 'application/octet-stream' });

			expect(upload.status).toBe(201);
			const ownedDownload = await request(app)
				.get(upload.body.pdfUrl)
				.set('Authorization', `Bearer ${token}`);
			expect(ownedDownload.status).toBe(200);
			expect(ownedDownload.headers['content-type']).toMatch(/application\/pdf/);
			expect(ownedDownload.body).toEqual(samplePdf);

			const foreignDownload = await request(app)
				.get(upload.body.pdfUrl)
				.set('Authorization', `Bearer ${otherToken}`);
			expect(foreignDownload.status).toBe(404);
		});
	});
});
