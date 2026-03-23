import request from 'supertest';
import app from '../app';
import { User, Franchisee, Client } from '../models';
import jwt from 'jsonwebtoken';

const JWT_SECRET = process.env.JWT_SECRET || 'your_jwt_secret';

describe('syncController - Client Discount', () => {
  let franchisee1: any;
  let user1: any;
  let token1: string;

  beforeAll(async () => {
    // Setup Franchisee
    franchisee1 = await Franchisee.create({ id: 'fd-id', name: 'Franchisee Discount', default_prices: {} });

    // Setup User
    user1 = await User.create({ id: 'ud-id', name: 'User Discount', email: 'userdiscount@example.com', password: 'password', franchiseeId: franchisee1.id });

    // Generate token
    token1 = jwt.sign({ id: user1.id, franchiseeId: franchisee1.id }, JWT_SECRET);
  });

  it('uploads new client with discountedPrice and returns it', async () => {
    const syncData = {
      last_sync_time: null,
      changes: {
        clients: [{
          remote_id: 'cd-id',
          name: 'Client Discount',
          discounted_price: 1500.50,
          is_dirty: true,
          updated_at: new Date().toISOString()
        }]
      }
    };

    const response = await request(app)
      .post('/api/sync')
      .set('Authorization', `Bearer ${token1}`)
      .send(syncData);

    expect(response.status).toBe(200);
    expect(response.body.updates.clients).toHaveLength(1);
    expect(response.body.updates.clients[0].remote_id).toBe('cd-id');
    expect(response.body.updates.clients[0].discounted_price).toBe(1500.50);

    // Verify DB
    const client = await Client.findOne({ where: { id: 'cd-id' } });
    expect(client).toBeDefined();
    expect((client as any).discountedPrice).toBe(1500.50);
  });
});
