import app from './app';
import { sequelize } from './models';
import { reconcileStagedClientPhotoUploads } from './services/clientPhotoUploadReceipt';

const host = process.env.HOST || '0.0.0.0';
const port = process.env.PORT || 3000;

export const startServer = async () => {
	await sequelize.authenticate();
	console.log('Database connection established');
	// Migrations are deliberately a deploy concern. This is file-state repair
	// only: complete committed staging receipts, then prune aged unclaimed files.
	// A failure prevents HTTP from binding so we never serve dangling media.
	await reconcileStagedClientPhotoUploads();
	console.log('Client photo staging reconciled');

	return app.listen(Number(port), host, () => {
		console.log(`Server running on http://${host}:${port}`);
	});
};

void startServer().catch((error) => {
	console.error('Unable to start server: database connection failed', error);
	process.exitCode = 1;
});
