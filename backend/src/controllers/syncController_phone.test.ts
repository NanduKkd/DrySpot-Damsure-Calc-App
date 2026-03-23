import request from 'supertest';
import app from '../app';
import { User, Franchisee, Client } from '../models';
import jwt from 'jsonwebtoken';

const JWT_SECRET = process.env.JWT_SECRET || 'your_jwt_secret';

describe('syncController - Client Phone', () => {
  let franchisee1: any;
  let user1: any;
  let token1: string;

  beforeAll(async () => {
    // Setup Franchisee
    franchisee1 = await Franchisee.create({ id: 'fp-id', name: 'Franchisee Phone', default_prices: {} });

    // Setup User
    user1 = await User.create({ id: 'up-id', name: 'User Phone', email: 'userphone@example.com', password: 'password', franchiseeId: franchisee1.id });

    // Generate token
    token1 = jwt.sign({ id: user1.id, franchiseeId: franchisee1.id }, JWT_SECRET);
  });

  it('uploads new client with phone and returns it', async () => {
    const syncData = {
      last_sync_time: null,
      changes: {
        clients: [{
          remote_id: 'cp-id',
          name: 'Client Phone',
          phone: '1234567890',
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
    expect(response.body.updates.clients[0].remote_id).toBe('cp-id');
    expect(response.body.updates.clients[0].phone).toBe('1234567890');

    // Verify DB
    const client = await Client.findOne({ where: { id: 'cp-id' } });
    expect(client).toBeDefined();
    expect(client?.phone).toBe('1234567890');
  });

  it('returns updated phone from server', async () => {
    const lastSync = new Date().toISOString();
    await new Promise(resolve => setTimeout(resolve, 100));

    // Manually create a client on the server
    await Client.create({
        id: 'cp2-id',
        franchiseeId: franchisee1.id,
        name: 'Client Server Update',
        phone: '0987654321'
    });

    const response = await request(app)
      .post('/api/sync')
      .set('Authorization', `Bearer ${token1}`)
      .send({ last_sync_time: lastSync, changes: null });

    expect(response.status).toBe(200);
    expect(response.body.updates.clients).toHaveLength(1);
    expect(response.body.updates.clients[0].remote_id).toBe('cp2-id');
    expect(response.body.updates.clients[0].phone).toBe('0987654321');
  });
});
