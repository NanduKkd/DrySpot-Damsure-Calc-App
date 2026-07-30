import { Response } from 'express';
import fs from 'fs';
import path from 'path';
import { AuthRequest } from '../middleware/authMiddleware';
import { Client, sequelize } from '../models';
import { removeUploadedPhoto } from '../middleware/photoUploadMiddleware';
import { queueManagedFileCleanup, reconcileManagedFileCleanup } from '../services/managedFileCleanup';

const uploadsDirectory = path.join(__dirname, '../../uploads');
const opaqueFilename = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(?:jpg|png|webp)$/i;

export const photoPath = (clientId: string, filename: string) => `/api/photos/client/${clientId}/${filename}`;

const parsePhotos = (photos: unknown): string[] => {
  if (Array.isArray(photos)) return photos.filter((value): value is string => typeof value === 'string');
  if (typeof photos !== 'string') return [];
  try {
    const parsed = JSON.parse(photos);
    return Array.isArray(parsed) ? parsed.filter((value): value is string => typeof value === 'string') : [];
  } catch {
    return [];
  }
};

const validImageContent = async (file: Express.Multer.File) => {
  const bytes = await fs.promises.readFile(file.path);
  const extension = path.extname(file.originalname).toLowerCase();
  const jpeg = bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
  const png = bytes.length >= 8 && bytes.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]));
  const webp = bytes.length >= 12 && bytes.subarray(0, 4).toString() === 'RIFF' && bytes.subarray(8, 12).toString() === 'WEBP';
  return (jpeg && ['.jpg', '.jpeg'].includes(extension)) || (png && extension === '.png') || (webp && extension === '.webp');
};

const ownedActiveClient = async (clientId: string, franchiseeId?: string) =>
  Client.findOne({ where: { id: clientId, franchiseeId } });

const safeFilePath = (filename: string) => {
  if (!opaqueFilename.test(filename)) return null;
  const filePath = path.resolve(uploadsDirectory, filename);
  return path.dirname(filePath) === uploadsDirectory ? filePath : null;
};

export const uploadPhoto = async (req: AuthRequest, res: Response) => {
  const file = req.file;
  const client = await ownedActiveClient(req.params.client_id, req.user?.franchiseeId);
  if (!client) {
    await removeUploadedPhoto(file);
    return res.status(403).json({ error: 'Unauthorized: Client does not belong to your franchisee' });
  }
  if (!file) return res.status(400).json({ error: 'No image file uploaded' });
  if (!(await validImageContent(file))) {
    await removeUploadedPhoto(file);
    return res.status(400).json({ error: 'Image content does not match its JPEG, PNG, or WebP extension' });
  }

  const canonicalPath = photoPath(client.id, file.filename);
  try {
    const photos = parsePhotos(client.photos);
    await client.update({ photos: JSON.stringify([...new Set([...photos, canonicalPath])]) });
    return res.status(201).json({ url: canonicalPath });
  } catch (error) {
    await removeUploadedPhoto(file);
    console.error('Photo upload error:', error);
    return res.status(500).json({ error: 'An error occurred during photo upload' });
  }
};

export const downloadPhoto = async (req: AuthRequest, res: Response) => {
  const { client_id: clientId, filename } = req.params;
  const client = await ownedActiveClient(clientId, req.user?.franchiseeId);
  const canonicalPath = photoPath(clientId, filename);
  const filePath = safeFilePath(filename);
  if (!client || !filePath || !parsePhotos(client.photos).includes(canonicalPath)) {
    return res.status(404).json({ error: 'Photo not found or unauthorized' });
  }
  return res.sendFile(filePath, (error) => {
    if (error && !res.headersSent) res.status(404).json({ error: 'Photo file not found' });
  });
};

export const deletePhoto = async (req: AuthRequest, res: Response) => {
  const { client_id: clientId, filename } = req.params;
  const canonicalPath = photoPath(clientId, filename);
  const filePath = safeFilePath(filename);
  if (!filePath) return res.status(404).json({ error: 'Photo not found or unauthorized' });

  const transaction = await sequelize.transaction();
  let committed = false;
  try {
    const client = await Client.findOne({ where: { id: clientId, franchiseeId: req.user?.franchiseeId }, transaction, lock: transaction.LOCK.UPDATE });
    const photos = client && parsePhotos(client.photos);
    if (!client || !photos?.includes(canonicalPath)) {
      await transaction.rollback();
      return res.status(404).json({ error: 'Photo not found or unauthorized' });
    }
    await client.update({ photos: JSON.stringify(photos.filter((photo) => photo !== canonicalPath)) }, { transaction });
    await queueManagedFileCleanup('photo', filename, transaction);
    await transaction.commit();
    committed = true;
    // Metadata deletion remains authoritative; cleanup failures are retained
    // by the transactionally-created outbox row for an operator retry.
    await reconcileManagedFileCleanup({ storageKeys: [filename], limit: 1 });
    return res.status(204).send();
  } catch (error) {
    if (!committed) await transaction.rollback();
    console.error('Photo deletion error:', error);
    return res.status(500).json({ error: 'An error occurred during photo deletion' });
  }
};
