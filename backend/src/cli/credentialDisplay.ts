import type { LifecycleResult } from '../services/userAdministration';

/** Credentials are never echoed when supplied by an operator or on a replay. */
export const displayNewGeneratedCredential = (
  result: LifecycleResult,
  display: (credential: string) => void,
): void => {
  if (result.outcome === 'succeeded' && result.generatedPassword) display(result.generatedPassword);
};
