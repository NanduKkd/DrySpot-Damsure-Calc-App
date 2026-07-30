'use strict';

const configured = (name) => {
  const value = process.env[name]?.trim();
  return value || undefined;
};

const sslOptions = () => process.env.DB_SSL === 'true'
  ? { ssl: { require: true, rejectUnauthorized: false } }
  : undefined;

const configuredPort = () => {
  const value = configured('DB_PORT');
  if (!value) return 5432;
  const port = Number(value);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error('DB_PORT must be a valid TCP port');
  }
  return port;
};

/**
 * Shared by the runtime Sequelize instance and sequelize-cli. Never provide
 * production database defaults: an incomplete environment must fail before a
 * process can connect to the wrong database.
 */
const resolveDatabaseConfig = (environment = process.env.NODE_ENV || 'development') => {
  if (environment === 'test') {
    return { dialect: 'sqlite', storage: process.env.DB_STORAGE || ':memory:', logging: false };
  }

  const dialectOptions = sslOptions();
  const databaseUrl = configured('DATABASE_URL');
  if (databaseUrl) {
    return { dialect: 'postgres', url: databaseUrl, logging: false, dialectOptions };
  }

  const required = ['DB_NAME', 'DB_USER', 'DB_PASSWORD', 'DB_HOST'];
  const missing = required.filter((name) => !configured(name));
  if (missing.length) {
    throw new Error(`Database configuration is missing required environment variables: ${missing.join(', ')}`);
  }

  return {
    dialect: 'postgres',
    database: configured('DB_NAME'),
    username: configured('DB_USER'),
    password: configured('DB_PASSWORD'),
    host: configured('DB_HOST'),
    port: configuredPort(),
    logging: false,
    dialectOptions,
  };
};

module.exports = { resolveDatabaseConfig };
