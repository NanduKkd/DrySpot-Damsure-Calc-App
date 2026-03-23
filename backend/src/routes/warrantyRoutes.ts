import { Router } from 'express';
import { uploadWarranty, getWarranties } from '../controllers/warrantyController';
import { authenticate } from '../middleware/authMiddleware';

const router = Router();

router.post('/upload', authenticate, uploadWarranty as any);
router.get('/client/:client_id', authenticate, getWarranties as any);

export default router;
