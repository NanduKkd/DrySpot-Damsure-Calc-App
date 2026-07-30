import request from 'supertest';
import jwt from 'jsonwebtoken';
import fs from 'fs';
import path from 'path';
import app from '../app';
import { Client, Franchisee, ManagedFileCleanup, User } from '../models';

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
      User.create({ id: '00000000-0000-0000-0000-000000000404', name: 'Photo owner', email: 'photo-owner@example.com', password: 'unused', franchiseeId: firstFranchisee }),
      User.create({ id: '00000000-0000-0000-0000-000000000405', name: 'Photo intruder', email: 'photo-intruder@example.com', password: 'unused', franchiseeId: secondFranchisee }),
    ]);
    await Client.create({ id: clientId, franchiseeId: firstFranchisee, name: 'Photo client' });
    ownerToken = jwt.sign({ id: owner.id, franchiseeId: firstFranchisee, tokenVersion: 0 }, JWT_SECRET);
    otherToken = jwt.sign({ id: other.id, franchiseeId: secondFranchisee, tokenVersion: 0 }, JWT_SECRET);
  });

  const upload = (token: string, body: Buffer, filename: string) => request(app)
    .post(`/api/photos/client/${clientId}`)
    .set('Authorization', `Bearer ${token}`)
    .attach('file', body, { filename, contentType: 'image/jpeg' });

  it('stores an opaque canonical photo URL and serves it only to the owner tenant', async () => {
    const response = await upload(ownerToken, Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00]), 'camera.jpg');
    expect(response.status).toBe(201);
    expect(response.body.url).toMatch(new RegExp(`^/api/photos/client/${clientId}/[0-9a-f-]{36}\\.jpg$`));
    expect(response.body.url).not.toContain('camera');

    const download = await request(app).get(response.body.url).set('Authorization', `Bearer ${ownerToken}`);
    expect(download.status).toBe(200);
    expect(download.headers['content-type']).toMatch(/image\/jpeg/);
    expect((await request(app).get(response.body.url).set('Authorization', `Bearer ${otherToken}`)).status).toBe(404);
  });

  it('rejects spoofed image contents and does not leave a stored upload', async () => {
    const before = fs.existsSync(uploadsDirectory) ? fs.readdirSync(uploadsDirectory).length : 0;
    const response = await upload(ownerToken, Buffer.from('not an image'), 'spoofed.jpg');
    expect(response.status).toBe(400);
    const after = fs.existsSync(uploadsDirectory) ? fs.readdirSync(uploadsDirectory).length : 0;
    expect(after).toBe(before);
  });

  it('returns image-specific errors for invalid extensions and oversized multipart files', async () => {
    const invalidExtension = await upload(ownerToken, Buffer.from([0xff, 0xd8, 0xff]), 'photo.gif');
    expect(invalidExtension.status).toBe(400);
    expect(invalidExtension.body).toEqual({ error: 'Only JPEG, PNG, and WebP images are allowed' });

    const oversized = await upload(ownerToken, Buffer.alloc(10 * 1024 * 1024 + 1, 0xff), 'large.jpg');
    expect(oversized.status).toBe(400);
    expect(oversized.body).toEqual({ error: 'Image file size must be 10MB or less' });
  });

  it('rejects forged/traversal URL access and removes metadata plus file on deletion', async () => {
    const response = await upload(ownerToken, Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), 'camera.png');
    const url = response.body.url as string;
    const filename = url.split('/').at(-1)!;
    expect(await request(app)
      .get(`/api/photos/client/${clientId}/00000000-0000-0000-0000-000000000000.jpg`)
      .set('Authorization', `Bearer ${ownerToken}`)).toHaveProperty('status', 404);

    expect(await request(app).delete(url).set('Authorization', `Bearer ${ownerToken}`)).toHaveProperty('status', 204);
    expect(fs.existsSync(path.join(uploadsDirectory, filename))).toBe(false);
    expect(JSON.parse((await Client.findByPk(clientId))!.photos)).not.toContain(url);
  });

  it('returns success after metadata commits even if physical cleanup fails', async () => {
    const response = await upload(ownerToken, Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), 'cleanup.png');
    const url = response.body.url as string;
    const unlink = jest.spyOn(fs.promises, 'unlink').mockRejectedValueOnce(new Error('disk unavailable'));
    const errorLog = jest.spyOn(console, 'error').mockImplementation();

    expect(await request(app).delete(url).set('Authorization', `Bearer ${ownerToken}`)).toHaveProperty('status', 204);
    expect(JSON.parse((await Client.findByPk(clientId))!.photos)).not.toContain(url);
    expect(unlink).toHaveBeenCalled();
    expect(errorLog).toHaveBeenCalled();
    const cleanup = await ManagedFileCleanup.findOne({ where: { storageKey: url.split('/').at(-1) } });
    expect(cleanup?.attempts).toBe(1);
    expect(cleanup?.exhaustedAt).toBeNull();
  });

  it('sync cannot add forged canonical URLs and removes server photos it drops', async () => {
    const syncClientId = '00000000-0000-0000-0000-000000000406';
    const canonical = `/api/photos/client/${syncClientId}/00000000-0000-0000-0000-000000000407.webp`;
    const removed = `/api/photos/client/${syncClientId}/00000000-0000-0000-0000-000000000408.jpg`;
    const forged = `/api/photos/client/${syncClientId}/00000000-0000-0000-0000-000000000409.png`;
    await Client.create({ id: syncClientId, franchiseeId: firstFranchisee, name: 'Server photo client', photos: JSON.stringify([canonical, removed]) });
    fs.mkdirSync(uploadsDirectory, { recursive: true });
    fs.writeFileSync(path.join(uploadsDirectory, '00000000-0000-0000-0000-000000000408.jpg'), Buffer.from([0xff, 0xd8, 0xff]));
    const response = await request(app).post('/api/sync').set('Authorization', `Bearer ${ownerToken}`).send({
      last_sync_time: null,
      changes: { clients: [{
        remote_id: syncClientId, name: 'Synced photo client',
        photos: [canonical, forged, 'file:///private/image.jpg', '/uploads/not-opaque.jpg', 'https://attacker.invalid/photo.jpg'],
      }] },
    });
    expect(response.status).toBe(200);
    const stored = await Client.findByPk(syncClientId);
    expect(stored?.photos).toBe(JSON.stringify([canonical]));
    expect(fs.existsSync(path.join(uploadsDirectory, '00000000-0000-0000-0000-000000000408.jpg'))).toBe(false);
    const update = response.body.updates.clients.find((client: any) => client.remote_id === stored?.id);
    expect(update.photos).toBe(JSON.stringify([canonical]));
  });
});
