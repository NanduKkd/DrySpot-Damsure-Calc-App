/* The production entrypoint is intentionally compiled: node dist/cli/userAdmin.js. */
import fs from 'fs';
import type { LifecycleRequest } from '../services/userAdministration';
import { OperatorAuthorizationError, resolveOperator } from './operatorAuthorization';

const fail = (code: string): never => { process.stderr.write(`user-admin: ${code}\n`); process.exit(2); };
const args = process.argv.slice(2);
const command = args.shift();
const option = (name: string): string | undefined => { const index = args.indexOf(name); return index < 0 ? undefined : args[index + 1]; };
const requireOption = (name: string) => option(name) || fail(`MISSING_${name.slice(2).replace(/-/g, '_').toUpperCase()}`);

const loadActor = () => {
  try { return resolveOperator(typeof process.getuid === 'function' ? process.getuid() : undefined, process.env); }
  catch (error) { return fail(error instanceof OperatorAuthorizationError ? error.code : 'OPERATOR_CONFIG_UNAVAILABLE'); }
};

const readStdin = async (): Promise<string> => new Promise((resolve, reject) => {
  let value = ''; process.stdin.setEncoding('utf8'); process.stdin.on('data', (chunk) => { value += chunk; if (Buffer.byteLength(value, 'utf8') > 128) reject(new Error('too long')); });
  process.stdin.on('end', () => resolve(value.replace(/[\r\n]+$/, ''))); process.stdin.on('error', reject);
});
const writeCredentialToTty = (credential: string) => {
  let fd: number | undefined;
  try { fd = fs.openSync('/dev/tty', 'w'); fs.writeSync(fd, `Credential (displayed once): ${credential}\n`); } finally { if (fd !== undefined) fs.closeSync(fd); }
};
const output = (value: unknown) => process.stdout.write(`${JSON.stringify(value)}\n`);

const run = async () => {
  const actor = loadActor();
  // Validate the trusted execution boundary before loading database configuration.
  const { UserAdministrationService } = await import('../services/userAdministration');
  const database = (await import('../config/database')).default;
  const service = new UserAdministrationService();
  try {
    const franchiseeId = requireOption('--franchisee-id');
    if (command === 'show') return output(await service.show(actor, franchiseeId, requireOption('--email')));
    if (command === 'audit') return output(await service.auditEvents(actor, franchiseeId, Number(option('--limit') || 50), option('--cursor')));
    if (!['create', 'deactivate', 'reactivate', 'revoke-all-tokens', 'reset-password'].includes(command || '')) return fail('UNKNOWN_COMMAND');
    const passwordStdin = args.includes('--password-stdin');
    if (args.some((arg) => /^--password(?:=|$)/.test(arg)) || args.some((arg) => /^--actor(?:=|$)/.test(arg))) return fail('UNSAFE_ARGUMENT');
    const request: LifecycleRequest = {
      action: command as LifecycleRequest['action'], franchiseeId, email: requireOption('--email'), reason: requireOption('--reason'), idempotencyKey: requireOption('--idempotency-key'), name: option('--name'),
      password: passwordStdin ? await readStdin() : undefined,
    };
    const result = await service.execute(actor, request);
    output({ outcome: result.outcome, reasonCode: result.reasonCode, user: result.user });
    if (result.generatedPassword || request.password) {
      // This occurs after the transaction: a failed TTY write must be recovered by reset with a new key.
      try { writeCredentialToTty(result.generatedPassword || request.password!); } catch (_) { process.stderr.write('user-admin: CREDENTIAL_DISPLAY_FAILED_AFTER_COMMIT; reset with a new idempotency key\n'); process.exitCode = 3; }
    }
  } finally { await database.close(); }
};

run().catch((error: unknown) => {
  const code = error && typeof error === 'object' && 'code' in error && typeof error.code === 'string' ? error.code : 'FAILED';
  process.stderr.write(`user-admin: ${code}\n`);
  process.exitCode = 2;
});
