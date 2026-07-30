import { Sequelize } from 'sequelize';
import dotenv from 'dotenv';

// Shared CommonJS resolver is also consumed by sequelize-cli from backend/config.
// eslint-disable-next-line @typescript-eslint/no-var-requires
const { resolveDatabaseConfig } = require('../../config/database.config.js');

dotenv.config();

const config = resolveDatabaseConfig(process.env.NODE_ENV);
const options = {
  ...config,
  define: { underscored: true, timestamps: true },
};

const sequelize = config.url
  ? new Sequelize(config.url, options)
  : new Sequelize(options);

export default sequelize;
