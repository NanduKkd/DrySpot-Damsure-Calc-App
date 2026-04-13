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
	filename: (_req, file, cb) => {
		const uniqueSuffix = Date.now() + '-' + Math.round(Math.random() * 1e9);
		cb(null, `${uniqueSuffix}${path.extname(file.originalname)}`);
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
