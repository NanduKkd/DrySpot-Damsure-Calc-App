import { Router } from 'express';
import { sync } from '../controllers/syncController';
import { syncV2 } from '../controllers/syncV2Controller';
import { authenticate } from '../middleware/authMiddleware';

const router = Router();

router.post('/', authenticate, sync as any);
router.post('/v2', authenticate, syncV2 as any);

export default router;
