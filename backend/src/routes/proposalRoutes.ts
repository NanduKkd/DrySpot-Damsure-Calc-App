import { Router } from 'express';
import { uploadProposal, getProposals, deleteProposal } from '../controllers/proposalController';
import { authenticate } from '../middleware/authMiddleware';
import { upload } from '../middleware/uploadMiddleware';

const router = Router();

router.post('/upload', authenticate, upload.single('file'), uploadProposal as any);
router.get('/client/:client_id', authenticate, getProposals as any);
router.delete('/:id', authenticate, deleteProposal as any);

export default router;
