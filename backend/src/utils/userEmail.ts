import { col, fn, where } from 'sequelize';
import sequelize from '../config/database';

export const normalizeUserEmail = (email: string): string => email.trim().toLowerCase();

// This must match the APP-108 expression index exactly. PostgreSQL uses btrim;
// SQLite's compatible built-in is trim.
export const normalizedEmailWhere = (email: string) =>
  where(
    fn('lower', fn(sequelize.getDialect() === 'postgres' ? 'btrim' : 'trim', col('email'))),
    normalizeUserEmail(email),
  );
