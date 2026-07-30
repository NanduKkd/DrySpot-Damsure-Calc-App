import fs from 'fs';
import path from 'path';
import { Op, Transaction } from 'sequelize';
import { ManagedFileCleanup, ManagedFileKind } from '../models/ManagedFileCleanup';

const uploadsDirectory = path.resolve(__dirname, '../../uploads');
const opaquePhotoFilename = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(?:jpg|png|webp)$/i;
const managedPdfFilename = /^[a-z0-9][a-z0-9._-]{0,240}\.pdf$/i;
const maxAttempts = 8;
const initialBackoffMs = 60_000;
const maxBackoffMs = 24 * 60 * 60 * 1000;

export type CleanupResult = {
  attempted: number;
  deleted: number;
  failed: number;
  exhausted: number;
};

const validStorageKey = (kind: ManagedFileKind, storageKey: string) =>
  (kind === 'photo' ? opaquePhotoFilename : managedPdfFilename).test(storageKey);

/** Never allow an outbox row, including a corrupted one, to escape managed storage. */
export const managedFilePath = (kind: ManagedFileKind, storageKey: string) => {
  if (!validStorageKey(kind, storageKey)) return null;
  const filePath = path.resolve(uploadsDirectory, storageKey);
  return path.dirname(filePath) === uploadsDirectory ? filePath : null;
};

/**
 * Insert the outbox row in the caller's metadata transaction. The unique key
 * makes repeated delete messages for the same managed object harmless.
 */
export const queueManagedFileCleanup = async (
  kind: ManagedFileKind,
  storageKey: string | null | undefined,
  transaction: Transaction,
) => {
  if (!storageKey || !managedFilePath(kind, storageKey)) return false;
  await ManagedFileCleanup.findOrCreate({
    where: { storageKey },
    defaults: { storageKey, kind, nextAttemptAt: new Date() },
    transaction,
  });
  return true;
};

const backoffFor = (attempts: number) =>
  Math.min(initialBackoffMs * 2 ** Math.max(0, attempts - 1), maxBackoffMs);

const errorMessage = (error: unknown) =>
  error instanceof Error ? error.message.slice(0, 4000) : String(error).slice(0, 4000);

const reconcileOne = async (job: ManagedFileCleanup): Promise<CleanupResult> => {
  const filePath = managedFilePath(job.kind, job.storageKey);
  if (!filePath) {
    await job.update({
      attempts: maxAttempts,
      exhaustedAt: new Date(),
      lastError: 'Invalid managed storage key; no filesystem action was taken.',
    });
    return { attempted: 0, deleted: 0, failed: 1, exhausted: 1 };
  }

  try {
    await fs.promises.unlink(filePath);
    await job.destroy();
    return { attempted: 1, deleted: 1, failed: 0, exhausted: 0 };
  } catch (error: any) {
    if (error?.code === 'ENOENT') {
      await job.destroy();
      return { attempted: 1, deleted: 1, failed: 0, exhausted: 0 };
    }
    const attempts = job.attempts + 1;
    const exhausted = attempts >= maxAttempts;
    await job.update({
      attempts,
      exhaustedAt: exhausted ? new Date() : null,
      nextAttemptAt: new Date(Date.now() + backoffFor(attempts)),
      lastError: errorMessage(error),
    });
    console.error(`Unable to remove managed ${job.kind} ${job.storageKey}:`, error);
    return { attempted: 1, deleted: 0, failed: 1, exhausted: exhausted ? 1 : 0 };
  }
};

/** Process only due, non-exhausted rows. Missing files are successful cleanup. */
export const reconcileManagedFileCleanup = async ({
  storageKeys,
  limit = 100,
}: { storageKeys?: string[]; limit?: number } = {}): Promise<CleanupResult> => {
  const where: any = {
    exhaustedAt: null,
    nextAttemptAt: { [Op.lte]: new Date() },
  };
  if (storageKeys?.length) where.storageKey = { [Op.in]: [...new Set(storageKeys)] };
  const jobs = await ManagedFileCleanup.findAll({
    where,
    order: [['nextAttemptAt', 'ASC'], ['createdAt', 'ASC']],
    limit: Math.max(1, Math.min(limit, 1000)),
  });
  const results = await Promise.all(jobs.map(reconcileOne));
  return results.reduce(
    (total, result) => ({
      attempted: total.attempted + result.attempted,
      deleted: total.deleted + result.deleted,
      failed: total.failed + result.failed,
      exhausted: total.exhausted + result.exhausted,
    }),
    { attempted: 0, deleted: 0, failed: 0, exhausted: 0 },
  );
};

export const listExhaustedManagedFileCleanup = () =>
  ManagedFileCleanup.findAll({
    where: { exhaustedAt: { [Op.ne]: null } },
    order: [['exhaustedAt', 'ASC']],
  });

/** Explicit operator action: retry rows which were intentionally stopped. */
export const retryExhaustedManagedFileCleanup = async () =>
  ManagedFileCleanup.update(
    { attempts: 0, exhaustedAt: null, nextAttemptAt: new Date(), lastError: null },
    { where: { exhaustedAt: { [Op.ne]: null } } },
  );

export const managedFileCleanupPolicy = { maxAttempts, initialBackoffMs, maxBackoffMs };
