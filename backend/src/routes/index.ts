import { Router } from 'express';
import authRoutes from './authRoutes';
import syncRoutes from './syncRoutes';
import warrantyRoutes from './warrantyRoutes';
import proposalRoutes from './proposalRoutes';
import photoRoutes from './photoRoutes';

const router = Router();

router.use('/auth', authRoutes);
router.use('/sync', syncRoutes);
router.use('/warranty', warrantyRoutes);
router.use('/proposal', proposalRoutes);
router.use('/photos', photoRoutes);

export default router;
