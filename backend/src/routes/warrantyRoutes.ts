import { Router } from 'express';
import { uploadWarranty, getWarranties, downloadWarranty, deleteWarranty } from '../controllers/warrantyController';
import { authenticate } from '../middleware/authMiddleware';
import { upload } from '../middleware/uploadMiddleware';

const router = Router();

router.post('/upload', authenticate, upload.single('file'), uploadWarranty as any);
router.get('/client/:client_id', authenticate, getWarranties as any);
router.get('/:id/download', authenticate, downloadWarranty as any);
router.delete('/:id', authenticate, deleteWarranty as any);

export default router;
