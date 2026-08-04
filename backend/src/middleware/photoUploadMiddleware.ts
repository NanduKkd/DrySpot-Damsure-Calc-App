import multer from 'multer';
import path from 'path';
import fs from 'fs';
import { randomUUID } from 'crypto';
import { NextFunction, Request, Response } from 'express';

export const photoUploadPath = path.join(__dirname, '../../uploads');
export const photoUploadStagingPath = path.join(photoUploadPath, '.staging');
const allowedExtensions = new Set(['.jpg', '.jpeg', '.png', '.webp']);

const storage = multer.diskStorage({
	destination: (_req, _file, cb) => {
		if (!fs.existsSync(photoUploadStagingPath)) {
			fs.mkdirSync(photoUploadStagingPath, { recursive: true });
		}
		cb(null, photoUploadStagingPath);
	},
	filename: (_req, file, cb) => {
		const extension = path.extname(file.originalname).toLowerCase();
		cb(null, `${randomUUID()}${extension === '.jpeg' ? '.jpg' : extension}`);
	},
});

export const photoUpload = multer({
	storage,
	limits: { fileSize: 10 * 1024 * 1024 },
	fileFilter: (_req, file, cb) => {
		const extension = path.extname(file.originalname).toLowerCase();
		if (!allowedExtensions.has(extension))
			return cb(new Error('Only JPEG, PNG, and WebP images are allowed'));
		cb(null, true);
	},
});

export const removeUploadedPhoto = async (file?: Express.Multer.File) => {
	if (!file?.path) return;
	try {
		await fs.promises.unlink(file.path);
	} catch (error: any) {
		if (error?.code !== 'ENOENT')
			console.error(`Unable to remove rejected image ${file.path}:`, error);
	}
};

export const removeStoredPhoto = async (filename: string) => {
	if (
		!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(?:jpg|png|webp)$/i.test(
			filename,
		)
	)
		return;
	const filePath = path.join(photoUploadPath, filename);
	if (path.dirname(filePath) !== photoUploadPath) return;
	try {
		await fs.promises.unlink(filePath);
	} catch (error: any) {
		if (error?.code !== 'ENOENT')
			console.error(`Unable to remove stored image ${filePath}:`, error);
	}
};

export const stagedPhotoPath = (filename: string) => path.join(photoUploadStagingPath, filename);

export const storedPhotoPath = (filename: string) => path.join(photoUploadPath, filename);

export const promoteUploadedPhoto = async (file: Express.Multer.File) => {
	const stagedPath = path.resolve(file.path);
	const finalPath = path.resolve(storedPhotoPath(file.filename));
	if (
		path.dirname(stagedPath) !== photoUploadStagingPath ||
		path.dirname(finalPath) !== photoUploadPath
	) {
		throw new Error('Photo staging path is invalid.');
	}
	await fs.promises.mkdir(photoUploadPath, { recursive: true });
	try {
		await fs.promises.rename(stagedPath, finalPath);
	} catch (error: any) {
		// A crash may complete the rename before receipt state is updated. A retry
		// observes the final asset and treats that outcome as a completed replay.
		if (error?.code !== 'ENOENT' || !fs.existsSync(finalPath)) throw error;
	}
};

/** Keep photo Multer errors out of the app-wide PDF upload error handler. */
export const parsePhotoUpload = (req: Request, res: Response, next: NextFunction) => {
	photoUpload.single('file')(req, res, async (error: any) => {
		if (!error) return next();
		await removeUploadedPhoto(req.file);
		if (error instanceof multer.MulterError && error.code === 'LIMIT_FILE_SIZE') {
			return res.status(400).json({ error: 'Image file size must be 10MB or less' });
		}
		return res.status(400).json({ error: 'Only JPEG, PNG, and WebP images are allowed' });
	});
};
