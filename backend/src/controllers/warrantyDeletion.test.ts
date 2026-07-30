import fs from 'fs';
import request from 'supertest';
import jwt from 'jsonwebtoken';
import app from '../app';
import {
	Client,
	Franchisee,
	ManagedFileCleanup,
	User,
	Warranty,
	WarrantyDeletionTombstone,
} from '../models';
import { irreversibleWarrantyConfirmation } from '../services/warrantyLifecycle';

const JWT_SECRET = process.env.JWT_SECRET!;
const samplePdf = Buffer.from('%PDF-1.4\nAPP-110 test\n%%EOF');

describe('APP-110 sync-safe permanent warranty deletion', () => {
	const tenantId = '10000000-0000-0000-0000-000000000001';
	const otherTenantId = '20000000-0000-0000-0000-000000000001';
	const clientId = '10000000-0000-0000-0000-000000000002';
	const otherClientId = '20000000-0000-0000-0000-000000000002';
	let token: string;
	let otherToken: string;

	beforeAll(async () => {
		await Franchisee.bulkCreate([
			{ id: tenantId, name: 'APP-110 tenant', default_prices: {} },
			{ id: otherTenantId, name: 'APP-110 other tenant', default_prices: {} },
		]);
		const [user, otherUser] = await Promise.all([
			User.create({
				id: '10000000-0000-0000-0000-000000000003',
				name: 'APP-110 user',
				email: 'app-110@example.com',
				password: 'unused',
				franchiseeId: tenantId,
			}),
			User.create({
				id: '20000000-0000-0000-0000-000000000003',
				name: 'APP-110 other user',
				email: 'app-110-other@example.com',
				password: 'unused',
				franchiseeId: otherTenantId,
			}),
		]);
		await Client.bulkCreate([
			{ id: clientId, name: 'APP-110 client', franchiseeId: tenantId },
			{
				id: otherClientId,
				name: 'APP-110 other client',
				franchiseeId: otherTenantId,
			},
		]);
		token = jwt.sign({ id: user.id, franchiseeId: tenantId, tokenVersion: 0 }, JWT_SECRET);
		otherToken = jwt.sign(
			{
				id: otherUser.id,
				franchiseeId: otherTenantId,
				tokenVersion: 0,
			},
			JWT_SECRET,
		);
	});

	const createWarranty = (
		id: string,
		ownerClientId = clientId,
		extras: Record<string, unknown> = {},
	) =>
		Warranty.create({
			id,
			clientId: ownerClientId,
			activeClientId: ownerClientId,
			warrantyCardNumber: `CARD-${id.slice(-4)}`,
			startDate: new Date('2026-01-01T00:00:00.000Z'),
			durationYears: 5,
			pdfUrl: `/api/warranty/${id}/download`,
			version: 1,
			...extras,
		});

	const confirmationFor = (warranty: Warranty) => ({
		confirmed_warranty_id: warranty.id,
		confirmed_warranty_card_number: warranty.warrantyCardNumber,
		confirmed_warranty_version: warranty.version,
		irreversible_confirmation: irreversibleWarrantyConfirmation(warranty.warrantyCardNumber),
	});

	const deleteRequest = (
		warranty: Warranty,
		requestToken = token,
		key = `delete-${warranty.id}`,
		body: Record<string, unknown> = confirmationFor(warranty),
	) =>
		request(app)
			.delete(`/api/warranty/${warranty.id}`)
			.set('Authorization', `Bearer ${requestToken}`)
			.set('Idempotency-Key', key)
			.send(body);

	it('requires authentication, derives the tenant from auth, and rejects stale confirmation', async () => {
		const id = '10000000-0000-0000-0000-000000000010';
		const warranty = await createWarranty(id);

		expect((await request(app).delete(`/api/warranty/${id}`)).status).toBe(401);
		expect((await deleteRequest(warranty, otherToken, 'foreign-delete-key')).status).toBe(403);

		const stale = await deleteRequest(warranty, token, 'stale-delete-key', {
			...confirmationFor(warranty),
			confirmed_warranty_version: warranty.version + 1,
		});
		expect(stale.status).toBe(409);
		expect(stale.body.code).toBe('stale_confirmation');
		expect(await Warranty.findByPk(id)).not.toBeNull();
		await warranty.destroy({ force: true });
	});

	it('hard-deletes idempotently, reserves the UUID globally, and defeats later sync edits', async () => {
		const id = '10000000-0000-0000-0000-000000000011';
		const warranty = await createWarranty(id);
		const key = 'idempotent-delete-key-001';

		expect((await deleteRequest(warranty, token, key)).status).toBe(204);
		expect((await deleteRequest(warranty, token, key)).status).toBe(204);
		expect(await Warranty.findByPk(id, { paranoid: false })).toBeNull();
		expect(await WarrantyDeletionTombstone.count({ where: { warrantyId: id } })).toBe(1);
		const otherId = '10000000-0000-0000-0000-000000000014';
		const otherWarranty = await createWarranty(otherId);
		const reusedKey = await deleteRequest(otherWarranty, token, key);
		expect(reusedKey.status).toBe(409);
		expect(reusedKey.body.code).toBe('idempotency_conflict');
		expect(await Warranty.findByPk(otherId)).not.toBeNull();
		await otherWarranty.destroy({ force: true });

		const resurrection = await request(app)
			.post('/api/sync')
			.set('Authorization', `Bearer ${token}`)
			.send({
				warranty_tombstone_cursor: '0',
				changes: {
					warranties: [
						{
							remote_id: id,
							client_id: clientId,
							warranty_card_number: warranty.warrantyCardNumber,
							start_date: warranty.startDate.toISOString(),
							duration_years: warranty.durationYears,
						},
					],
				},
			});
		expect(resurrection.status).toBe(200);
		expect(resurrection.body.outcomes.warranties).toEqual([
			{
				remote_id: id,
				status: 'tombstoned',
				code: 'warranty_deleted',
			},
		]);
		expect(resurrection.body.updates.warranty_tombstones).toEqual([
			expect.objectContaining({ warranty_id: id }),
		]);
		expect(await Warranty.findByPk(id, { paranoid: false })).toBeNull();

		const crossTenantReuse = await request(app)
			.post('/api/sync')
			.set('Authorization', `Bearer ${otherToken}`)
			.send({
				warranty_tombstone_cursor: '0',
				changes: {
					warranties: [
						{
							remote_id: id,
							client_id: otherClientId,
							warranty_card_number: 'CROSS-TENANT-REUSE',
							start_date: '2026-01-01T00:00:00.000Z',
							duration_years: 5,
						},
					],
				},
			});
		expect(crossTenantReuse.status).toBe(200);
		expect(crossTenantReuse.body.outcomes.warranties[0].status).toBe('tombstoned');
		expect(crossTenantReuse.body.updates.warranty_tombstones).toEqual([]);
		expect(await Warranty.findByPk(id, { paranoid: false })).toBeNull();
	});

	it('commits deletion despite unlink failure and rejects unsafe stored paths', async () => {
		const failureId = '10000000-0000-0000-0000-000000000012';
		const failureWarranty = await createWarranty(failureId, clientId, {
			pdfFileName: 'app-110-storage-failure.pdf',
		});
		const unlink = jest
			.spyOn(fs.promises, 'unlink')
			.mockRejectedValueOnce(new Error('injected storage outage'));

		expect(
			(await deleteRequest(failureWarranty, token, 'file-failure-delete-key')).status,
		).toBe(204);
		await new Promise((resolve) => setImmediate(resolve));
		expect(await Warranty.findByPk(failureId, { paranoid: false })).toBeNull();
		expect(
			(
				await ManagedFileCleanup.findOne({
					where: { storageKey: 'app-110-storage-failure.pdf' },
				})
			)?.attempts,
		).toBe(1);
		unlink.mockRestore();

		const unsafeId = '10000000-0000-0000-0000-000000000013';
		const unsafeWarranty = await createWarranty(unsafeId, clientId, {
			pdfFileName: '../outside-managed-storage.pdf',
		});
		expect((await deleteRequest(unsafeWarranty, token, 'unsafe-path-delete-key')).status).toBe(
			204,
		);
		expect(
			await ManagedFileCleanup.count({
				where: { storageKey: '../outside-managed-storage.pdf' },
			}),
		).toBe(0);
	});

	it('atomically replaces only the explicitly confirmed version and replays the same request', async () => {
		const replacementClientId = '10000000-0000-0000-0000-000000000020';
		const oldId = '10000000-0000-0000-0000-000000000021';
		await Client.create({
			id: replacementClientId,
			name: 'Replacement client',
			franchiseeId: tenantId,
		});
		const old = await createWarranty(oldId, replacementClientId);
		const key = 'replacement-idempotency-key-001';
		const upload = () =>
			request(app)
				.post('/api/warranty/upload')
				.set('Authorization', `Bearer ${token}`)
				.set('Idempotency-Key', key)
				.field('client_id', replacementClientId)
				.field('start_date', '2026-07-30T00:00:00.000Z')
				.field('duration_years', '10')
				.field('warranty_card_number', 'CARD-REPLACEMENT')
				.field('confirmed_warranty_id', old.id)
				.field('confirmed_warranty_card_number', old.warrantyCardNumber)
				.field('confirmed_warranty_version', old.version.toString())
				.field(
					'irreversible_confirmation',
					irreversibleWarrantyConfirmation(old.warrantyCardNumber),
				)
				.attach('file', samplePdf, {
					filename: 'replacement.pdf',
					contentType: 'application/pdf',
				});

		const first = await upload();
		expect(first.status).toBe(201);
		expect(first.body.replayed).toBe(false);
		expect(await Warranty.findByPk(old.id, { paranoid: false })).toBeNull();
		expect((await WarrantyDeletionTombstone.findByPk(old.id))?.replacementWarrantyId).toBe(
			first.body.id,
		);
		expect(await Warranty.count({ where: { clientId: replacementClientId } })).toBe(1);

		const replay = await upload();
		expect(replay.status).toBe(201);
		expect(replay.body.id).toBe(first.body.id);
		expect(replay.body.replayed).toBe(true);
		expect(await Warranty.count({ where: { clientId: replacementClientId } })).toBe(1);

		const stale = await request(app)
			.post('/api/warranty/upload')
			.set('Authorization', `Bearer ${token}`)
			.set('Idempotency-Key', 'different-replacement-key')
			.field('client_id', replacementClientId)
			.field('start_date', '2026-07-30T00:00:00.000Z')
			.field('duration_years', '10')
			.field('warranty_card_number', 'SHOULD-NOT-WIN')
			.field('confirmed_warranty_id', old.id)
			.field('confirmed_warranty_card_number', old.warrantyCardNumber)
			.field('confirmed_warranty_version', old.version.toString())
			.field(
				'irreversible_confirmation',
				irreversibleWarrantyConfirmation(old.warrantyCardNumber),
			)
			.attach('file', samplePdf, {
				filename: 'stale.pdf',
				contentType: 'application/pdf',
			});
		expect(stale.status).toBe(409);
		expect(stale.body.code).toBe('stale_confirmation');
		expect(await Warranty.count({ where: { clientId: replacementClientId } })).toBe(1);
	});

	it('serializes competing replacements so one confirmed old version wins', async () => {
		const raceClientId = '10000000-0000-0000-0000-000000000030';
		const oldId = '10000000-0000-0000-0000-000000000031';
		await Client.create({
			id: raceClientId,
			name: 'Replacement race client',
			franchiseeId: tenantId,
		});
		const old = await createWarranty(oldId, raceClientId);
		const upload = (key: string, card: string) =>
			request(app)
				.post('/api/warranty/upload')
				.set('Authorization', `Bearer ${token}`)
				.set('Idempotency-Key', key)
				.field('client_id', raceClientId)
				.field('start_date', '2026-07-30T00:00:00.000Z')
				.field('duration_years', '5')
				.field('warranty_card_number', card)
				.field('confirmed_warranty_id', old.id)
				.field('confirmed_warranty_card_number', old.warrantyCardNumber)
				.field('confirmed_warranty_version', old.version.toString())
				.field(
					'irreversible_confirmation',
					irreversibleWarrantyConfirmation(old.warrantyCardNumber),
				)
				.attach('file', samplePdf, {
					filename: `${card}.pdf`,
					contentType: 'application/pdf',
				});

		// SQLite uses one connection and cannot run two explicit transactions at
		// once. PostgreSQL exercises true overlap; SQLite exercises the same
		// lock-serialized order deterministically.
		const responses =
			Warranty.sequelize!.getDialect() === 'sqlite'
				? [
						await upload('replacement-race-key-001', 'RACE-A'),
						await upload('replacement-race-key-002', 'RACE-B'),
					]
				: await Promise.all([
						upload('replacement-race-key-001', 'RACE-A'),
						upload('replacement-race-key-002', 'RACE-B'),
					]);
		expect(responses.map((response) => response.status).sort()).toEqual([201, 409]);
		expect(await Warranty.count({ where: { clientId: raceClientId } })).toBe(1);
		expect(await WarrantyDeletionTombstone.count({ where: { warrantyId: oldId } })).toBe(1);
	});

	it('emits permanent warranty tombstones when a client is deleted', async () => {
		const deletedClientId = '10000000-0000-0000-0000-000000000040';
		const deletedWarrantyId = '10000000-0000-0000-0000-000000000041';
		await Client.create({
			id: deletedClientId,
			name: 'Deleted client',
			franchiseeId: tenantId,
		});
		await createWarranty(deletedWarrantyId, deletedClientId);

		const response = await request(app)
			.post('/api/sync')
			.set('Authorization', `Bearer ${token}`)
			.send({
				warranty_tombstone_cursor: '0',
				changes: {
					clients: [
						{
							remote_id: deletedClientId,
							deleted_at: '2026-07-30T00:00:00.000Z',
						},
					],
				},
			});
		expect(response.status).toBe(200);
		expect(response.body.updates.warranty_tombstones).toContainEqual(
			expect.objectContaining({ warranty_id: deletedWarrantyId }),
		);
		expect(await Warranty.findByPk(deletedWarrantyId, { paranoid: false })).toBeNull();
	});
});
