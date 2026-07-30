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
	sequelize,
} from '../models';
import {
	irreversibleWarrantyConfirmation,
	warrantyReplacementConflict,
} from '../services/warrantyLifecycle';

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

	it('requires authentication, derives the tenant from auth, hides foreign existence, and rejects stale confirmation', async () => {
		const id = '10000000-0000-0000-0000-000000000010';
		const warranty = await createWarranty(id);

		expect((await request(app).delete(`/api/warranty/${id}`)).status).toBe(401);
		const foreign = await deleteRequest(warranty, otherToken, 'foreign-delete-key');
		const absentId = '10000000-0000-0000-0000-000000000099';
		const absent = await request(app)
			.delete(`/api/warranty/${absentId}`)
			.set('Authorization', `Bearer ${otherToken}`)
			.set('Idempotency-Key', 'absent-delete-key')
			.send({
				confirmed_warranty_id: absentId,
				confirmed_warranty_card_number: 'OPAQUE',
				confirmed_warranty_version: 1,
				irreversible_confirmation: irreversibleWarrantyConfirmation('OPAQUE'),
			});
		expect(foreign.status).toBe(404);
		expect(foreign.body).toEqual({
			error: 'Warranty not found.',
			code: 'not_found',
		});
		expect(absent.status).toBe(foreign.status);
		expect(absent.body).toEqual(foreign.body);

		const stale = await deleteRequest(warranty, token, 'stale-delete-key', {
			...confirmationFor(warranty),
			confirmed_warranty_version: warranty.version + 1,
		});
		expect(stale.status).toBe(409);
		expect(stale.body.code).toBe('stale_confirmation');
		expect(await Warranty.findByPk(id)).not.toBeNull();
		await warranty.destroy({ force: true });
	});

	it('rejects every malformed confirmation envelope with 422 before lifecycle entry', async () => {
		const id = '10000000-0000-0000-0000-000000000015';
		const warranty = await createWarranty(id);
		const valid = confirmationFor(warranty);
		const malformed: Record<string, unknown>[] = [
			{},
			{
				confirmed_warranty_card_number: valid.confirmed_warranty_card_number,
				confirmed_warranty_version: valid.confirmed_warranty_version,
				irreversible_confirmation: valid.irreversible_confirmation,
			},
			{
				confirmed_warranty_id: valid.confirmed_warranty_id,
				confirmed_warranty_version: valid.confirmed_warranty_version,
				irreversible_confirmation: valid.irreversible_confirmation,
			},
			{
				confirmed_warranty_id: valid.confirmed_warranty_id,
				confirmed_warranty_card_number: valid.confirmed_warranty_card_number,
				irreversible_confirmation: valid.irreversible_confirmation,
			},
			{
				confirmed_warranty_id: valid.confirmed_warranty_id,
				confirmed_warranty_card_number: valid.confirmed_warranty_card_number,
				confirmed_warranty_version: valid.confirmed_warranty_version,
			},
			{ ...valid, confirmed_warranty_id: '' },
			{ ...valid, confirmed_warranty_id: 'not-a-uuid' },
			{ ...valid, confirmed_warranty_id: 7 },
			{ ...valid, confirmed_warranty_card_number: '' },
			{ ...valid, confirmed_warranty_card_number: { value: 'CARD' } },
			{ ...valid, confirmed_warranty_version: 0 },
			{ ...valid, confirmed_warranty_version: -1 },
			{ ...valid, confirmed_warranty_version: 1.5 },
			{ ...valid, confirmed_warranty_version: '1.5' },
			{ ...valid, confirmed_warranty_version: '01' },
			{ ...valid, confirmed_warranty_version: Number.MAX_SAFE_INTEGER + 1 },
			{ ...valid, irreversible_confirmation: '' },
			{ ...valid, irreversible_confirmation: true },
		];
		const transactionSpy = jest.spyOn(sequelize, 'transaction');
		try {
			const missingEnvelopeAndKey = await request(app)
				.delete(`/api/warranty/${id}`)
				.set('Authorization', `Bearer ${token}`)
				.send({});
			expect(missingEnvelopeAndKey.status).toBe(422);
			for (const [index, body] of malformed.entries()) {
				const response = await deleteRequest(
					warranty,
					token,
					`malformed-confirmation-${index}`,
					body,
				);
				expect(response.status).toBe(422);
				expect(response.body).toEqual({
					error: 'Named, version-bound irreversible confirmation is required',
					code: 'confirmation_invalid',
				});
			}
			expect(transactionSpy).not.toHaveBeenCalled();
		} finally {
			transactionSpy.mockRestore();
		}
		expect(await Warranty.findByPk(id)).not.toBeNull();
		expect(await WarrantyDeletionTombstone.count({ where: { warrantyId: id } })).toBe(0);

		const structurallyValidButWrongSource = await deleteRequest(
			warranty,
			token,
			'structurally-valid-stale-source',
			{
				...valid,
				confirmed_warranty_id: '10000000-0000-0000-0000-000000000016',
			},
		);
		expect(structurallyValidButWrongSource.status).toBe(409);
		expect(structurallyValidButWrongSource.body.code).toBe('stale_confirmation');
		await warranty.destroy({ force: true });
	});

	it('hard-deletes idempotently, reserves the UUID globally, and defeats later sync edits', async () => {
		const id = '10000000-0000-0000-0000-000000000011';
		const warranty = await createWarranty(id);
		const key = 'idempotent-delete-key-001';

		const deleted = await deleteRequest(warranty, token, key);
		expect(deleted.status).toBe(200);
		expect(deleted.body).toEqual({
			status: 'deleted',
			warranty_id: id,
			deletion_sequence: expect.any(String),
			replayed: false,
		});
		const replay = await deleteRequest(warranty, token, key);
		expect(replay.status).toBe(200);
		expect(replay.body).toEqual({
			...deleted.body,
			replayed: true,
		});
		const changedConfirmation = await deleteRequest(warranty, token, key, {
			...confirmationFor(warranty),
			irreversible_confirmation: `${irreversibleWarrantyConfirmation(
				warranty.warrantyCardNumber,
			)}!`,
		});
		expect(changedConfirmation.status).toBe(409);
		expect(changedConfirmation.body.code).toBe('idempotency_conflict');
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
		expect(crossTenantReuse.body.outcomes.warranties).toEqual([
			{
				remote_id: id,
				status: 'rejected',
				code: 'warranty_conflict',
			},
		]);
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
		).toBe(200);
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
			200,
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
		const targetId = '10000000-0000-4000-8000-000000000022';
		const upload = ({
			card = 'CARD-REPLACEMENT',
			pdf = samplePdf,
			version = old.version,
			targetClientId = replacementClientId,
			targetWarrantyId = targetId,
			startDate = '2026-07-30T00:00:00.000Z',
			durationYears = '10',
			sourceWarrantyId = old.id,
			confirmedCard = old.warrantyCardNumber,
			phrase = irreversibleWarrantyConfirmation(old.warrantyCardNumber),
		}: {
			card?: string;
			pdf?: Buffer;
			version?: number;
			targetClientId?: string;
			targetWarrantyId?: string;
			startDate?: string;
			durationYears?: string;
			sourceWarrantyId?: string;
			confirmedCard?: string;
			phrase?: string;
		} = {}) =>
			request(app)
				.post('/api/warranty/upload')
				.set('Authorization', `Bearer ${token}`)
				.set('Idempotency-Key', key)
				.field('client_id', targetClientId)
				.field('start_date', startDate)
				.field('duration_years', durationYears)
				.field('warranty_card_number', card)
				.field('replacement_warranty_id', targetWarrantyId)
				.field('confirmed_warranty_id', sourceWarrantyId)
				.field('confirmed_warranty_card_number', confirmedCard)
				.field('confirmed_warranty_version', version.toString())
				.field('irreversible_confirmation', phrase)
				.attach('file', pdf, {
					filename: 'replacement.PDF',
					contentType: 'application/pdf',
				});

		const first = await upload();
		expect(first.status).toBe(201);
		expect(first.body.id).toBe(targetId);
		expect(first.body.replayed).toBe(false);
		expect(first.body.pdfFileName).toMatch(/\.pdf$/);
		expect(first.body.pdfFileName).not.toMatch(/\.PDF$/);
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
		const replacementWarranty = (await Warranty.findByPk(first.body.id))!;
		const changedAction = await deleteRequest(replacementWarranty, token, key);
		expect(changedAction.status).toBe(409);
		expect(changedAction.body.code).toBe('idempotency_conflict');

		const changedPayload = await upload({ card: 'CHANGED-PAYLOAD' });
		expect(changedPayload.status).toBe(409);
		expect(changedPayload.body.code).toBe('idempotency_conflict');

		const changedFile = await upload({
			pdf: Buffer.from('%PDF-1.4\nchanged content\n%%EOF'),
		});
		expect(changedFile.status).toBe(409);
		expect(changedFile.body.code).toBe('idempotency_conflict');

		const changedConfirmation = await upload({ version: old.version + 1 });
		expect(changedConfirmation.status).toBe(409);
		expect(changedConfirmation.body.code).toBe('idempotency_conflict');

		const changedParent = await upload({ targetClientId: otherClientId });
		expect(changedParent.status).toBe(409);
		expect(changedParent.body.code).toBe('idempotency_conflict');

		const changedTarget = await upload({
			targetWarrantyId: '10000000-0000-4000-8000-000000000023',
		});
		expect(changedTarget.status).toBe(409);
		expect(changedTarget.body).toEqual(
			expect.objectContaining({ code: 'idempotency_conflict' }),
		);
		for (const mismatch of [
			{ startDate: '2026-07-31T00:00:00.000Z' },
			{ durationYears: '9' },
			{ sourceWarrantyId: '10000000-0000-0000-0000-000000000025' },
			{ confirmedCard: 'CHANGED-CONFIRMED-CARD' },
			{ phrase: 'PERMANENTLY DELETE WARRANTY CHANGED' },
		]) {
			const response = await upload(mismatch);
			expect(response.status).toBe(409);
			expect(response.body.code).toBe('idempotency_conflict');
		}

		const stale = await request(app)
			.post('/api/warranty/upload')
			.set('Authorization', `Bearer ${token}`)
			.set('Idempotency-Key', 'different-replacement-key')
			.field('client_id', replacementClientId)
			.field('start_date', '2026-07-30T00:00:00.000Z')
			.field('duration_years', '10')
			.field('warranty_card_number', 'SHOULD-NOT-WIN')
			.field('replacement_warranty_id', '10000000-0000-4000-8000-000000000024')
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
		const upload = (key: string, card: string, targetWarrantyId: string) =>
			request(app)
				.post('/api/warranty/upload')
				.set('Authorization', `Bearer ${token}`)
				.set('Idempotency-Key', key)
				.field('client_id', raceClientId)
				.field('start_date', '2026-07-30T00:00:00.000Z')
				.field('duration_years', '5')
				.field('warranty_card_number', card)
				.field('replacement_warranty_id', targetWarrantyId)
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
						await upload(
							'replacement-race-key-001',
							'RACE-A',
							'10000000-0000-4000-8000-000000000032',
						),
						await upload(
							'replacement-race-key-002',
							'RACE-B',
							'10000000-0000-4000-8000-000000000033',
						),
					]
				: await Promise.all([
						upload(
							'replacement-race-key-001',
							'RACE-A',
							'10000000-0000-4000-8000-000000000032',
						),
						upload(
							'replacement-race-key-002',
							'RACE-B',
							'10000000-0000-4000-8000-000000000033',
						),
					]);
		expect(responses.map((response) => response.status).sort()).toEqual([201, 409]);
		expect(await Warranty.count({ where: { clientId: raceClientId } })).toBe(1);
		expect(await WarrantyDeletionTombstone.count({ where: { warrantyId: oldId } })).toBe(1);
	});

	it('returns one opaque conflict for every unavailable replacement target without mutation', async () => {
		const replacementClientId = '10000000-0000-0000-0000-000000000034';
		const oldId = '10000000-0000-0000-0000-000000000035';
		const foreignTombstonedTargetId = '20000000-0000-4000-8000-000000000036';
		const foreignLiveTargetId = '20000000-0000-4000-8000-000000000037';
		const ownHistoricalTargetId = '10000000-0000-4000-8000-000000000038';
		const ownActiveTargetId = '10000000-0000-4000-8000-000000000039';
		const raceTargetId = '10000000-0000-4000-8000-000000000090';
		const availableTargetId = '10000000-0000-4000-8000-000000000091';
		const sourceStorageKey = 'replacement-conflict-source.pdf';
		await Client.create({
			id: replacementClientId,
			name: 'Reserved target client',
			franchiseeId: tenantId,
		});
		const old = await createWarranty(oldId, replacementClientId, {
			pdfFileName: sourceStorageKey,
		});
		await Client.create({
			id: '10000000-0000-0000-0000-000000000036',
			name: 'Own active target client',
			franchiseeId: tenantId,
		});
		await Client.create({
			id: '20000000-0000-0000-0000-000000000036',
			name: 'Foreign live target client',
			franchiseeId: otherTenantId,
		});
		await WarrantyDeletionTombstone.create({
			warrantyId: foreignTombstonedTargetId,
			franchiseeId: otherTenantId,
			deletionSequence: '900000',
			deletedAt: new Date('2026-07-30T00:00:00.000Z'),
		});
		await WarrantyDeletionTombstone.create({
			warrantyId: ownHistoricalTargetId,
			franchiseeId: tenantId,
			deletionSequence: '900001',
			deletedAt: new Date('2026-07-30T00:00:00.000Z'),
		});
		await createWarranty(foreignLiveTargetId, '20000000-0000-0000-0000-000000000036');
		await createWarranty(ownActiveTargetId, '10000000-0000-0000-0000-000000000036');

		const upload = (targetWarrantyId: string | undefined, key: string) => {
			let pending = request(app)
				.post('/api/warranty/upload')
				.set('Authorization', `Bearer ${token}`)
				.set('Idempotency-Key', key)
				.field('client_id', replacementClientId)
				.field('start_date', '2026-07-30T00:00:00.000Z')
				.field('duration_years', '5')
				.field('warranty_card_number', 'RESERVED-TARGET')
				.field('confirmed_warranty_id', old.id)
				.field('confirmed_warranty_card_number', old.warrantyCardNumber)
				.field('confirmed_warranty_version', old.version.toString())
				.field(
					'irreversible_confirmation',
					irreversibleWarrantyConfirmation(old.warrantyCardNumber),
				);
			if (targetWarrantyId != null) {
				pending = pending.field('replacement_warranty_id', targetWarrantyId);
			}
			return pending.attach('file', samplePdf, {
				filename: 'reserved-target.pdf',
				contentType: 'application/pdf',
			});
		};

		for (const [targetWarrantyId, key] of [
			[undefined, 'missing-target-key'],
			['', 'empty-target-key'],
			['not-a-uuid', 'malformed-target-key'],
		] as const) {
			const malformed = await upload(targetWarrantyId, key);
			expect(malformed.status).toBe(422);
			expect(malformed.body.code).toBe('confirmation_invalid');
		}

		const collisions = [];
		for (const [targetWarrantyId, key] of [
			[foreignLiveTargetId, 'foreign-live-target-key'],
			[foreignTombstonedTargetId, 'foreign-tombstoned-target-key'],
			[ownHistoricalTargetId, 'own-historical-target-key'],
			[ownActiveTargetId, 'own-active-target-key'],
		]) {
			collisions.push(await upload(targetWarrantyId, key));
		}
		const databaseCollision = Object.assign(new Error('sensitive database uniqueness detail'), {
			name: 'SequelizeUniqueConstraintError',
			original: { code: '23505', constraint: 'sensitive_constraint_name' },
		});
		const create = jest.spyOn(Warranty, 'create').mockRejectedValueOnce(databaseCollision);
		try {
			collisions.push(await upload(raceTargetId, 'database-race-target-key'));
		} finally {
			create.mockRestore();
		}

		const expectedBody = {
			error: warrantyReplacementConflict.message,
			code: warrantyReplacementConflict.code,
		};
		const expectedBytes = JSON.stringify(expectedBody);
		for (const collision of collisions) {
			expect(collision.status).toBe(409);
			expect(collision.body).toEqual(expectedBody);
			expect(collision.text).toBe(expectedBytes);
		}
		expect(await Warranty.findByPk(old.id)).not.toBeNull();
		expect(await WarrantyDeletionTombstone.findByPk(old.id)).toBeNull();
		expect(await ManagedFileCleanup.count({ where: { storageKey: sourceStorageKey } })).toBe(0);
		expect(await Warranty.findByPk(foreignLiveTargetId)).not.toBeNull();
		expect(await Warranty.findByPk(ownActiveTargetId)).not.toBeNull();
		expect(await WarrantyDeletionTombstone.findByPk(foreignTombstonedTargetId)).not.toBeNull();
		expect(await WarrantyDeletionTombstone.findByPk(ownHistoricalTargetId)).not.toBeNull();

		const available = await upload(availableTargetId, 'available-target-key');
		expect(available.status).toBe(201);
		expect(available.body.id).toBe(availableTargetId);
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

	it('rejects a warranty create whose client was deleted earlier in the same batch', async () => {
		const deletedClientId = '10000000-0000-0000-0000-000000000050';
		const attemptedWarrantyId = '10000000-0000-0000-0000-000000000051';
		await Client.create({
			id: deletedClientId,
			name: 'Same-batch deleted client',
			franchiseeId: tenantId,
		});

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
					warranties: [
						{
							remote_id: attemptedWarrantyId,
							client_id: deletedClientId,
							warranty_card_number: 'MUST-NOT-CREATE',
							start_date: '2026-07-30T00:00:00.000Z',
							duration_years: 5,
						},
					],
				},
			});

		expect(response.status).toBe(200);
		expect(response.body.outcomes.clients).toEqual([
			expect.objectContaining({ remote_id: deletedClientId, status: 'applied' }),
		]);
		expect(response.body.outcomes.warranties).toEqual([
			{
				remote_id: attemptedWarrantyId,
				status: 'rejected',
				code: 'warranty_conflict',
			},
		]);
		expect(await Client.findByPk(deletedClientId)).toBeNull();
		expect(await Warranty.findByPk(attemptedWarrantyId, { paranoid: false })).toBeNull();
	});

	it('rejects oversized cursors before committing any mutation', async () => {
		const cursorClientId = '10000000-0000-0000-0000-000000000060';
		const cursorWarrantyId = '10000000-0000-0000-0000-000000000061';
		const cursorClient = await Client.create({
			id: cursorClientId,
			name: 'Cursor unchanged',
			franchiseeId: tenantId,
		});
		const cursorWarranty = await createWarranty(cursorWarrantyId, cursorClientId);

		const response = await request(app)
			.post('/api/sync')
			.set('Authorization', `Bearer ${token}`)
			.send({
				warranty_tombstone_cursor: '9'.repeat(200),
				changes: {
					clients: [
						{
							remote_id: cursorClientId,
							name: 'MUST NOT COMMIT',
						},
					],
					warranties: [
						{
							remote_id: cursorWarrantyId,
							client_id: cursorClientId,
							warranty_card_number: 'MUST-NOT-COMMIT',
							start_date: '2026-07-30T00:00:00.000Z',
							duration_years: 50,
						},
					],
				},
			});

		expect(response.status).toBe(400);
		await cursorClient.reload();
		await cursorWarranty.reload();
		expect(cursorClient.name).toBe('Cursor unchanged');
		expect(cursorWarranty.version).toBe(1);
		expect(cursorWarranty.warrantyCardNumber).not.toBe('MUST-NOT-COMMIT');
	});
});
