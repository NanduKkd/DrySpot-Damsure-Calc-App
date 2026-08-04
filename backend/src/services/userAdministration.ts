import bcrypt from 'bcrypt';
import crypto from 'crypto';
import os from 'os';
import { Op, QueryTypes, Transaction, UniqueConstraintError } from 'sequelize';
import sequelize from '../config/database';
import { Franchisee } from '../models/Franchisee';
import { User } from '../models/User';
import { UserAdminAuditEvent } from '../models/UserAdminAuditEvent';
import { normalizeUserEmail, normalizedEmailWhere } from '../utils/userEmail';

export const USER_ADMIN_BCRYPT_COST = 12;
const MAX_TOKEN_VERSION = 2147483647;
const COMMON_PASSWORDS = new Set([
  'passwordpassword', 'password123456', 'password123456789', '1234567890123456',
  'qwertyuiopasdfgh', 'qwerty1234567890', 'letmeinletmein12', 'welcome123456789',
  'adminadminadmin12', 'iloveyouiloveyou', 'changemechangeme1', 'monkeymonkeymonk',
]);
export type UserAdminAction = 'create' | 'deactivate' | 'reactivate' | 'revoke-all-tokens' | 'reset-password';
const USER_ADMIN_ACTIONS = new Set<string>(['create', 'deactivate', 'reactivate', 'revoke-all-tokens', 'reset-password']);

export interface AdminActor { actor: string; uid: number; authMode: string; franchiseeIds: string[] | '*'; }
export interface LifecycleRequest {
  action: UserAdminAction; franchiseeId: string; email: string; reason: string; idempotencyKey: string;
  name?: string; password?: string;
}
export interface LifecycleResult { outcome: 'succeeded' | 'noop'; reasonCode: string; user: { id: string; email: string; franchiseeId: string; isActive: boolean; tokenVersion: number }; generatedPassword?: string; }
export interface AuditEventOutput extends Record<string, unknown> { id: string; auditSequence: string; }
export interface AuditPage { events: AuditEventOutput[]; nextCursor?: string; }

export class UserAdminError extends Error {
  constructor(public readonly code: string, message = code) { super(message); }
}

const isUuid = (value: string) => /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
const requestHash = (request: LifecycleRequest) => crypto.createHash('sha256').update(JSON.stringify({
  action: request.action, franchiseeId: request.franchiseeId, email: normalizeUserEmail(request.email), reason: request.reason, name: request.name || '',
  // The resulting digest is the required canonical request SHA-256; the plaintext is never persisted.
  credential: request.password || null,
})).digest('hex');
const snapshot = (user: User | null) => user ? { isActive: user.isActive, tokenVersion: user.tokenVersion } : null;
const publicUser = (user: User) => ({ id: user.id, email: normalizeUserEmail(user.email), franchiseeId: user.franchiseeId, isActive: user.isActive, tokenVersion: user.tokenVersion });
const isEmail = (email: string) => /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) && Buffer.byteLength(email, 'utf8') <= 320;
const MAX_AUDIT_SEQUENCE = 9223372036854775807n;
type AuditCursor = { sequence: string; franchiseeId?: string };

const encodeAuditCursor = (franchiseeId: string, sequence: string): string =>
  Buffer.from(JSON.stringify({ franchiseeId, sequence })).toString('base64url');

const decodeAuditCursor = (value: string): AuditCursor => {
  try {
    const parsed = JSON.parse(Buffer.from(value, 'base64url').toString('utf8')) as AuditCursor;
    const sequence = BigInt(parsed.sequence);
    if (
      !/^[1-9]\d*$/.test(parsed.sequence) || sequence > MAX_AUDIT_SEQUENCE || sequence.toString() !== parsed.sequence
      || (parsed.franchiseeId !== undefined && !isUuid(parsed.franchiseeId))
    ) throw new Error('invalid');
    return parsed;
  } catch (_) { throw new UserAdminError('INVALID_AUDIT_CURSOR'); }
};

