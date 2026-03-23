import { Sequelize } from 'sequelize';
import dotenv from 'dotenv';

dotenv.config();

const isTest = process.env.NODE_ENV === 'test';

const sequelize = isTest 
  ? new Sequelize('sqlite::memory:', { logging: false, define: { underscored: true, timestamps: true } })
  : new Sequelize(
      process.env.DB_NAME || 'damsure_db',
      process.env.DB_USER || 'postgres',
      process.env.DB_PASSWORD || 'password',
      {
        host: process.env.DB_HOST || 'localhost',
        dialect: 'postgres',
        logging: false,
        define: {
          underscored: true,
          timestamps: true,
        },
      }
    );

export default sequelize;
