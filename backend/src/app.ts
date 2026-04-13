import cors from 'cors';
import express, { Application, NextFunction, Request, Response } from 'express';
import helmet from 'helmet';
import multer from 'multer';
import morgan from 'morgan';
import routes from './routes';
import { sequelize } from './models';

import path from 'path';

const app: Application = express();

app.use(
	helmet({
		crossOriginResourcePolicy: { policy: 'cross-origin' },
	}),
);
app.use(cors());
app.use(morgan('dev'));
app.use(express.json());
app.use(express.urlencoded({ extended: true }));

app.use('/uploads', express.static(path.join(__dirname, '../uploads')));
app.use('/api', routes);

app.get('/health', (_req: Request, res: Response) => {
	res.json({ message: 'API is running' });
});

app.use((err: Error, _req: Request, res: Response, _next: NextFunction) => {
	console.error(err.stack);

	if (err instanceof multer.MulterError) {
		if (err.code === 'LIMIT_FILE_SIZE') {
			return res.status(400).json({ error: 'PDF file size must be 15MB or less' });
		}

		return res.status(400).json({ error: err.message });
	}

	if (err.message === 'Only PDF files are allowed!') {
		return res.status(400).json({ error: err.message });
	}

	res.status(500).json({ error: 'Something went wrong!' });
});

// Sync database (in production, use migrations)
if (process.env.NODE_ENV !== 'test') {
	sequelize
		.sync({ alter: true })
		.then(() => {
			console.log('Database synced');
		})
		.catch((err) => {
			console.error('Error syncing database:', err);
		});
}

export default app;
