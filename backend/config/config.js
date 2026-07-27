require('dotenv').config();
const { resolveDatabaseConfig } = require('./database.config');

const cliConfig = (environment) => {
  const config = resolveDatabaseConfig(environment);
  if (config.url) {
    const { url: _url, ...options } = config;
    return { ...options, use_env_variable: 'DATABASE_URL' };
  }
  return config;
};

// sequelize-cli only reads the selected environment. Resolving just that entry
// keeps `NODE_ENV=test` independent of local production credentials while
// retaining fail-fast validation for the environment actually being run.
const environment = process.env.NODE_ENV || 'development';
module.exports = {
  development: {},
  production: {},
  test: {},
  [environment]: cliConfig(environment),
};
