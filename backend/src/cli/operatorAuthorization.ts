import fs from 'fs';
import type { AdminActor } from '../services/userAdministration';

type OperatorConfig = { operators: Record<string, { franchiseeIds: string[] | '*' }> };
type FileAccess = {
  lstatSync(path: string): Pick<fs.Stats, 'uid' | 'mode' | 'isSymbolicLink'>;
  readFileSync(path: string, encoding: BufferEncoding): string | Buffer;
};
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export class OperatorAuthorizationError extends Error {
  constructor(public readonly code: string) { super(code); }
}

export const operatorConfigPath = (environment: NodeJS.ProcessEnv): string =>
  environment.NODE_ENV === 'test' && environment.DAMSURE_USER_ADMIN_CONFIG
    ? environment.DAMSURE_USER_ADMIN_CONFIG
    : '/etc/damsure/user-admin-operators.json';

export const resolveOperator = (
  uid: number | undefined,
  environment: NodeJS.ProcessEnv,
  fileAccess: FileAccess = fs,
): AdminActor => {
  if (uid !== 0) throw new OperatorAuthorizationError('DIRECT_INVOCATION_DENIED');
  const username = environment.SUDO_USER;
  const sudoUid = environment.SUDO_UID;
  if (!username || !/^[a-z_][a-z0-9_-]{0,31}$/i.test(username) || !/^\d+$/.test(sudoUid || '') || Number(sudoUid) < 1) {
    throw new OperatorAuthorizationError('UNVERIFIED_OPERATOR');
  }
  const configPath = operatorConfigPath(environment);
  let stat: Pick<fs.Stats, 'uid' | 'mode' | 'isSymbolicLink'>;
  let config: OperatorConfig;
  try {
    stat = fileAccess.lstatSync(configPath);
    config = JSON.parse(fileAccess.readFileSync(configPath, 'utf8') as string) as OperatorConfig;
  } catch (_) {
    throw new OperatorAuthorizationError('OPERATOR_CONFIG_UNAVAILABLE');
  }
  if (stat.isSymbolicLink() || stat.uid !== 0 || (stat.mode & 0o022) !== 0) throw new OperatorAuthorizationError('OPERATOR_CONFIG_UNSAFE');
  const scope = config.operators?.[username]?.franchiseeIds;
  if (scope !== '*' && (!Array.isArray(scope) || scope.length === 0 || scope.some((value) => typeof value !== 'string' || !UUID.test(value)))) {
    throw new OperatorAuthorizationError('UNAUTHORIZED_OPERATOR');
  }
  return { actor: username, uid: Number(sudoUid), authMode: 'sudo-wrapper', franchiseeIds: scope };
};
