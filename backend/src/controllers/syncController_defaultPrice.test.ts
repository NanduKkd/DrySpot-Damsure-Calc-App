import request from 'supertest';
import app from '../app';
import { User, Franchisee, DefaultPrice } from '../models';
import jwt from 'jsonwebtoken';

const JWT_SECRET = process.env.JWT_SECRET || 'your_jwt_secret';

describe('syncController (DefaultPrice)', () => {
  let franchisee: any;
  let user: any;
  let token: string;

  beforeAll(async () => {
    // Setup Franchisee
    franchisee = await Franchisee.create({ id: '00000000-0000-0000-0000-000000000001', name: 'Sync Franchisee' });

    // Setup User
    user = await User.create({ id: '00000000-0000-0000-0000-000000000002', name: 'Sync User', email: 'sync@example.com', password: 'password', franchiseeId: franchisee.id });

    // Generate token
    token = jwt.sign({ id: user.id, franchiseeId: franchisee.id }, JWT_SECRET);
  });

  it('syncs default_prices in push (upload)', async () => {
    const syncData = {
      last_sync_time: null,
      changes: {
        default_prices: [{
          remote_id: '00000000-0000-0000-0000-000000000003',
          price: 12.5,
          enabled: true,
          updated_at: new Date().toISOString()
        }]
      }
    };

    const response = await request(app)
      .post('/api/sync')
      .set('Authorization', `Bearer ${token}`)
      .send(syncData);

    expect(response.status).toBe(200);

    // Verify DB
    const dp = await DefaultPrice.findOne({ where: { id: '00000000-0000-0000-0000-000000000003' } });
    expect(dp).toBeDefined();
    expect(Number(dp?.price)).toBe(12.5);
    expect(dp?.franchiseeId).toBe(franchisee.id);
  });

  it('syncs default_prices in pull (download)', async () => {
    // Create another price directly in DB
    await DefaultPrice.create({
      id: '00000000-0000-0000-0000-000000000004',
      price: 15.0,
      enabled: true,
      franchiseeId: franchisee.id,
      updatedAt: new Date()
    });

    const response = await request(app)
      .post('/api/sync')
      .set('Authorization', `Bearer ${token}`)
      .send({ last_sync_time: null, changes: null });

    expect(response.status).toBe(200);
    expect(response.body.updates.default_prices).toBeDefined();
    const dps = response.body.updates.default_prices;
    expect(dps.some((p: any) => p.remote_id === '00000000-0000-0000-0000-000000000004')).toBe(true);
  });
});
