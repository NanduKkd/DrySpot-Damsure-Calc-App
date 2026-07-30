import app from './app';
import { sequelize } from './models';

const host = process.env.HOST || '0.0.0.0';
const port = process.env.PORT || 3000;

export const startServer = async () => {
  await sequelize.authenticate();
  console.log('Database connection established');

  return app.listen(Number(port), host, () => {
    console.log(`Server running on http://${host}:${port}`);
  });
};

void startServer().catch((error) => {
  console.error('Unable to start server: database connection failed', error);
  process.exitCode = 1;
});
