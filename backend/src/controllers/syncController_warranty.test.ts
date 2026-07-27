import request from 'supertest';
import jwt from 'jsonwebtoken';
import fs from 'fs';
import path from 'path';
import app from '../app';
import { Client, Franchisee, Proposal, User, Warranty } from '../models';
import * as uploadMiddleware from '../middleware/uploadMiddleware';

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
  let token: string;

  beforeAll(async () => {
    await Franchisee.create({ id: franchiseeId, name: 'Warranty sync tenant', default_prices: {} });
    const user = await User.create({
      id: '00000000-0000-0000-0000-000000000306', name: 'Warranty sync user',
      email: 'warranty-sync@example.com', password: 'unused', franchiseeId,
    });
    await Client.create({ id: clientId, franchiseeId, name: 'Warranty client' });
    token = jwt.sign({ id: user.id, franchiseeId, tokenVersion: 0 }, JWT_SECRET);
  });

  const sync = (changes: object) => request(app)
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

  it('rejects an offline active-warranty conflict without partial writes', async () => {
    const response = await sync({ warranties: [warranty(replacementWarrantyId)] });
    expect(response.status).toBe(409);
    expect(await Warranty.findByPk(replacementWarrantyId, { paranoid: false })).toBeNull();
    expect((await Warranty.findByPk(firstWarrantyId))?.activeClientId).toBe(clientId);
  });

  it('only replaces an active warranty when explicitly requested', async () => {
    const response = await sync({ warranties: [warranty(replacementWarrantyId, { replace_existing: true })] });
    expect(response.status).toBe(200);
    expect(await Warranty.findByPk(firstWarrantyId)).toBeNull();
    expect((await Warranty.findByPk(firstWarrantyId, { paranoid: false }))?.activeClientId).toBeNull();
    expect((await Warranty.findByPk(replacementWarrantyId))?.activeClientId).toBe(clientId);
  });

  it('does not allow synced proposal metadata to select a stored PDF', async () => {
    const response = await sync({ proposals: [{
      remote_id: proposalId, client_id: clientId,
      pdf_url: 'https://attacker.invalid/api/proposal/foreign/download',
      pdf_file_name: '../foreign-tenant.pdf',
    }] });
    expect(response.status).toBe(200);
    const stored = await Proposal.findByPk(proposalId);
    expect(stored?.pdfFileName).toBeNull();
    expect(stored?.pdfUrl).toContain(`/api/proposal/${proposalId}/download`);
    expect(stored?.pdfUrl).not.toContain('attacker.invalid');
    expect(stored?.pdfUrl).toMatch(/^\/api\/proposal\/[0-9a-f-]+\/download$/);
  });

  it('cleans only trusted server PDF filenames after sync deletion commits', async () => {
    await Client.create({ id: fileClientId, franchiseeId, name: 'File lifecycle client' });
    await Warranty.create({
      id: fileWarrantyId, clientId: fileClientId, activeClientId: fileClientId,
      warrantyCardNumber: 'file-card', startDate: new Date(), durationYears: 1,
      pdfUrl: 'http://localhost/api/warranty/file/download', pdfFileName: 'server-owned.pdf',
    });
    await Proposal.create({
      id: fileProposalId, clientId: fileClientId,
      pdfUrl: 'http://localhost/api/proposal/file/download', pdfFileName: 'proposal-owned.pdf',
    });
    const removal = jest.spyOn(uploadMiddleware, 'removeStoredPdf').mockResolvedValue();

    const response = await sync({
      warranties: [{ remote_id: fileWarrantyId, deleted_at: new Date().toISOString() }],
      proposals: [{ remote_id: fileProposalId, deleted_at: new Date().toISOString() }],
    });

    expect(response.status).toBe(200);
    expect(removal).toHaveBeenCalledWith('', 'server-owned.pdf');
    expect(removal).toHaveBeenCalledWith('', 'proposal-owned.pdf');
    expect((await Warranty.findByPk(fileWarrantyId, { paranoid: false }))?.activeClientId).toBeNull();
    removal.mockRestore();
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
    await Client.create({ id: deletedClientId, franchiseeId, name: 'Tombstoned client', photos: JSON.stringify([photoUrl]) });
    await Warranty.create({
      id: deletedWarrantyId, clientId: deletedClientId, activeClientId: deletedClientId,
      warrantyCardNumber: 'tombstone-card', startDate: new Date(), durationYears: 1,
      pdfUrl: 'http://localhost/api/warranty/tombstone/download', pdfFileName: warrantyFilename,
    });
    await Proposal.create({
      id: deletedProposalId, clientId: deletedClientId,
      pdfUrl: 'http://localhost/api/proposal/tombstone/download', pdfFileName: proposalFilename,
    });
    await Franchisee.create({ id: foreignFranchiseeId, name: 'Foreign tombstone tenant', default_prices: {} });
    await Client.create({ id: foreignClientId, franchiseeId: foreignFranchiseeId, name: 'Foreign client' });
    await Warranty.create({
      id: foreignWarrantyId, clientId: foreignClientId, activeClientId: foreignClientId,
      warrantyCardNumber: 'foreign-card', startDate: new Date(), durationYears: 1,
      pdfUrl: 'http://localhost/api/warranty/foreign/download', pdfFileName: foreignFilename,
    });

    const response = await sync({ clients: [{ remote_id: deletedClientId, deleted_at: new Date().toISOString() }] });
    expect(response.status).toBe(200);
    expect(await Client.findByPk(deletedClientId)).toBeNull();
    expect(await Warranty.findByPk(deletedWarrantyId)).toBeNull();
    expect(await Proposal.findByPk(deletedProposalId)).toBeNull();
    expect((await Warranty.findByPk(deletedWarrantyId, { paranoid: false }))?.activeClientId).toBeNull();
    expect(fs.existsSync(path.join(uploadsDirectory, photoFilename))).toBe(false);
    expect(fs.existsSync(path.join(uploadsDirectory, warrantyFilename))).toBe(false);
    expect(fs.existsSync(path.join(uploadsDirectory, proposalFilename))).toBe(false);
    expect(fs.existsSync(path.join(uploadsDirectory, foreignFilename))).toBe(true);
    expect(await Warranty.findByPk(foreignWarrantyId)).not.toBeNull();
    fs.unlinkSync(path.join(uploadsDirectory, foreignFilename));
  });
});
