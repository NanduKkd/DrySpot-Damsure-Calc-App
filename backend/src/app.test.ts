import request from 'supertest';
import app from './app';

describe('app', () => {
  it('responds on the health route', async () => {
    const response = await request(app).get('/health');

    expect(response.status).toBe(200);
    expect(response.body).toEqual({ message: 'API is running' });
  });

  it('returns 413 for oversized sync payloads', async () => {
    const response = await request(app)
      .post('/api/sync')
      .set('Content-Type', 'application/json')
      .send({ image_data: 'a'.repeat(21 * 1024 * 1024) });

    expect(response.status).toBe(413);
    expect(response.body.error).toBe(
      'Sync payload too large. Please sync fewer or smaller images.',
    );
  }, 15000);
});
