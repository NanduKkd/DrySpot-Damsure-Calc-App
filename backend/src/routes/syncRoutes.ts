import { Router } from 'express';
import { sync } from '../controllers/syncController';
import { authenticate } from '../middleware/authMiddleware';

const router = Router();

router.post('/', authenticate, sync as any);

export default router;
