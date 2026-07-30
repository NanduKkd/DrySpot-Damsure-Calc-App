import { sequelize } from '../src/models';

// Deliberately explicit: production code rejects missing/default JWT secrets.
process.env.JWT_SECRET = 'test-only-jwt-secret-with-32-characters';

beforeAll(async () => {
	if (process.env.NODE_ENV === 'test') {
		await sequelize.sync({ force: true });
	}
});

afterAll(async () => {
	await sequelize.close();
	jest.restoreAllMocks();
});

afterEach(() => {
	jest.clearAllMocks();
});
