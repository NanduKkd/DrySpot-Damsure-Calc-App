import request from 'supertest';
import app from './app';

describe('app', () => {
  it('responds on the health route', async () => {
    const response = await request(app).get('/health');

    expect(response.status).toBe(200);
    expect(response.body).toEqual({ message: 'API is running' });
  });
});
