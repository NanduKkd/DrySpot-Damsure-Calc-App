import request from 'supertest';
import jwt from 'jsonwebtoken';
import app from '../app';
import { Client, Franchisee, User, Warranty } from '../models';
import { irreversibleWarrantyConfirmation } from '../services/warrantyLifecycle';

const JWT_SECRET = process.env.JWT_SECRET!;
const samplePdf = Buffer.from('%PDF-1.4\nminimal test PDF\n%%EOF');

describe('warrantyController', () => {
	let franchisee: any;
	let otherFranchisee: any;
	let user: any;
	let otherUser: any;
	let client: any;
	let otherClient: any;
	let token: string;
	let otherToken: string;

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
		otherUser = await User.create({
			id: 'u2-id',
			name: 'User 2',
			email: 'user2@example.com',
			password: 'password',
			franchiseeId: otherFranchisee.id,
		});

		token = jwt.sign({ id: user.id, franchiseeId: franchisee.id }, JWT_SECRET);
		otherToken = jwt.sign({ id: otherUser.id, franchiseeId: otherFranchisee.id }, JWT_SECRET);
	});

	describe('POST /api/warranty/upload', () => {
		it('accepts generated PDFs uploaded as application/octet-stream', async () => {
			const response = await request(app)
				.post('/api/warranty/upload')
				.set('Authorization', `Bearer ${token}`)
				.set('Host', 'attacker.invalid')
				.field('client_id', client.id)
				.field('start_date', new Date().toISOString())
				.field('duration_years', '5')
				.field('warranty_card_number', 'WARR-001')
				.attach('file', samplePdf, {
					filename: 'warranty.pdf',
					contentType: 'application/octet-stream',
				});

			expect(response.status).toBe(201);
			expect(response.body.pdfUrl).toMatch(/^\/api\/warranty\/[0-9a-f-]+\/download$/);
			expect(response.body.pdfUrl).not.toContain('attacker.invalid');
			expect(response.body.warrantyCardNumber).toBe('WARR-001');

			const warranty = await Warranty.findOne({ where: { clientId: client.id } });
			expect(warranty).toBeDefined();
			expect((warranty as any).warrantyCardNumber).toBe('WARR-001');

			const unauthorizedDownload = await request(app).get(
				`/api/warranty/${response.body.id}/download`,
			);
			expect(unauthorizedDownload.status).toBe(401);
		});

		it('serves the PDF only to the owning authenticated franchisee', async () => {
			const current = (await Warranty.findOne({
				where: { clientId: client.id },
			}))!;
			const upload = await request(app)
				.post('/api/warranty/upload')
				.set('Authorization', `Bearer ${token}`)
				.set('Idempotency-Key', 'download-replacement-key')
				.field('client_id', client.id)
				.field('start_date', new Date().toISOString())
				.field('duration_years', '5')
				.field('warranty_card_number', 'WARR-DOWNLOAD')
				.field('confirmed_warranty_id', current.id)
				.field('confirmed_warranty_card_number', current.warrantyCardNumber)
				.field('confirmed_warranty_version', current.version.toString())
				.field(
					'irreversible_confirmation',
					irreversibleWarrantyConfirmation(current.warrantyCardNumber),
				)
				.attach('file', samplePdf, {
					filename: 'warranty.pdf',
					contentType: 'application/octet-stream',
				});

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

		it('requires explicit replacement when an active warranty exists', async () => {
			const response = await request(app)
				.post('/api/warranty/upload')
				.set('Authorization', `Bearer ${token}`)
				.field('client_id', client.id)
				.field('start_date', new Date().toISOString())
				.field('duration_years', '5')
				.field('warranty_card_number', 'WARR-REPLACE')
				.attach('file', samplePdf, {
					filename: 'warranty.pdf',
					contentType: 'application/octet-stream',
				});

			expect(response.status).toBe(409);
			const current = (await Warranty.findOne({
				where: { clientId: client.id },
			}))!;

			const replacement = await request(app)
				.post('/api/warranty/upload')
				.set('Authorization', `Bearer ${token}`)
				.set('Idempotency-Key', 'explicit-replacement-key')
				.field('client_id', client.id)
				.field('start_date', new Date().toISOString())
				.field('duration_years', '5')
				.field('warranty_card_number', 'WARR-REPLACE')
				.field('confirmed_warranty_id', current.id)
				.field('confirmed_warranty_card_number', current.warrantyCardNumber)
				.field('confirmed_warranty_version', current.version.toString())
				.field(
					'irreversible_confirmation',
					irreversibleWarrantyConfirmation(current.warrantyCardNumber),
				)
				.attach('file', samplePdf, {
					filename: 'warranty.pdf',
					contentType: 'application/octet-stream',
				});
			expect(replacement.status).toBe(201);
			expect(await Warranty.count({ where: { activeClientId: client.id } })).toBe(1);
		});

		it('replaces after an old process leaves a historical active marker', async () => {
			const rolloutClient = await Client.create({
				id: 'c-rollout-id',
				name: 'Rolling deploy client',
				franchiseeId: franchisee.id,
			});
			const migratedWarranty = await Warranty.create({
				id: 'w-rollout-migrated-id',
				clientId: rolloutClient.id,
				activeClientId: rolloutClient.id,
				warrantyCardNumber: 'MIGRATED-ACTIVE-WARRANTY',
				startDate: new Date(),
				durationYears: 5,
				pdfUrl: '/api/warranty/w-rollout-migrated-id/download',
			});
			// Reproduce the old process's post-migration replacement sequence.
			await migratedWarranty.destroy();
			const rolloutWarranty = await Warranty.create({
				id: 'w-rollout-id',
				clientId: rolloutClient.id,
				activeClientId: null,
				warrantyCardNumber: 'OLD-PROCESS-WARRANTY',
				startDate: new Date(),
				durationYears: 5,
				pdfUrl: '/api/warranty/w-rollout-id/download',
			});

			const replacement = await request(app)
				.post('/api/warranty/upload')
				.set('Authorization', `Bearer ${token}`)
				.set('Idempotency-Key', 'rollout-replacement-key')
				.field('client_id', rolloutClient.id)
				.field('start_date', new Date().toISOString())
				.field('duration_years', '5')
				.field('warranty_card_number', 'NEW-PROCESS-WARRANTY')
				.field('confirmed_warranty_id', rolloutWarranty.id)
				.field('confirmed_warranty_card_number', rolloutWarranty.warrantyCardNumber)
				.field('confirmed_warranty_version', rolloutWarranty.version.toString())
				.field(
					'irreversible_confirmation',
					irreversibleWarrantyConfirmation(rolloutWarranty.warrantyCardNumber),
				)
				.attach('file', samplePdf, {
					filename: 'warranty.pdf',
					contentType: 'application/octet-stream',
				});

			expect(replacement.status).toBe(201);
			expect(await Warranty.findByPk(rolloutWarranty.id)).toBeNull();
			expect(await Warranty.findByPk(migratedWarranty.id, { paranoid: false })).toBeNull();
			expect(
				await Warranty.count({
					where: { clientId: rolloutClient.id, activeClientId: rolloutClient.id },
				}),
			).toBe(1);
		});

		it('returns 400 when client_id is missing', async () => {
			const response = await request(app)
				.post('/api/warranty/upload')
				.set('Authorization', `Bearer ${token}`)
				.field('start_date', new Date().toISOString())
				.field('duration_years', '5')
				.field('warranty_card_number', 'WARR-002')
				.attach('file', samplePdf, {
					filename: 'warranty.pdf',
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
				.attach('file', samplePdf, {
					filename: 'warranty.pdf',
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
				.attach('file', samplePdf, {
					filename: 'warranty.pdf',
					contentType: 'application/octet-stream',
				});

			expect(response.status).toBe(403);
			expect(response.body.error).toBe(
				'Unauthorized: Client does not belong to your franchisee',
			);
		});
	});
});
