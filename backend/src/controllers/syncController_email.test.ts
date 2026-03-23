import request from 'supertest';
import app from '../app';
import { User, Franchisee, Client } from '../models';
import jwt from 'jsonwebtoken';

const JWT_SECRET = process.env.JWT_SECRET || 'your_jwt_secret';

describe('syncController - Email Validation Bug', () => {
  let franchisee: any;
  let user: any;
  let token: string;

  beforeAll(async () => {
    franchisee = await Franchisee.create({ id: 'f-email-id', name: 'Franchisee Email Test', default_prices: {} });
    user = await User.create({ id: 'u-email-id', name: 'User Email Test', email: 'user_email@example.com', password: 'password', franchiseeId: franchisee.id });
    token = jwt.sign({ id: user.id, franchiseeId: franchisee.id }, JWT_SECRET);
  });

  afterAll(async () => {
    // Cleanup
    await Client.destroy({ where: { franchiseeId: franchisee.id } });
    await User.destroy({ where: { id: user.id } });
    await Franchisee.destroy({ where: { id: franchisee.id } });
  });

  describe('POST /api/sync with empty email', () => {
    it('should accept a client with an empty email address without throwing SequelizeValidationError', async () => {
      const syncData = {
        last_sync_time: null,
        changes: {
          clients: [{
            remote_id: 'c-empty-email',
            name: 'Client with Empty Email',
            address: 'Address',
            email: '', // Empty email triggering the bug
            phone: '1234567890',
            is_dirty: true,
            updated_at: new Date().toISOString()
          }]
        }
      };

      const response = await request(app)
        .post('/api/sync')
        .set('Authorization', `Bearer ${token}`)
        .send(syncData);

      expect(response.status).toBe(200);
      expect(response.body.updates.clients).toHaveLength(1);
      
      const client = await Client.findOne({ where: { id: 'c-empty-email' } });
      expect(client).toBeDefined();
      expect(client?.email).toBe(null); // converted to null by setter
    });
  });
});
