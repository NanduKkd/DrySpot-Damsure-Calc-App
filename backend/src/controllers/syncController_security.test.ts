import request from 'supertest';
import jwt from 'jsonwebtoken';
import app from '../app';
import { Client, DefaultPrice, Franchisee, Item, Proposal, Rectangle, User, Warranty } from '../models';

const JWT_SECRET = process.env.JWT_SECRET!;

describe('syncController tenant mutation authorization', () => {
  let token: string;
  const tenantOne = '00000000-0000-0000-0000-000000000101';
  const tenantTwo = '00000000-0000-0000-0000-000000000102';
  const foreignClient = '00000000-0000-0000-0000-000000000201';
  const foreignItem = '00000000-0000-0000-0000-000000000202';
  const foreignRectangle = '00000000-0000-0000-0000-000000000203';
  const foreignWarranty = '00000000-0000-0000-0000-000000000204';
  const foreignProposal = '00000000-0000-0000-0000-000000000205';
  const foreignPrice = '00000000-0000-0000-0000-000000000206';

  beforeAll(async () => {
    await Franchisee.bulkCreate([
      { id: tenantOne, name: 'Tenant one', default_prices: {} },
      { id: tenantTwo, name: 'Tenant two', default_prices: {} },
    ]);
    const user = await User.create({
      id: '00000000-0000-0000-0000-000000000103', name: 'Tenant one user',
      email: 'tenant-one-security@example.com', password: 'unused', franchiseeId: tenantOne,
    });
    token = jwt.sign({ id: user.id, franchiseeId: tenantOne, tokenVersion: 0 }, JWT_SECRET);

    await Client.create({ id: foreignClient, franchiseeId: tenantTwo, name: 'Foreign client' });
    await Item.create({ id: foreignItem, clientId: foreignClient, name: 'Foreign item', price: 1 });
    await Rectangle.create({ id: foreignRectangle, itemId: foreignItem, length: 1, width: 1 });
    await Warranty.create({ id: foreignWarranty, clientId: foreignClient, warrantyCardNumber: 'F-1', startDate: new Date(), durationYears: 1, pdfUrl: 'foreign.pdf' });
    await Proposal.create({ id: foreignProposal, clientId: foreignClient, pdfUrl: 'foreign.pdf' });
    await DefaultPrice.create({ id: foreignPrice, franchiseeId: tenantTwo, price: 1, enabled: true });
  });

  const postChanges = (changes: object) => request(app)
    .post('/api/sync')
    .set('Authorization', `Bearer ${token}`)
    .send({ last_sync_time: null, changes });

  it.each([
    ['clients', { remote_id: foreignClient, name: 'stolen' }, Client, foreignClient],
    ['items', { remote_id: foreignItem, client_id: foreignClient, name: 'stolen', price: 2 }, Item, foreignItem],
    ['rectangles', { remote_id: foreignRectangle, item_id: foreignItem, length: 2, width: 2 }, Rectangle, foreignRectangle],
    ['warranties', { remote_id: foreignWarranty, client_id: foreignClient, warranty_card_number: 'x', start_date: new Date().toISOString(), duration_years: 1, pdf_url: 'x.pdf' }, Warranty, foreignWarranty],
    ['proposals', { remote_id: foreignProposal, client_id: foreignClient, pdf_url: 'x.pdf' }, Proposal, foreignProposal],
    ['default_prices', { remote_id: foreignPrice, price: 2, enabled: true }, DefaultPrice, foreignPrice],
  ])('rejects hostile %s UUID reuse', async (collection, record, Model: any, id) => {
    const response = await postChanges({ [collection]: [record] });
    expect(response.status).toBe(403);
    expect(await Model.findByPk(id, { paranoid: false })).not.toBeNull();
  });

  it.each([
    ['clients', foreignClient, Client],
    ['items', foreignItem, Item],
    ['rectangles', foreignRectangle, Rectangle],
    ['warranties', foreignWarranty, Warranty],
    ['proposals', foreignProposal, Proposal],
    ['default_prices', foreignPrice, DefaultPrice],
  ])('rejects hostile %s deletion', async (collection, id, Model: any) => {
    const response = await postChanges({ [collection]: [{ remote_id: id, deleted_at: new Date().toISOString() }] });
    expect(response.status).toBe(403);
    expect(await Model.findByPk(id)).not.toBeNull();
  });

  it('rejects a new child that points to a foreign parent', async () => {
    const response = await postChanges({
      items: [{ remote_id: '00000000-0000-0000-0000-000000000207', client_id: foreignClient, name: 'injected', price: 1 }],
    });
    expect(response.status).toBe(403);
    expect(await Item.findByPk('00000000-0000-0000-0000-000000000207')).toBeNull();
  });
});
