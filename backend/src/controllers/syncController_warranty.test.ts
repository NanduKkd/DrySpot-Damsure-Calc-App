import request from 'supertest';
import jwt from 'jsonwebtoken';
import fs from 'fs';
import path from 'path';
import app from '../app';
import { Client, Franchisee, ManagedFileCleanup, Proposal, User, Warranty } from '../models';

const JWT_SECRET = process.env.JWT_SECRET!;
const uploadsDirectory = path.join(__dirname, '../../uploads');

describe('syncController warranty and PDF server invariants', () => {
	const franchiseeId = '00000000-0000-0000-0000-000000000301';
	const clientId = '00000000-0000-0000-0000-000000000302';
	const firstWarrantyId = '00000000-0000-0000-0000-000000000303';
	const replacementWarrantyId = '00000000-0000-0000-0000-000000000304';
	const proposalId = '00000000-0000-0000-0000-000000000305';
	const fileClientId = '00000000-0000-0000-0000-000000000307';
	const fileWarrantyId = '00000000-0000-0000-0000-000000000308';
	const fileProposalId = '00000000-0000-0000-0000-000000000309';
	const rolloutClientId = '00000000-0000-0000-0000-000000000320';
	const rolloutHistoricalWarrantyId = '00000000-0000-0000-0000-000000000323';
	const rolloutWarrantyId = '00000000-0000-0000-0000-000000000321';
	const rolloutReplacementId = '00000000-0000-0000-0000-000000000322';
	let token: string;

	beforeAll(async () => {
		await Franchisee.create({
			id: franchiseeId,
			name: 'Warranty sync tenant',
			default_prices: {},
		});
		const user = await User.create({
			id: '00000000-0000-0000-0000-000000000306',
			name: 'Warranty sync user',
			email: 'warranty-sync@example.com',
			password: 'unused',
			franchiseeId,
		});
		await Client.create({ id: clientId, franchiseeId, name: 'Warranty client' });
		token = jwt.sign({ id: user.id, franchiseeId, tokenVersion: 0 }, JWT_SECRET);
	});

	const sync = (changes: object) =>
		request(app)
			.post('/api/sync')
			.set('Authorization', `Bearer ${token}`)
			.set('Host', 'attacker.invalid')
			.send({ last_sync_time: null, changes });

	const warranty = (remote_id: string, extras = {}) => ({
		remote_id,
		client_id: clientId,
		warranty_card_number: `card-${remote_id}`,
		start_date: '2026-01-01T00:00:00.000Z',
		duration_years: 1,
		pdf_url: 'https://attacker.invalid/api/warranty/foreign/download',
		pdf_file_name: '../foreign-tenant.pdf',
		active_client_id: '00000000-0000-0000-0000-000000000999',
		...extras,
	});

	it('makes synced warranties active and ignores forged PDF metadata', async () => {
		const response = await sync({ warranties: [warranty(firstWarrantyId)] });
		expect(response.status).toBe(200);

		const stored = await Warranty.findByPk(firstWarrantyId);
		expect(stored?.activeClientId).toBe(clientId);
		expect(stored?.pdfFileName).toBeNull();
		expect(stored?.pdfUrl).toContain(`/api/warranty/${firstWarrantyId}/download`);
		expect(stored?.pdfUrl).not.toContain('attacker.invalid');
		expect(stored?.pdfUrl).toMatch(/^\/api\/warranty\/[0-9a-f-]+\/download$/);
	});

	it('reports an offline active-warranty conflict without partial writes', async () => {
		const response = await sync({ warranties: [warranty(replacementWarrantyId)] });
		expect(response.status).toBe(200);
		expect(response.body.outcomes.warranties).toEqual([
			{
				remote_id: replacementWarrantyId,
				status: 'rejected',
				code: 'active_warranty_exists',
			},
		]);
		expect(await Warranty.findByPk(replacementWarrantyId, { paranoid: false })).toBeNull();
		expect((await Warranty.findByPk(firstWarrantyId))?.activeClientId).toBe(clientId);
	});

	it('never infers destructive replacement from generic sync metadata', async () => {
		const response = await sync({
			warranties: [warranty(replacementWarrantyId, { replace_existing: true })],
		});
		expect(response.status).toBe(200);
		expect(response.body.outcomes.warranties[0]).toEqual({
			remote_id: replacementWarrantyId,
			status: 'rejected',
			code: 'active_warranty_exists',
		});
		expect((await Warranty.findByPk(firstWarrantyId))?.activeClientId).toBe(clientId);
		expect(await Warranty.findByPk(replacementWarrantyId, { paranoid: false })).toBeNull();
	});

	it('backfills a rollout-window soft delete without allowing sync replacement', async () => {
		await Client.create({
			id: rolloutClientId,
			franchiseeId,
			name: 'Rolling deploy client',
		});
		const migratedWarranty = await Warranty.create({
			id: rolloutHistoricalWarrantyId,
			clientId: rolloutClientId,
			activeClientId: rolloutClientId,
			warrantyCardNumber: 'migrated-active-warranty',
			startDate: new Date('2025-01-01T00:00:00.000Z'),
			durationYears: 1,
			pdfUrl: `/api/warranty/${rolloutHistoricalWarrantyId}/download`,
		});
		// Reproduce the old process's replacement after migration: the soft
		// delete retains active_client_id, while its new current row leaves it null.
		await migratedWarranty.destroy();
		await Warranty.create({
			id: rolloutWarrantyId,
			clientId: rolloutClientId,
			activeClientId: null,
			warrantyCardNumber: 'old-process-replacement',
			startDate: new Date('2026-01-01T00:00:00.000Z'),
			durationYears: 1,
			pdfUrl: `/api/warranty/${rolloutWarrantyId}/download`,
		});

		const response = await sync({
			warranties: [
				warranty(rolloutReplacementId, {
					client_id: rolloutClientId,
					replace_existing: true,
				}),
			],
		});

		expect(response.status).toBe(200);
		expect(response.body.outcomes.warranties[0]).toEqual({
			remote_id: rolloutReplacementId,
			status: 'rejected',
			code: 'active_warranty_exists',
		});
		expect(await Warranty.findByPk(rolloutWarrantyId)).not.toBeNull();
		expect(
			await Warranty.findByPk(rolloutHistoricalWarrantyId, { paranoid: false }),
		).toBeNull();
		expect(await Warranty.findByPk(rolloutReplacementId)).toBeNull();
	});

	it('does not allow camelCase PDF metadata to mutate an existing warranty', async () => {
		const before = await Warranty.findByPk(firstWarrantyId);
		const response = await sync({
			warranties: [
				warranty(firstWarrantyId, {
					pdfUrl: 'https://attacker.invalid/api/warranty/reassigned/download',
					pdfFileName: '../reassigned.pdf',
				}),
			],
		});

		expect(response.status).toBe(200);
		const stored = await Warranty.findByPk(firstWarrantyId);
		expect(stored?.pdfUrl).toBe(before?.pdfUrl);
		expect(stored?.pdfFileName).toBe(before?.pdfFileName);
	});

	it('does not allow synced proposal metadata to select a stored PDF', async () => {
		const response = await sync({
			proposals: [
				{
					remote_id: proposalId,
					client_id: clientId,
					pdf_url: 'https://attacker.invalid/api/proposal/foreign/download',
					pdf_file_name: '../foreign-tenant.pdf',
				},
			],
		});
		expect(response.status).toBe(200);
		const stored = await Proposal.findByPk(proposalId);
		expect(stored?.pdfFileName).toBeNull();
		expect(stored?.pdfUrl).toContain(`/api/proposal/${proposalId}/download`);
		expect(stored?.pdfUrl).not.toContain('attacker.invalid');
		expect(stored?.pdfUrl).toMatch(/^\/api\/proposal\/[0-9a-f-]+\/download$/);

		const updateResponse = await sync({
			proposals: [
				{
					remote_id: proposalId,
					client_id: clientId,
					pdfUrl: 'https://attacker.invalid/api/proposal/reassigned/download',
					pdfFileName: '../reassigned.pdf',
				},
			],
		});
		expect(updateResponse.status).toBe(200);
		const updated = await Proposal.findByPk(proposalId);
		expect(updated?.pdfUrl).toBe(stored?.pdfUrl);
		expect(updated?.pdfFileName).toBe(stored?.pdfFileName);
	});

	it('rejects warranty sync deletion while still deleting proposal metadata safely', async () => {
		await Client.create({ id: fileClientId, franchiseeId, name: 'File lifecycle client' });
		await Warranty.create({
			id: fileWarrantyId,
			clientId: fileClientId,
			activeClientId: fileClientId,
			warrantyCardNumber: 'file-card',
			startDate: new Date(),
			durationYears: 1,
			pdfUrl: 'http://localhost/api/warranty/file/download',
			pdfFileName: 'server-owned.pdf',
		});
		await Proposal.create({
			id: fileProposalId,
			clientId: fileClientId,
			pdfUrl: 'http://localhost/api/proposal/file/download',
			pdfFileName: 'proposal-owned.pdf',
		});
		const response = await sync({
			warranties: [{ remote_id: fileWarrantyId, deleted_at: new Date().toISOString() }],
			proposals: [{ remote_id: fileProposalId, deleted_at: new Date().toISOString() }],
		});

		expect(response.status).toBe(200);
		expect(response.body.outcomes.warranties[0]).toEqual({
			remote_id: fileWarrantyId,
			status: 'rejected',
			code: 'online_delete_required',
		});
		expect(await Warranty.findByPk(fileWarrantyId)).not.toBeNull();
		expect(
			await ManagedFileCleanup.count({ where: { storageKey: 'proposal-owned.pdf' } }),
		).toBe(0);
	});

	it('client tombstone cleans only its managed photo and PDF files after commit', async () => {
		const deletedClientId = '00000000-0000-0000-0000-000000000310';
		const deletedWarrantyId = '00000000-0000-0000-0000-000000000311';
		const deletedProposalId = '00000000-0000-0000-0000-000000000312';
		const photoFilename = '00000000-0000-0000-0000-000000000313.jpg';
		const warrantyFilename = 'client-tombstone-warranty.pdf';
		const proposalFilename = 'client-tombstone-proposal.pdf';
		const foreignFilename = 'foreign-tenant-file.pdf';
		const foreignFranchiseeId = '00000000-0000-0000-0000-000000000314';
		const foreignClientId = '00000000-0000-0000-0000-000000000315';
		const foreignWarrantyId = '00000000-0000-0000-0000-000000000316';
		const photoUrl = `/api/photos/client/${deletedClientId}/${photoFilename}`;
		fs.mkdirSync(uploadsDirectory, { recursive: true });
		[photoFilename, warrantyFilename, proposalFilename, foreignFilename].forEach((filename) =>
			fs.writeFileSync(path.join(uploadsDirectory, filename), 'test'),
		);
		await Client.create({
			id: deletedClientId,
			franchiseeId,
			name: 'Tombstoned client',
			photos: JSON.stringify([photoUrl]),
		});
		await Warranty.create({
			id: deletedWarrantyId,
			clientId: deletedClientId,
			activeClientId: deletedClientId,
			warrantyCardNumber: 'tombstone-card',
			startDate: new Date(),
			durationYears: 1,
			pdfUrl: 'http://localhost/api/warranty/tombstone/download',
			pdfFileName: warrantyFilename,
		});
		await Proposal.create({
			id: deletedProposalId,
			clientId: deletedClientId,
			pdfUrl: 'http://localhost/api/proposal/tombstone/download',
			pdfFileName: proposalFilename,
		});
		await Franchisee.create({
			id: foreignFranchiseeId,
			name: 'Foreign tombstone tenant',
			default_prices: {},
		});
		await Client.create({
			id: foreignClientId,
			franchiseeId: foreignFranchiseeId,
			name: 'Foreign client',
		});
		await Warranty.create({
			id: foreignWarrantyId,
			clientId: foreignClientId,
			activeClientId: foreignClientId,
			warrantyCardNumber: 'foreign-card',
			startDate: new Date(),
			durationYears: 1,
			pdfUrl: 'http://localhost/api/warranty/foreign/download',
			pdfFileName: foreignFilename,
		});

		const response = await sync({
			clients: [{ remote_id: deletedClientId, deleted_at: new Date().toISOString() }],
		});
		expect(response.status).toBe(200);
		expect(await Client.findByPk(deletedClientId)).toBeNull();
		expect(await Warranty.findByPk(deletedWarrantyId)).toBeNull();
		expect(await Proposal.findByPk(deletedProposalId)).toBeNull();
		expect(await Warranty.findByPk(deletedWarrantyId, { paranoid: false })).toBeNull();
		expect(fs.existsSync(path.join(uploadsDirectory, photoFilename))).toBe(false);
		expect(fs.existsSync(path.join(uploadsDirectory, warrantyFilename))).toBe(false);
		expect(fs.existsSync(path.join(uploadsDirectory, proposalFilename))).toBe(false);
		expect(fs.existsSync(path.join(uploadsDirectory, foreignFilename))).toBe(true);
		expect(await Warranty.findByPk(foreignWarrantyId)).not.toBeNull();
		fs.unlinkSync(path.join(uploadsDirectory, foreignFilename));
	});
});
