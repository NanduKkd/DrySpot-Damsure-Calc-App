import bcrypt from 'bcrypt';
import crypto from 'crypto';
import os from 'os';
import { Op, Transaction, UniqueConstraintError, fn, col, where } from 'sequelize';
import sequelize from '../config/database';
import { Franchisee } from '../models/Franchisee';
import { User } from '../models/User';
import { UserAdminAuditEvent } from '../models/UserAdminAuditEvent';

export const USER_ADMIN_BCRYPT_COST = 12;
const MAX_TOKEN_VERSION = 2147483647;
const COMMON_PASSWORDS = new Set([
  'passwordpassword', 'password123456', 'password123456789', '1234567890123456',
  'qwertyuiopasdfgh', 'qwerty1234567890', 'letmeinletmein12', 'welcome123456789',
  'adminadminadmin12', 'iloveyouiloveyou', 'changemechangeme1', 'monkeymonkeymonk',
]);
export type UserAdminAction = 'create' | 'deactivate' | 'reactivate' | 'revoke-all-tokens' | 'reset-password';

export interface AdminActor { actor: string; uid: number; authMode: string; franchiseeIds: string[] | '*'; }
export interface LifecycleRequest {
  action: UserAdminAction; franchiseeId: string; email: string; reason: string; idempotencyKey: string;
  name?: string; password?: string;
}
export interface LifecycleResult { outcome: 'succeeded' | 'noop'; reasonCode: string; user: { id: string; email: string; franchiseeId: string; isActive: boolean; tokenVersion: number }; generatedPassword?: string; }

export class UserAdminError extends Error {
  constructor(public readonly code: string, message = code) { super(message); }
}

export const normalizeUserEmail = (email: string): string => email.trim().toLowerCase();
const isUuid = (value: string) => /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
const requestHash = (request: LifecycleRequest) => crypto.createHash('sha256').update(JSON.stringify({
  action: request.action, franchiseeId: request.franchiseeId, email: normalizeUserEmail(request.email), reason: request.reason, name: request.name || '',
  // The resulting digest is the required canonical request SHA-256; the plaintext is never persisted.
  credential: request.password || null,
})).digest('hex');
const snapshot = (user: User | null) => user ? { isActive: user.isActive, tokenVersion: user.tokenVersion } : null;
const publicUser = (user: User) => ({ id: user.id, email: normalizeUserEmail(user.email), franchiseeId: user.franchiseeId, isActive: user.isActive, tokenVersion: user.tokenVersion });
const emailWhere = (email: string) => where(fn('lower', fn('trim', col('email'))), email);
const isEmail = (email: string) => /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) && Buffer.byteLength(email, 'utf8') <= 320;

const ensurePassword = (password: string, email: string, name: string) => {
  const length = Buffer.byteLength(password, 'utf8');
  const lowered = password.toLowerCase();
  if (length < 16 || length > 64 || lowered.includes(email) || (name && lowered.includes(name.trim().toLowerCase())) || COMMON_PASSWORDS.has(lowered)) {
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
  constructor(private readonly appVersion = process.env.APP_VERSION || 'unknown') {}

  private async audit(transaction: Transaction, actor: AdminActor, request: LifecycleRequest, outcome: 'succeeded' | 'noop' | 'rejected', reasonCode: string, target: User | null, before: object | null, after: object | null) {
    await UserAdminAuditEvent.create({
      id: crypto.randomUUID(), idempotencyKey: request.idempotencyKey, canonicalRequestSha256: requestHash(request),
      actor: actor.actor, actorUid: actor.uid, authMode: actor.authMode, scopeSnapshot: { franchiseeIds: actor.franchiseeIds },
      action: request.action, targetUserId: target?.id || null, normalizedEmail: normalizeUserEmail(request.email), franchiseeId: request.franchiseeId,
      reason: request.reason, outcome, reasonCode, beforeState: before, afterState: after, hostname: os.hostname(), appVersion: this.appVersion,
    }, { transaction });
  }

  private validate(actor: AdminActor, request: LifecycleRequest) {
    const normalizedEmail = normalizeUserEmail(request.email);
    if (!isUuid(request.franchiseeId) || !isUuid(request.idempotencyKey) || !request.reason.trim() || Buffer.byteLength(request.reason, 'utf8') > 512) throw new UserAdminError('INVALID_REQUEST');
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
        let target = await User.findOne({ where: emailWhere(normalizedEmail), transaction, lock: transaction.LOCK.UPDATE });
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
          } else {
            const password = request.password || generatePolicyCompliantPassword(normalizedEmail, target.name);
            ensurePassword(password, normalizedEmail, target.name);
            this.incrementTokenVersion(target); target.password = await bcrypt.hash(password, USER_ADMIN_BCRYPT_COST); await target.save({ transaction });
            if (!request.password) generatedPassword = password;
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
    const user = await User.findOne({ where: { franchiseeId, [Op.and]: [emailWhere(normalizeUserEmail(email))] } });
    if (!user) throw new UserAdminError('TARGET_NOT_FOUND_IN_FRANCHISEE');
    return publicUser(user);
  }

  async auditEvents(actor: AdminActor, franchiseeId: string, limit = 50, cursor?: string) {
    if (!isUuid(franchiseeId) || (actor.franchiseeIds !== '*' && !actor.franchiseeIds.includes(franchiseeId))) throw new UserAdminError('OUT_OF_SCOPE');
    const whereClause: Record<string, unknown> = { franchiseeId };
    if (cursor) whereClause.id = { [Op.lt]: cursor };
    return UserAdminAuditEvent.findAll({ where: whereClause, order: [['createdAt', 'DESC'], ['id', 'DESC']], limit: Math.min(Math.max(limit, 1), 100) });
  }
}