const ensurePassword = (password: string, email: string, name: string) => {
  const length = Buffer.byteLength(password, 'utf8');
  const lowered = password.toLowerCase();
  const symbols = new Set(Array.from(password));
  const repeatedPattern = /^(.{1,4})\1+$/u.test(password);
  if (
    length < 16 || length > 64 || password.trim() !== password || /[\p{Cc}\p{Cf}]/u.test(password)
    || symbols.size < 4 || repeatedPattern || lowered.includes(email)
    || (name && lowered.includes(name.trim().toLowerCase())) || COMMON_PASSWORDS.has(lowered)
  ) {
    throw new UserAdminError('WEAK_CREDENTIAL', 'Credential does not meet the administration policy');
  }
};

export const generatePassword = (): string => crypto.randomBytes(24).toString('base64url');

const generatePolicyCompliantPassword = (email: string, name: string): string => {
  // A random base64url credential can very occasionally contain a supplied name.
  // Regenerate rather than weakening the same policy used for supplied secrets.
  for (let attempt = 0; attempt < 32; attempt += 1) {
    const password = generatePassword();
    try { ensurePassword(password, email, name); return password; } catch (error) {
      if (!(error instanceof UserAdminError) || error.code !== 'WEAK_CREDENTIAL') throw error;
    }
  }
  throw new UserAdminError('CREDENTIAL_GENERATION_FAILED');
};

export class UserAdministrationService {
  private readonly appVersion: string;

  constructor(appVersion = process.env.APP_VERSION) {
    if (process.env.NODE_ENV === 'production' && (!appVersion || !/^[0-9a-f]{7,64}$/i.test(appVersion))) {
      throw new UserAdminError('APP_VERSION_REQUIRED');
    }
    this.appVersion = appVersion || 'unknown';
  }

  private async nextAuditSequence(transaction: Transaction): Promise<string> {
    if (sequelize.getDialect() === 'postgres') {
      const rows = await sequelize.query(
        "SELECT nextval('user_admin_audit_events_audit_sequence_seq')::text AS audit_sequence",
        { type: QueryTypes.SELECT, transaction },
      ) as Array<{ audit_sequence: string }>;
      return rows[0].audit_sequence;
    }
    await sequelize.query(
      'UPDATE user_admin_audit_event_sequence SET next_value = next_value + 1 WHERE singleton = 1',
      { transaction },
    );
    const rows = await sequelize.query(
      'SELECT CAST(next_value AS TEXT) AS audit_sequence FROM user_admin_audit_event_sequence WHERE singleton = 1',
      { type: QueryTypes.SELECT, transaction },
    ) as Array<{ audit_sequence: string }>;
    return rows[0].audit_sequence;
  }

  private async audit(transaction: Transaction, actor: AdminActor, request: LifecycleRequest, outcome: 'succeeded' | 'noop' | 'rejected', reasonCode: string, target: User | null, before: object | null, after: object | null) {
    await UserAdminAuditEvent.create({
      id: crypto.randomUUID(), idempotencyKey: request.idempotencyKey, canonicalRequestSha256: requestHash(request), auditSequence: await this.nextAuditSequence(transaction),
      actor: actor.actor, actorUid: actor.uid, authMode: actor.authMode, scopeSnapshot: { franchiseeIds: actor.franchiseeIds },
      action: request.action, targetUserId: target?.id || null, normalizedEmail: normalizeUserEmail(request.email), franchiseeId: request.franchiseeId,
      reason: Buffer.byteLength(request.reason, 'utf8') > 255 ? '[redacted:reason-too-long]' : request.reason,
      outcome, reasonCode, beforeState: before, afterState: after, hostname: os.hostname(), appVersion: this.appVersion,
    }, { transaction });
  }

  private validate(actor: AdminActor, request: LifecycleRequest) {
    const normalizedEmail = normalizeUserEmail(request.email);
    // The service is reusable outside the CLI, so do not rely on the TypeScript
    // union or the CLI parser to constrain untrusted runtime values.
    if (!USER_ADMIN_ACTIONS.has(request.action)) throw new UserAdminError('UNSUPPORTED_ACTION');
    if (!isUuid(request.franchiseeId) || !isUuid(request.idempotencyKey) || !request.reason.trim()) throw new UserAdminError('INVALID_REQUEST');
    if (Buffer.byteLength(request.reason, 'utf8') > 255) throw new UserAdminError('REASON_TOO_LONG');
    if (!isEmail(normalizedEmail)) throw new UserAdminError('INVALID_EMAIL');
    if (actor.franchiseeIds !== '*' && !actor.franchiseeIds.includes(request.franchiseeId)) throw new UserAdminError('OUT_OF_SCOPE');
    if (request.action === 'create' && !request.name?.trim()) throw new UserAdminError('NAME_REQUIRED');
  }

