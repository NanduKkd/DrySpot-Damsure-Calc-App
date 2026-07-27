const INSECURE_SECRETS = new Set(['your_jwt_secret', 'change-me', 'secret']);

/**
 * JWT signing must never silently fall back to a repository-known value.  Tests
 * set JWT_SECRET explicitly in their Jest setup before application modules load.
 */
export const getJwtSecret = (): string => {
  const secret = process.env.JWT_SECRET;

  if (!secret || INSECURE_SECRETS.has(secret)) {
    throw new Error('JWT_SECRET must be configured to a non-default value');
  }

  return secret;
};

export const JWT_SECRET = getJwtSecret();
