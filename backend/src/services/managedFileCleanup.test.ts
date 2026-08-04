import fs from 'fs';
import { sequelize, ManagedFileCleanup } from '../models';
import {
  managedFileCleanupPolicy,
  managedFilePath,
  queueManagedFileCleanup,
  reconcileDueManagedFileCleanup,
  reconcileManagedFileCleanupByStorageKeys,
  retryExhaustedManagedFileCleanup,
} from './managedFileCleanup';

describe('managed file cleanup outbox', () => {
  const photo = '00000000-0000-0000-0000-000000009901.jpg';

  it('confines paths and refuses traversal rows', async () => {
    expect(managedFilePath('pdf', '../outside.pdf')).toBeNull();
    expect(managedFilePath('photo', 'not-a-managed-image.jpg')).toBeNull();
    await sequelize.transaction(async (transaction) => {
      expect(await queueManagedFileCleanup('pdf', '../outside.pdf', transaction)).toBe(false);
    });
    expect(await ManagedFileCleanup.count({ where: { storageKey: '../outside.pdf' } })).toBe(0);
  });

  it('is idempotent, treats ENOENT as success, and retains failures with backoff', async () => {
    await sequelize.transaction(async (transaction) => {
      await queueManagedFileCleanup('photo', photo, transaction);
    });
    await sequelize.transaction(async (transaction) => {
      await queueManagedFileCleanup('photo', photo, transaction);
    });
    expect(await ManagedFileCleanup.count({ where: { storageKey: photo } })).toBe(1);
    expect(await reconcileManagedFileCleanupByStorageKeys([photo])).toEqual({
      attempted: 1,
      deleted: 1,
      failed: 0,
      exhausted: 0,
    });
    expect(await ManagedFileCleanup.count({ where: { storageKey: photo } })).toBe(0);

    const failingPhoto = '00000000-0000-0000-0000-000000009902.jpg';
    await sequelize.transaction(async (transaction) => {
      await queueManagedFileCleanup('photo', failingPhoto, transaction);
    });
    const unlink = jest.spyOn(fs.promises, 'unlink').mockRejectedValueOnce(new Error('storage offline'));
    await reconcileManagedFileCleanupByStorageKeys([failingPhoto]);
    const retained = await ManagedFileCleanup.findOne({ where: { storageKey: failingPhoto } });
    expect(retained?.attempts).toBe(1);
    expect(retained?.nextAttemptAt.getTime()).toBeGreaterThan(Date.now() + managedFileCleanupPolicy.initialBackoffMs - 2_000);
    unlink.mockRestore();
  });

  it('caps retries as exhausted and only retries them after explicit operator reconciliation', async () => {
    const exhaustedPhoto = '00000000-0000-0000-0000-000000009903.jpg';
    await ManagedFileCleanup.create({
      storageKey: exhaustedPhoto,
      kind: 'photo',
      attempts: managedFileCleanupPolicy.maxAttempts - 1,
      nextAttemptAt: new Date(),
    });
    const unlink = jest.spyOn(fs.promises, 'unlink').mockRejectedValueOnce(new Error('storage offline'));
    expect((await reconcileManagedFileCleanupByStorageKeys([exhaustedPhoto])).exhausted).toBe(1);
    expect((await ManagedFileCleanup.findOne({ where: { storageKey: exhaustedPhoto } }))?.exhaustedAt).not.toBeNull();
    expect((await retryExhaustedManagedFileCleanup())[0]).toBeGreaterThanOrEqual(1);
    const requeued = await ManagedFileCleanup.findOne({ where: { storageKey: exhaustedPhoto } });
    expect(requeued?.attempts).toBe(0);
    expect(requeued?.exhaustedAt).toBeNull();
    unlink.mockRestore();
    await ManagedFileCleanup.destroy({ where: { storageKey: exhaustedPhoto } });
  });

  it('does not process global due work for an empty request scope, but does for explicit global reconciliation', async () => {
    const duePhoto = '00000000-0000-0000-0000-000000009904.jpg';
    await sequelize.transaction(async (transaction) => {
      await queueManagedFileCleanup('photo', duePhoto, transaction);
    });
    const unlink = jest.spyOn(fs.promises, 'unlink');
    expect(await reconcileManagedFileCleanupByStorageKeys([])).toEqual({
      attempted: 0,
      deleted: 0,
      failed: 0,
      exhausted: 0,
    });
    expect(unlink).not.toHaveBeenCalled();
    expect(await ManagedFileCleanup.count({ where: { storageKey: duePhoto } })).toBe(1);

    expect(await reconcileDueManagedFileCleanup()).toEqual({
      attempted: 1,
      deleted: 1,
      failed: 0,
      exhausted: 0,
    });
    unlink.mockRestore();
  });
});