  private async recordRejected(actor: AdminActor, request: LifecycleRequest, code: string, target: User | null = null) {
    try {
      await sequelize.transaction(async (transaction) => {
        const prior = await UserAdminAuditEvent.findOne({ where: { idempotencyKey: request.idempotencyKey }, transaction, lock: transaction.LOCK.UPDATE });
        if (!prior) await this.audit(transaction, actor, request, 'rejected', code, target, snapshot(target), snapshot(target));
      });
    } catch (error) {
      if (!(error instanceof UserAdminError)) throw error;
    }
  }

  async execute(actor: AdminActor, request: LifecycleRequest): Promise<LifecycleResult> {
    try { this.validate(actor, request); } catch (error) {
      if (error instanceof UserAdminError && isUuid(request.idempotencyKey) && isUuid(request.franchiseeId)) await this.recordRejected(actor, request, error.code);
      throw error;
    }
    const normalizedEmail = normalizeUserEmail(request.email);
    let generatedPassword: string | undefined;
    try {
      return await sequelize.transaction(async (transaction) => {
        if (sequelize.getDialect() === 'postgres') await sequelize.query('SELECT pg_advisory_xact_lock(hashtext(:key))', { replacements: { key: request.idempotencyKey }, transaction });
        const previous = await UserAdminAuditEvent.findOne({ where: { idempotencyKey: request.idempotencyKey }, transaction, lock: transaction.LOCK.UPDATE });
        if (previous) {
          if (previous.get('canonicalRequestSha256') !== requestHash(request)) throw new UserAdminError('IDEMPOTENCY_CONFLICT');
          const state = previous.get('afterState') as { isActive: boolean; tokenVersion: number } | null;
          const target = previous.get('targetUserId') ? await User.findByPk(previous.get('targetUserId') as string, { transaction }) : null;
          if (!target || !state || previous.get('outcome') === 'rejected') throw new UserAdminError(previous.get('reasonCode') as string);
          return { outcome: previous.get('outcome') as 'succeeded' | 'noop', reasonCode: previous.get('reasonCode') as string, user: publicUser(target) };
        }
        const franchisee = await Franchisee.findByPk(request.franchiseeId, { transaction, lock: transaction.LOCK.UPDATE });
        if (!franchisee) throw new UserAdminError('FRANCHISEE_NOT_FOUND');
        let target = await User.findOne({ where: normalizedEmailWhere(normalizedEmail), transaction, lock: transaction.LOCK.UPDATE });
        if (target && target.franchiseeId !== request.franchiseeId) throw new UserAdminError('TARGET_NOT_FOUND_IN_FRANCHISEE');
        const before = snapshot(target);
        let outcome: 'succeeded' | 'noop' = 'succeeded';
        let reasonCode = 'APPLIED';
        if (request.action === 'create') {
          if (target) { throw new UserAdminError('EMAIL_ALREADY_EXISTS'); }
          else {
            const password = request.password || generatePolicyCompliantPassword(normalizedEmail, request.name || '');
            ensurePassword(password, normalizedEmail, request.name || '');
            target = await User.create({ name: request.name!.trim(), email: normalizedEmail, password: await bcrypt.hash(password, USER_ADMIN_BCRYPT_COST), franchiseeId: request.franchiseeId, isActive: true, tokenVersion: 0 }, { transaction });
            if (!request.password) generatedPassword = password;
          }
        } else {
          if (!target) throw new UserAdminError('TARGET_NOT_FOUND_IN_FRANCHISEE');
          if (request.action === 'deactivate') {
            if (!target.isActive) { outcome = 'noop'; reasonCode = 'ALREADY_INACTIVE'; }
            else { this.incrementTokenVersion(target); target.isActive = false; await target.save({ transaction }); }
          } else if (request.action === 'reactivate') {
            if (target.isActive) { outcome = 'noop'; reasonCode = 'ALREADY_ACTIVE'; }
            else { target.isActive = true; await target.save({ transaction }); }
          } else if (request.action === 'revoke-all-tokens') {
            this.incrementTokenVersion(target); await target.save({ transaction });
          } else if (request.action === 'reset-password') {
            const password = request.password || generatePolicyCompliantPassword(normalizedEmail, target.name);
            ensurePassword(password, normalizedEmail, target.name);
            this.incrementTokenVersion(target); target.password = await bcrypt.hash(password, USER_ADMIN_BCRYPT_COST); await target.save({ transaction });
            if (!request.password) generatedPassword = password;
          } else {
            // Kept as a defence in depth guard if this branch is refactored.
            throw new UserAdminError('UNSUPPORTED_ACTION');
          }
        }
        await this.audit(transaction, actor, request, outcome, reasonCode, target!, before, snapshot(target!));
        return { outcome, reasonCode, user: publicUser(target!), generatedPassword };
      });
    } catch (error) {
      if (error instanceof UniqueConstraintError) {
        await this.recordRejected(actor, request, 'EMAIL_ALREADY_EXISTS');
        throw new UserAdminError('EMAIL_ALREADY_EXISTS');
      }
      if (error instanceof UserAdminError && !['IDEMPOTENCY_CONFLICT'].includes(error.code)) await this.recordRejected(actor, request, error.code);
      throw error;
    }
  }

