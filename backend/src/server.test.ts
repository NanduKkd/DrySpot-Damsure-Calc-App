const authenticate = jest.fn();
const listen = jest.fn();
const reconcileStagedClientPhotoUploads = jest.fn();

jest.mock('./models', () => ({ sequelize: { authenticate } }));
jest.mock('./app', () => ({ __esModule: true, default: { listen } }));
jest.mock('./services/clientPhotoUploadReceipt', () => ({ reconcileStagedClientPhotoUploads }));

import { startServer } from './server';

describe('startServer', () => {
	beforeEach(() => {
		authenticate.mockReset().mockResolvedValue(undefined);
		reconcileStagedClientPhotoUploads.mockReset().mockResolvedValue(undefined);
		listen.mockReset().mockImplementation((_port: number, _host: string, ready: () => void) => {
			ready();
			return { close: jest.fn() };
		});
	});

	it('authenticates and reconciles staging before binding the HTTP listener', async () => {
		await startServer();
		expect(authenticate).toHaveBeenCalled();
		expect(reconcileStagedClientPhotoUploads).toHaveBeenCalled();
		expect(reconcileStagedClientPhotoUploads.mock.invocationCallOrder[0]).toBeGreaterThan(
			authenticate.mock.invocationCallOrder[0],
		);
		expect(listen.mock.invocationCallOrder[0]).toBeGreaterThan(
			reconcileStagedClientPhotoUploads.mock.invocationCallOrder[0],
		);
		expect(listen).toHaveBeenCalledTimes(1);
	});

	it('does not bind the HTTP listener when database authentication fails', async () => {
		authenticate.mockRejectedValueOnce(new Error('database unavailable'));
		await expect(startServer()).rejects.toThrow('database unavailable');
		expect(listen).not.toHaveBeenCalled();
	});

	it('does not bind the HTTP listener when stage reconciliation fails', async () => {
		reconcileStagedClientPhotoUploads.mockRejectedValueOnce(new Error('staging unavailable'));
		await expect(startServer()).rejects.toThrow('staging unavailable');
		expect(listen).not.toHaveBeenCalled();
	});
});
