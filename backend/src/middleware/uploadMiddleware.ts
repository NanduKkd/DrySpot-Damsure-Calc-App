import multer from 'multer';
import path from 'path';
import fs from 'fs';

const storage = multer.diskStorage({
	destination: (_req, _file, cb) => {
		const uploadPath = path.join(__dirname, '../../uploads');
		if (!fs.existsSync(uploadPath)) {
			fs.mkdirSync(uploadPath, { recursive: true });
		}
		cb(null, uploadPath);
	},
	filename: (_req, _file, cb) => {
		const uniqueSuffix = Date.now() + '-' + Math.round(Math.random() * 1e9);
		// All accepted uploads are PDFs. A canonical managed key keeps APP-109
		// cleanup independent of the client's original filename/casing.
		cb(null, `${uniqueSuffix}.pdf`);
	},
});

export const upload = multer({
	storage,
	// Warranty PDFs embed multiple raster assets and exceed 5MB in release builds.
	limits: { fileSize: 15 * 1024 * 1024 },
	fileFilter: (_req, file, cb) => {
		const extension = path.extname(file.originalname).toLowerCase();
		const isPdfMime =
			file.mimetype === 'application/pdf' ||
			(file.mimetype === 'application/octet-stream' && extension === '.pdf');

		if (isPdfMime) {
			cb(null, true);
		} else {
			cb(new Error('Only PDF files are allowed!'));
		}
	},
});

/** Remove an already-written multer file when the request cannot be persisted. */
export const removeUploadedFile = async (file?: Express.Multer.File) => {
	if (!file?.path) return;
	try {
		await fs.promises.unlink(file.path);
	} catch (error: any) {
		if (error?.code !== 'ENOENT') {
			console.error(`Unable to remove rejected upload ${file.path}:`, error);
		}
	}
};

export const removeStoredPdf = async (pdfUrl: string, pdfFileName?: string | null) => {
	const filename = pdfFileName || path.basename(new URL(pdfUrl, 'http://localhost').pathname);
	if (!filename || filename === '.' || filename === path.sep) return;
	const uploadPath = path.join(__dirname, '../../uploads');
	const filePath = path.join(uploadPath, filename);
	if (path.dirname(filePath) !== uploadPath) return;
	try {
		await fs.promises.unlink(filePath);
	} catch (error: any) {
		if (error?.code !== 'ENOENT') {
			console.error(`Unable to remove stored PDF ${filePath}:`, error);
		}
	}
};
