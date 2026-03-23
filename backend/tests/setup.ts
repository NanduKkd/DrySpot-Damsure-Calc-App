import { sequelize } from '../src/models';

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
