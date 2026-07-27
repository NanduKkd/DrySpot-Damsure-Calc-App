const authenticate = jest.fn();
const listen = jest.fn();

jest.mock('./models', () => ({ sequelize: { authenticate } }));
jest.mock('./app', () => ({ __esModule: true, default: { listen } }));

import { startServer } from './server';

describe('startServer', () => {
  beforeEach(() => {
    authenticate.mockReset().mockResolvedValue(undefined);
    listen.mockReset().mockImplementation((_port: number, _host: string, ready: () => void) => {
      ready();
      return { close: jest.fn() };
    });
  });

  it('authenticates the database before binding the HTTP listener', async () => {
    await startServer();
    expect(authenticate).toHaveBeenCalled();
    expect(listen).toHaveBeenCalledTimes(1);
  });

  it('does not bind the HTTP listener when database authentication fails', async () => {
    authenticate.mockRejectedValueOnce(new Error('database unavailable'));
    await expect(startServer()).rejects.toThrow('database unavailable');
    expect(listen).not.toHaveBeenCalled();
  });
});
