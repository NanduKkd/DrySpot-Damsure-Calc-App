import request from 'supertest';
import jwt from 'jsonwebtoken';
import fs from 'fs';
import path from 'path';
import { createHash, randomUUID } from 'crypto';
import app from '../app';
import {
	Client,
	ClientPhotoUpload,
	Franchisee,
	ManagedFileCleanup,
	TenantSyncState,
	User,
} from '../models';
import {
	finalizeClientPhotoUploadReceipt,
	reconcileStagedClientPhotoUploads,
} from '../services/clientPhotoUploadReceipt';
import { photoUploadStagingPath, stagedPhotoPath } from '../middleware/photoUploadMiddleware';

const JWT_SECRET = process.env.JWT_SECRET!;
const uploadsDirectory = path.join(__dirname, '../../uploads');

describe('client photo storage', () => {
	const firstFranchisee = '00000000-0000-0000-0000-000000000401';
	const secondFranchisee = '00000000-0000-0000-0000-000000000402';
	const clientId = '00000000-0000-0000-0000-000000000403';
	let ownerToken: string;
	let otherToken: string;

	beforeAll(async () => {
		await Franchisee.bulkCreate([
			{ id: firstFranchisee, name: 'Photo owner', default_prices: {} },
			{ id: secondFranchisee, name: 'Photo intruder', default_prices: {} },
		]);
		const [owner, other] = await Promise.all([
			User.create({
				id: '00000000-0000-0000-0000-000000000404',
				name: 'Photo owner',
				email: 'photo-owner@example.com',
				password: 'unused',
				franchiseeId: firstFranchisee,
			}),
			User.create({
				id: '00000000-0000-0000-0000-000000000405',
				name: 'Photo intruder',
				email: 'photo-intruder@example.com',
				password: 'unused',
				franchiseeId: secondFranchisee,
			}),
		]);
		await Client.create({ id: clientId, franchiseeId: firstFranchisee, name: 'Photo client' });
		ownerToken = jwt.sign(
			{ id: owner.id, franchiseeId: firstFranchisee, tokenVersion: 0 },
			JWT_SECRET,
		);
		otherToken = jwt.sign(
			{ id: other.id, franchiseeId: secondFranchisee, tokenVersion: 0 },
			JWT_SECRET,
		);
	});

	const upload = (
		token: string,
		body: Buffer,
		filename: string,
		uploadId = randomUUID(),
		targetClientId = clientId,
	) =>
		request(app)
			.post(`/api/photos/client/${targetClientId}`)
			.set('Authorization', `Bearer ${token}`)
			.set('Idempotency-Key', uploadId)
			.set('X-Photo-SHA256', createHash('sha256').update(body).digest('hex'))
			.attach('file', body, { filename, contentType: 'image/jpeg' });

	const uploadLegacy = (token: string, body: Buffer, filename: string) =>
		request(app)
			.post(`/api/photos/client/${clientId}`)
			.set('Authorization', `Bearer ${token}`)
			.attach('file', body, { filename, contentType: 'image/jpeg' });

	it('stores an opaque canonical photo URL and serves it only to the owner tenant', async () => {
		const response = await upload(
			ownerToken,
			Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00]),
			'camera.jpg',
		);
		expect(response.status).toBe(201);
		expect(response.body.url).toMatch(
			new RegExp(`^/api/photos/client/${clientId}/[0-9a-f-]{36}\\.jpg$`),
		);
		expect(response.body.url).not.toContain('camera');

		const download = await request(app)
			.get(response.body.url)
			.set('Authorization', `Bearer ${ownerToken}`);
		expect(download.status).toBe(200);
		expect(download.headers['content-type']).toMatch(/image\/jpeg/);
		expect(
			(await request(app).get(response.body.url).set('Authorization', `Bearer ${otherToken}`))
				.status,
		).toBe(404);
	});

	it('keeps the deployed headerless upload contract while requiring a digest for receipt uploads', async () => {
		const body = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00]);
		const legacy = await uploadLegacy(ownerToken, body, 'older-client.jpg');
		expect(legacy.status).toBe(201);
		expect(legacy.body.url).toMatch(
			new RegExp(`^/api/photos/client/${clientId}/[0-9a-f-]{36}\\.jpg$`),
		);
		expect(
			await ClientPhotoUpload.count({ where: { canonicalUrl: legacy.body.url } }),
		).toBe(0);
		expect(
			(
				await request(app)
					.get(legacy.body.url)
					.set('Authorization', `Bearer ${ownerToken}`)
			).status,
		).toBe(200);

		const claimedWithoutDigest = await request(app)
			.post(`/api/photos/client/${clientId}`)
			.set('Authorization', `Bearer ${ownerToken}`)
			.set('Idempotency-Key', randomUUID())
			.attach('file', body, { filename: 'claimed-operation.jpg', contentType: 'image/jpeg' });
		expect(claimedWithoutDigest.status).toBe(400);
		expect(claimedWithoutDigest.body.error.code).toBe('invalid_photo_digest');
	});

	it('replays one logical upload after an ambiguous response without duplicate media', async () => {
		const body = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00]);
		const uploadId = randomUUID();
		const first = await upload(ownerToken, body, 'ambiguous.jpg', uploadId);
		const filesBeforeReplay = fs.readdirSync(photoUploadStagingPath).length;
		const replay = await upload(ownerToken, body, 'ambiguous.jpg', uploadId);

		expect(first.status).toBe(201);
		expect(replay.status).toBe(201);
		expect(replay.body).toEqual({
			url: first.body.url,
			response_cursor: first.body.response_cursor,
		});
		expect(fs.readdirSync(photoUploadStagingPath).length).toBe(filesBeforeReplay);
		expect(
			await ClientPhotoUpload.count({ where: { franchiseeId: firstFranchisee, uploadId } }),
		).toBe(1);
		expect(
			JSON.parse((await Client.findByPk(clientId))!.photos).filter(
				(photo: string) => photo === first.body.url,
			),
		).toHaveLength(1);
	});

	it('serializes same-key concurrent uploads into one receipt and canonical asset', async () => {
		const body = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00]);
		const uploadId = randomUUID();
		const [first, second] = await Promise.all([
			upload(ownerToken, body, 'concurrent.jpg', uploadId),
			upload(ownerToken, body, 'concurrent.jpg', uploadId),
		]);
		expect([first.status, second.status]).toEqual([201, 201]);
		expect(first.body.url).toBe(second.body.url);
		expect(
			await ClientPhotoUpload.count({ where: { franchiseeId: firstFranchisee, uploadId } }),
		).toBe(1);
	});

	it('rejects a same-key binding conflict and isolates equal keys by tenant', async () => {
		const uploadId = randomUUID();
		const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00]);
		const png = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
		expect((await upload(ownerToken, jpeg, 'bound.jpg', uploadId)).status).toBe(201);
		const conflict = await upload(ownerToken, png, 'bound.png', uploadId);
		expect(conflict.status).toBe(409);
		expect(conflict.body).toEqual({
			error: {
				code: 'idempotency_conflict',
				message: 'This upload id is already bound to different photo data.',
			},
		});

		const otherClientId = randomUUID();
		await Client.create({
			id: otherClientId,
			franchiseeId: secondFranchisee,
			name: 'Other tenant photo client',
		});
		expect((await upload(otherToken, jpeg, 'other.jpg', uploadId, otherClientId)).status).toBe(
			201,
		);
		expect(await ClientPhotoUpload.count({ where: { uploadId } })).toBe(2);
	});

	it('recovers a committed staged receipt at startup and age-removes only an unclaimed staging file', async () => {
		const filename = `${randomUUID()}.jpg`;
		const canonical = `/api/photos/client/${clientId}/${filename}`;
		await fs.promises.mkdir(photoUploadStagingPath, { recursive: true });
		await fs.promises.writeFile(
			stagedPhotoPath(filename),
			Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00]),
		);
		const uploadId = randomUUID();
		await (await Client.findByPk(clientId))!.update({
			photos: JSON.stringify([canonical]),
		});
		await ClientPhotoUpload.create({
			franchiseeId: firstFranchisee,
			uploadId,
			clientId,
			fileSha256: createHash('sha256')
				.update(Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00]))
				.digest('hex'),
			canonicalUrl: canonical,
			storageKey: filename,
			responseCursor: '700',
			status: 'staged',
		});
		const orphan = `${randomUUID()}.jpg`;
		await fs.promises.writeFile(stagedPhotoPath(orphan), Buffer.from([0xff, 0xd8, 0xff]));
		const old = new Date(Date.now() - 1000);
		await fs.promises.utimes(stagedPhotoPath(orphan), old, old);

		await reconcileStagedClientPhotoUploads({ minimumAgeMs: 0 });

		expect(fs.existsSync(path.join(uploadsDirectory, filename))).toBe(true);
		expect(fs.existsSync(stagedPhotoPath(orphan))).toBe(false);
		expect(
			(
				await ClientPhotoUpload.findOne({
					where: { franchiseeId: firstFranchisee, uploadId },
				})
			)?.status,
		).toBe('completed');
	});

	it('compensates a missing committed stage without removing unrelated photos, then replays terminal 410', async () => {
		const body = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00]);
		const uploadId = randomUUID();
		const missingFilename = `${randomUUID()}.jpg`;
		const unrelated = `/api/photos/client/${clientId}/${randomUUID()}.jpg`;
		const missing = `/api/photos/client/${clientId}/${missingFilename}`;
		await TenantSyncState.upsert({ franchiseeId: firstFranchisee, cursor: '800' });
		await (await Client.findByPk(clientId))!.update({
			photos: JSON.stringify([unrelated, missing]),
			syncCursor: '800',
		});
		await ClientPhotoUpload.create({
			franchiseeId: firstFranchisee,
			uploadId,
			clientId,
			fileSha256: createHash('sha256').update(body).digest('hex'),
			canonicalUrl: missing,
			storageKey: missingFilename,
			responseCursor: '800',
			status: 'staged',
		});

		await reconcileStagedClientPhotoUploads({ minimumAgeMs: 0 });

		const client = await Client.findByPk(clientId);
		expect(JSON.parse(client!.photos)).toEqual(expect.arrayContaining([unrelated]));
		expect(JSON.parse(client!.photos)).not.toContain(missing);
		expect(String(client!.syncCursor)).toBe('801');
		expect(String((await TenantSyncState.findByPk(firstFranchisee))!.cursor)).toBe('801');
		expect(
			(
				await ClientPhotoUpload.findOne({
					where: { franchiseeId: firstFranchisee, uploadId },
				})
			)?.status,
		).toBe('deleted');
		const replay = await upload(ownerToken, body, 'missing.jpg', uploadId);
		expect(replay.status).toBe(410);
		expect(replay.body.error.code).toBe('uploaded_asset_deleted');
	});

	it('rejects spoofed image contents and does not leave a stored upload', async () => {
		const before = fs.existsSync(uploadsDirectory)
			? fs.readdirSync(uploadsDirectory).length
			: 0;
		const response = await upload(ownerToken, Buffer.from('not an image'), 'spoofed.jpg');
		expect(response.status).toBe(400);
		const after = fs.existsSync(uploadsDirectory) ? fs.readdirSync(uploadsDirectory).length : 0;
		expect(after).toBe(before);
	});

	it('returns image-specific errors for invalid extensions and oversized multipart files', async () => {
		const invalidExtension = await upload(
			ownerToken,
			Buffer.from([0xff, 0xd8, 0xff]),
			'photo.gif',
		);
		expect(invalidExtension.status).toBe(400);
		expect(invalidExtension.body).toEqual({
			error: 'Only JPEG, PNG, and WebP images are allowed',
		});

		const oversized = await upload(
			ownerToken,
			Buffer.alloc(10 * 1024 * 1024 + 1, 0xff),
			'large.jpg',
		);
		expect(oversized.status).toBe(400);
		expect(oversized.body).toEqual({ error: 'Image file size must be 10MB or less' });
	});

	it('rejects forged/traversal URL access and removes metadata plus file on deletion', async () => {
		const body = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
		const uploadId = randomUUID();
		const response = await upload(ownerToken, body, 'camera.png', uploadId);
		const url = response.body.url as string;
		const filename = url.split('/').at(-1)!;
		expect(
			await request(app)
				.get(`/api/photos/client/${clientId}/00000000-0000-0000-0000-000000000000.jpg`)
				.set('Authorization', `Bearer ${ownerToken}`),
		).toHaveProperty('status', 404);

		expect(
			await request(app).delete(url).set('Authorization', `Bearer ${ownerToken}`),
		).toHaveProperty('status', 204);
		expect(fs.existsSync(path.join(uploadsDirectory, filename))).toBe(false);
		expect(JSON.parse((await Client.findByPk(clientId))!.photos)).not.toContain(url);
		const replay = await upload(ownerToken, body, 'camera.png', uploadId);
		expect(replay.status).toBe(410);
		expect(replay.body.error.code).toBe('uploaded_asset_deleted');
	});

	it('makes a terminal media deletion win over a stale receipt finalizer', async () => {
		const body = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00]);
		const uploadId = randomUUID();
		const created = await upload(ownerToken, body, 'delete-wins.jpg', uploadId);
		expect(created.status).toBe(201);
		const staleReceipt = (await ClientPhotoUpload.findOne({
			where: { franchiseeId: firstFranchisee, uploadId },
		}))!;
		// Model a finalizer that read a staged instance just before a concurrent
		// media deletion. The finalizer must freshly lock and re-read it.
		await staleReceipt.update({ status: 'staged' });
		await request(app).delete(created.body.url).set('Authorization', `Bearer ${ownerToken}`);

		expect(await finalizeClientPhotoUploadReceipt(staleReceipt)).toBe('deleted');
		const receipt = await ClientPhotoUpload.findOne({
			where: { franchiseeId: firstFranchisee, uploadId },
		});
		expect(receipt?.status).toBe('deleted');
		expect(JSON.parse((await Client.findByPk(clientId))!.photos)).not.toContain(created.body.url);
		const replay = await upload(ownerToken, body, 'delete-wins.jpg', uploadId);
		expect(replay.status).toBe(410);
		expect(replay.body.error.code).toBe('uploaded_asset_deleted');
	});

	it('returns success after metadata commits even if physical cleanup fails', async () => {
		const response = await upload(
			ownerToken,
			Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
			'cleanup.png',
		);
		const url = response.body.url as string;
		const unlink = jest
			.spyOn(fs.promises, 'unlink')
			.mockRejectedValueOnce(new Error('disk unavailable'));
		const errorLog = jest.spyOn(console, 'error').mockImplementation();

		expect(
			await request(app).delete(url).set('Authorization', `Bearer ${ownerToken}`),
		).toHaveProperty('status', 204);
		expect(JSON.parse((await Client.findByPk(clientId))!.photos)).not.toContain(url);
		expect(unlink).toHaveBeenCalled();
		expect(errorLog).toHaveBeenCalled();
		const cleanup = await ManagedFileCleanup.findOne({
			where: { storageKey: url.split('/').at(-1) },
		});
		expect(cleanup?.attempts).toBe(1);
		expect(cleanup?.exhaustedAt).toBeNull();
	});

	it('sync cannot add forged canonical URLs and removes server photos it drops', async () => {
		const syncClientId = '00000000-0000-0000-0000-000000000406';
		const canonical = `/api/photos/client/${syncClientId}/00000000-0000-0000-0000-000000000407.webp`;
		const removed = `/api/photos/client/${syncClientId}/00000000-0000-0000-0000-000000000408.jpg`;
		const forged = `/api/photos/client/${syncClientId}/00000000-0000-0000-0000-000000000409.png`;
		await Client.create({
			id: syncClientId,
			franchiseeId: firstFranchisee,
			name: 'Server photo client',
			photos: JSON.stringify([canonical, removed]),
		});
		fs.mkdirSync(uploadsDirectory, { recursive: true });
		const removalBody = Buffer.from([0xff, 0xd8, 0xff]);
		fs.writeFileSync(
			path.join(uploadsDirectory, '00000000-0000-0000-0000-000000000408.jpg'),
			removalBody,
		);
		const removalUploadId = randomUUID();
		await ClientPhotoUpload.create({
			franchiseeId: firstFranchisee,
			uploadId: removalUploadId,
			clientId: syncClientId,
			fileSha256: createHash('sha256').update(removalBody).digest('hex'),
			canonicalUrl: removed,
			storageKey: '00000000-0000-0000-0000-000000000408.jpg',
			responseCursor: '1',
			status: 'completed',
		});
		const response = await request(app)
			.post('/api/sync')
			.set('Authorization', `Bearer ${ownerToken}`)
			.send({
				last_sync_time: null,
				changes: {
					clients: [
						{
							remote_id: syncClientId,
							name: 'Synced photo client',
							photos: [
								canonical,
								forged,
								'file:///private/image.jpg',
								'/uploads/not-opaque.jpg',
								'https://attacker.invalid/photo.jpg',
							],
						},
					],
				},
			});
		expect(response.status).toBe(200);
		const stored = await Client.findByPk(syncClientId);
		expect(stored?.photos).toBe(JSON.stringify([canonical]));
		expect(
			fs.existsSync(path.join(uploadsDirectory, '00000000-0000-0000-0000-000000000408.jpg')),
		).toBe(false);
		expect(
			(
				await ClientPhotoUpload.findOne({
					where: { franchiseeId: firstFranchisee, uploadId: removalUploadId },
				})
			)?.status,
		).toBe('deleted');
		const replay = await upload(
			ownerToken,
			removalBody,
			'removed.jpg',
			removalUploadId,
			syncClientId,
		);
		expect(replay.status).toBe(410);
		expect(replay.body.error.code).toBe('uploaded_asset_deleted');
		const update = response.body.updates.clients.find(
			(client: any) => client.remote_id === stored?.id,
		);
		expect(update.photos).toBe(JSON.stringify([canonical]));
	});
});