  private incrementTokenVersion(user: User) {
    if (!Number.isSafeInteger(user.tokenVersion) || user.tokenVersion >= MAX_TOKEN_VERSION) throw new UserAdminError('TOKEN_VERSION_EXHAUSTED');
    user.tokenVersion += 1;
  }

  async show(actor: AdminActor, franchiseeId: string, email: string) {
    if (!isUuid(franchiseeId) || (actor.franchiseeIds !== '*' && !actor.franchiseeIds.includes(franchiseeId))) throw new UserAdminError('OUT_OF_SCOPE');
    const user = await User.findOne({ where: { franchiseeId, [Op.and]: [normalizedEmailWhere(email)] } });
    if (!user) throw new UserAdminError('TARGET_NOT_FOUND_IN_FRANCHISEE');
    return publicUser(user);
  }

  async auditEvents(actor: AdminActor, franchiseeId: string, limit = 50, cursor?: string): Promise<AuditPage> {
    if (!isUuid(franchiseeId) || (actor.franchiseeIds !== '*' && !actor.franchiseeIds.includes(franchiseeId))) throw new UserAdminError('OUT_OF_SCOPE');
    const whereClause: Record<string | symbol, unknown> = { franchiseeId };
    if (cursor) {
      const point = decodeAuditCursor(cursor);
      if (point.franchiseeId && point.franchiseeId !== franchiseeId) throw new UserAdminError('INVALID_AUDIT_CURSOR');
      // New cursors carry a tenant binding. Sequence-only cursors from the
      // previous format remain valid only when their immutable anchor belongs
      // to this tenant, so they cannot suppress newer tenant-local events.
      const anchor = await UserAdminAuditEvent.findOne({
        where: { franchiseeId, auditSequence: point.sequence }, attributes: ['id'], raw: true,
      });
      if (!anchor) throw new UserAdminError('INVALID_AUDIT_CURSOR');
      whereClause.auditSequence = { [Op.lt]: point.sequence };
    }
    const cappedLimit = Math.min(Math.max(limit, 1), 100);
    // `raw` preserves the text cast below. Model hydration can coerce BIGINT
    // through a JavaScript number, which would corrupt values above 2^53.
    const rows = await UserAdminAuditEvent.findAll({
      where: whereClause,
      order: [['auditSequence', 'DESC']],
      limit: cappedLimit + 1,
      attributes: { include: [[sequelize.literal('CAST(audit_sequence AS TEXT)'), 'auditSequenceText']] },
      raw: true,
    }) as unknown as Array<Record<string, unknown>>;
    const events = rows.slice(0, cappedLimit);
    return {
      events: events.map((row) => {
        const values = { ...row };
        const auditSequence = String(values.auditSequenceText);
        delete values.auditSequenceText;
        return { ...values, auditSequence } as AuditEventOutput;
      }),
      nextCursor: rows.length > cappedLimit ? encodeAuditCursor(franchiseeId, String(events[events.length - 1].auditSequenceText)) : undefined,
    };
  }
}
