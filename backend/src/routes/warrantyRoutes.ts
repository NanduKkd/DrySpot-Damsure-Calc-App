import { Router } from 'express';
import { uploadWarranty, getWarranties } from '../controllers/warrantyController';
import { authenticate } from '../middleware/authMiddleware';
import { upload } from '../middleware/uploadMiddleware';

const router = Router();

router.post('/upload', authenticate, upload.single('file'), uploadWarranty as any);
router.get('/client/:client_id', authenticate, getWarranties as any);

export default router;
