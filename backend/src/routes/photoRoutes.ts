import { Router } from 'express';
import { deletePhoto, downloadPhoto, uploadPhoto } from '../controllers/photoController';
import { authenticate } from '../middleware/authMiddleware';
import { parsePhotoUpload } from '../middleware/photoUploadMiddleware';

const router = Router();

router.post('/client/:client_id', authenticate, parsePhotoUpload, uploadPhoto as any);
router.get('/client/:client_id/:filename', authenticate, downloadPhoto as any);
router.delete('/client/:client_id/:filename', authenticate, deletePhoto as any);

export default router;
