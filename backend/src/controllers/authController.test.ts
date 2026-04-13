import request from 'supertest';
import app from '../app';
import { User, Franchisee } from '../models';
import bcrypt from 'bcrypt';

describe('authController', () => {
  let franchisee: any;

  beforeAll(async () => {
    franchisee = await Franchisee.create({
      id: 'f1-id',
      name: 'Franchisee 1',
      default_prices: {}
    });
  });

  describe('POST /api/auth/login', () => {
    it('returns 200 and a token on valid login', async () => {
      const password = 'password123';
      const hashedPassword = await bcrypt.hash(password, 10);
      
      await User.create({
        id: 'u1-id',
        name: 'Test User',
        email: 'test@example.com',
        password: hashedPassword,
        franchiseeId: franchisee.id,
      });

      const response = await request(app)
        .post('/api/auth/login')
        .send({ email: 'test@example.com', password: password });

      expect(response.status).toBe(200);
      expect(response.body).toHaveProperty('token');
      expect(response.body.user).toMatchObject({
        email: 'test@example.com',
        franchisee_id: franchisee.id,
        franchisee_name: franchisee.name,
      });
    });

    it('returns 401 on invalid password', async () => {
      const response = await request(app)
        .post('/api/auth/login')
        .send({ email: 'test@example.com', password: 'wrongpassword' });

      expect(response.status).toBe(401);
      expect(response.body).toEqual({ error: 'Invalid email or password' });
    });

    it('returns 401 on user not found', async () => {
      const response = await request(app)
        .post('/api/auth/login')
        .send({ email: 'nonexistent@example.com', password: 'password123' });

      expect(response.status).toBe(401);
      expect(response.body).toEqual({ error: 'Invalid email or password' });
    });
  });
});
