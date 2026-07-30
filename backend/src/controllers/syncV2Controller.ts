import { Response } from 'express';
import { AuthRequest } from '../middleware/authMiddleware';
import { sequelize } from '../models';
import {
	executeSyncV2,
	parseSyncV2Envelope,
	SyncEnvelopeError,
	SyncTenantAuthorizationError,
} from '../services/lwwSync';

export const syncV2 = async (req: AuthRequest, res: Response) => {
	const franchiseeId = req.user?.franchiseeId;
	if (!franchiseeId) {
		return res.status(401).json({
			error: {
				code: 'unauthenticated',
				message: 'Authentication is required.',
			},
		});
	}

	try {
		// Complete structural validation happens before a transaction can mutate
		// authoritative state. Per-change business validation happens only after
		// tenancy preflight has proved that the entire opaque identifier set is safe.
		const envelope = parseSyncV2Envelope(req.body);
		const response = await executeSyncV2(envelope, franchiseeId, sequelize);
		return res.json(response);
	} catch (error) {
		if (error instanceof SyncEnvelopeError) {
			return res.status(error.status).json({
				error: {
					code: error.code,
					message: error.message,
				},
			});
		}
		if (error instanceof SyncTenantAuthorizationError) {
			return res.status(403).json({
				error: {
					code: 'unauthorized',
					message: 'The sync request is not authorized.',
				},
				outcomes: error.outcomes,
			});
		}
		console.error('Sync v2 error:', error);
		return res.status(500).json({
			error: {
				code: 'sync_failed',
				message: 'The sync request could not be completed.',
			},
		});
	}
};
