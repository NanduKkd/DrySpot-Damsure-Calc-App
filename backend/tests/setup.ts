import { Sequelize } from 'sequelize';
import { sequelize } from '../src/models';

// eslint-disable-next-line @typescript-eslint/no-var-requires
const warrantyDeletionMigration = require('../migrations/20260730010000-add-warranty-deletion-tombstones.js');

// Deliberately explicit: production code rejects missing/default JWT secrets.
process.env.JWT_SECRET = 'test-only-jwt-secret-with-32-characters';

beforeAll(async () => {
	if (process.env.NODE_ENV === 'test') {
		await sequelize.sync({ force: true });
		// sequelize.sync cannot create the database triggers that make UUID
		// reservation safe against old or rolled-back writers.
		await warrantyDeletionMigration.up(sequelize.getQueryInterface(), Sequelize);
	}
});

afterAll(async () => {
	await sequelize.close();
	jest.restoreAllMocks();
});

afterEach(() => {
	jest.clearAllMocks();
});
