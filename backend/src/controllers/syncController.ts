import { Response } from 'express';
import { Op } from 'sequelize';
import { AuthRequest } from '../middleware/authMiddleware';
import { Client, Item, Rectangle, DefaultPrice, Warranty, Proposal, sequelize } from '../models';
import { queueManagedFileCleanup, reconcileManagedFileCleanupByStorageKeys } from '../services/managedFileCleanup';

class OwnershipError extends Error {}
class ParentNotFoundError extends Error {}
class ActiveWarrantyConflictError extends Error {}

const assertOwnedClient = async (id: string, franchiseeId: string, transaction: any) => {
	const client = await Client.findByPk(id, { paranoid: false, transaction });
	if (!client) throw new ParentNotFoundError('Client not found');
	if (client.franchiseeId !== franchiseeId)
		throw new OwnershipError('Client belongs to another franchisee');
	return client;
};

const assertOwnedItem = async (id: string, franchiseeId: string, transaction: any) => {
	const item = await Item.findByPk(id, { paranoid: false, transaction });
	if (!item) throw new ParentNotFoundError('Item not found');
	await assertOwnedClient(item.clientId, franchiseeId, transaction);
	return item;
};

const assertActiveOwnedClient = async (id: string, franchiseeId: string, transaction: any) => {
	const client = await assertOwnedClient(id, franchiseeId, transaction);
	if (client.deletedAt) throw new ParentNotFoundError('Client is deleted');
	return client;
};

const enforceActiveWarranty = async (
	warrantyId: string,
	clientId: string,
	replaceExisting: boolean,
	transaction: any,
) => {
	// During a rolling deploy, the pre-migration process can legitimately
	// replace a warranty without populating active_client_id. Any non-deleted
	// warranty for the client is therefore active, regardless of which
	// application version created it.
	const active = await Warranty.findAll({
		where: { clientId, id: { [Op.ne]: warrantyId } },
		transaction,
		lock: transaction.LOCK.UPDATE,
	});
	if (active.length && !replaceExisting) throw new ActiveWarrantyConflictError();
	// The old process soft-deletes a migrated warranty without clearing the
	// newly added active_client_id column. Clear the marker across history so a
	// full unique index cannot be held by that rollout-window tombstone.
	await Warranty.update(
		{ activeClientId: null },
		{
			where: { clientId },
			paranoid: false,
			transaction,
		},
	);
	for (const current of active) {
		await current.destroy({ transaction });
	}
	return active;
};

const managedPdfUrl = (resource: 'warranty' | 'proposal', id: string) =>
	`/api/${resource}/${id}/download`;

const photoUrlPattern = (clientId: string) =>
	new RegExp(
		`^/api/photos/client/${clientId}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\.(?:jpg|png|webp)$`,
		'i',
	);
const photoUrlPatternForAnyClient =
	/^\/api\/photos\/client\/[0-9a-f-]{36}\/[0-9a-f-]{36}\.(?:jpg|png|webp)$/i;

const canonicalPhotoUrls = (photos: unknown, clientId: string): string[] => {
	let values: unknown = photos;
	if (typeof photos === 'string') {
		try {
			values = JSON.parse(photos);
		} catch {
			values = [];
		}
	}
	if (!Array.isArray(values)) return [];
	const pattern = photoUrlPattern(clientId);
	return [
		...new Set(
			values.filter(
				(value): value is string => typeof value === 'string' && pattern.test(value),
			),
		),
	];
};

const canonicalPhotos = (photos: unknown, clientId: string) =>
	JSON.stringify(canonicalPhotoUrls(photos, clientId));

export const sync = async (req: AuthRequest, res: Response) => {
	const { last_sync_time, changes } = req.body;
	const franchiseeId = req.user?.franchiseeId;

	if (!franchiseeId) {
		return res.status(401).json({ error: 'Franchisee ID not found in token' });
	}

	const transaction = await sequelize.transaction();
	let committed = false;
	const storedPdfsToRemove: string[] = [];
	const storedPhotosToRemove: string[] = [];
	const queueStoredPdfRemoval = (pdfFileName?: string | null) => {
		// Only a server-generated basename may select a file for deletion. Synced
		// metadata is deliberately never permitted to populate this field.
		if (pdfFileName && !pdfFileName.includes('/') && !pdfFileName.includes('\\')) {
			storedPdfsToRemove.push(pdfFileName);
		}
	};
	const queueStoredPhotoRemoval = (photoUrl: string) => {
		const filename = photoUrl.split('/').at(-1) || '';
		if (photoUrlPatternForAnyClient.test(photoUrl)) storedPhotosToRemove.push(filename);
	};

	try {
		const serverTime = new Date().toISOString();

		// 1. Process incoming changes from client
		if (changes) {
			// Every existing remote ID is checked before it is reused.  `upsert`
			// cannot safely express this because a primary-key conflict could belong
			// to a different franchisee.
			if (changes.clients && changes.clients.length > 0) {
				for (const clientData of changes.clients) {
					const {
						remote_id,
						deleted_at,
						discounted_price,
						site_address,
						siteAddress: camelSiteAddress,
						photos,
						...rest
					} = clientData;
					const existing = await Client.findByPk(remote_id, {
						paranoid: false,
						transaction,
					});
					if (existing && existing.franchiseeId !== franchiseeId) {
						throw new OwnershipError('Client belongs to another franchisee');
					}

					if (deleted_at) {
						if (existing) {
							// A client tombstone makes its managed assets unreachable. Remove
							// their metadata in the same transaction, then clean files only
							// after the tombstone commits.
							canonicalPhotoUrls(existing.photos, existing.id).forEach(
								queueStoredPhotoRemoval,
							);
							const warranties = await Warranty.findAll({
								where: { clientId: existing.id },
								transaction,
								lock: transaction.LOCK.UPDATE,
							});
							for (const warranty of warranties) {
								queueStoredPdfRemoval(warranty.pdfFileName);
								await warranty.update({ activeClientId: null }, { transaction });
								await warranty.destroy({ transaction });
							}
							const proposals = await Proposal.findAll({
								where: { clientId: existing.id },
								transaction,
								lock: transaction.LOCK.UPDATE,
							});
							for (const proposal of proposals) {
								queueStoredPdfRemoval(proposal.pdfFileName);
								await proposal.destroy({ transaction });
							}
							await existing.destroy({ transaction });
						}
					} else {
						const existingPhotos = existing
							? canonicalPhotoUrls(existing.photos, remote_id)
							: [];
						const syncedPhotos =
							photos === undefined
								? undefined
								: existing
									? canonicalPhotoUrls(photos, remote_id).filter((photo) =>
											existingPhotos.includes(photo),
										)
									: [];
						if (syncedPhotos) {
							existingPhotos
								.filter((photo) => !syncedPhotos.includes(photo))
								.forEach(queueStoredPhotoRemoval);
						}
						const values = {
							...rest,
							id: remote_id,
							franchiseeId,
							discountedPrice: discounted_price,
							siteAddress: site_address ?? camelSiteAddress,
							...(syncedPhotos === undefined
								? {}
								: { photos: JSON.stringify(syncedPhotos) }),
						};
						if (existing) await existing.update(values, { transaction });
						else await Client.create(values, { transaction });
					}
				}
			}

			// Upsert Items
			if (changes.items && changes.items.length > 0) {
				for (const itemData of changes.items) {
					const { remote_id, client_id, deleted_at, ...rest } = itemData;
					const existing = await Item.findByPk(remote_id, {
						paranoid: false,
						transaction,
					});
					if (existing)
						await assertOwnedClient(existing.clientId, franchiseeId, transaction);

					if (deleted_at) {
						if (existing) await existing.destroy({ transaction });
					} else {
						await assertOwnedClient(client_id, franchiseeId, transaction);
						const values = { ...rest, id: remote_id, clientId: client_id };
						if (existing) await existing.update(values, { transaction });
						else await Item.create(values, { transaction });
					}
				}
			}

			// Upsert Rectangles
			if (changes.rectangles && changes.rectangles.length > 0) {
				for (const rectData of changes.rectangles) {
					const { remote_id, item_id, deleted_at, image_data, ...rest } = rectData;
					const existing = await Rectangle.findByPk(remote_id, {
						paranoid: false,
						transaction,
					});
					if (existing) await assertOwnedItem(existing.itemId, franchiseeId, transaction);

					if (deleted_at) {
						if (existing) await existing.destroy({ transaction });
					} else {
						await assertOwnedItem(item_id, franchiseeId, transaction);
						const values = {
							...rest,
							id: remote_id,
							itemId: item_id,
							imageData: image_data,
						};
						if (existing) await existing.update(values, { transaction });
						else await Rectangle.create(values, { transaction });
					}
				}
			}

			// Upsert Default Prices
			if (changes.default_prices && changes.default_prices.length > 0) {
				for (const dpData of changes.default_prices) {
					const { remote_id, deleted_at, ...rest } = dpData;
					const existing = await DefaultPrice.findByPk(remote_id, {
						paranoid: false,
						transaction,
					});
					if (existing && existing.franchiseeId !== franchiseeId) {
						throw new OwnershipError('Default price belongs to another franchisee');
					}

					if (deleted_at) {
						if (existing) await existing.destroy({ transaction });
					} else {
						const values = { ...rest, id: remote_id, franchiseeId };
						if (existing) await existing.update(values, { transaction });
						else await DefaultPrice.create(values, { transaction });
					}
				}
			}

			// Upsert Warranties
			if (changes.warranties && changes.warranties.length > 0) {
				for (const wData of changes.warranties) {
					const {
						remote_id,
						client_id,
						deleted_at,
						start_date,
						duration_years,
						warranty_card_number,
						// PDF location/filename and active state are server-managed.  Sync
						// clients must not be able to point a tenant-owned record at another
						// tenant's file or fabricate a download path.
						pdf_url: _pdfUrl,
						pdfUrl: _camelPdfUrl,
						pdf_file_name: _pdfFileName,
						pdfFileName: _camelPdfFileName,
						active_client_id: _activeClientId,
						activeClientId: _camelActiveClientId,
						replace_existing,
						...rest
					} = wData;
					const existing = await Warranty.findByPk(remote_id, {
						paranoid: false,
						transaction,
					});
					if (existing)
						await assertOwnedClient(existing.clientId, franchiseeId, transaction);

					if (deleted_at) {
						if (existing) {
							queueStoredPdfRemoval(existing.pdfFileName);
							await existing.update({ activeClientId: null }, { transaction });
							await existing.destroy({ transaction });
						}
					} else {
						await assertActiveOwnedClient(client_id, franchiseeId, transaction);
						const replaced = await enforceActiveWarranty(
							remote_id,
							client_id,
							replace_existing === true,
							transaction,
						);
						replaced.forEach((current) => queueStoredPdfRemoval(current.pdfFileName));
						const values = {
							...rest,
							id: remote_id,
							clientId: client_id,
							activeClientId: client_id,
							startDate: start_date,
							durationYears: duration_years,
							warrantyCardNumber: warranty_card_number,
							...(existing
								? {}
								: {
										pdfUrl: managedPdfUrl('warranty', remote_id),
										pdfFileName: null,
									}),
						};
						if (existing) await existing.update(values, { transaction });
						else await Warranty.create(values, { transaction });
					}
				}
			}

			// Upsert Proposals
			if (changes.proposals && changes.proposals.length > 0) {
				for (const pData of changes.proposals) {
					const {
						remote_id,
						client_id,
						deleted_at,
						pdf_url: _pdfUrl,
						pdfUrl: _camelPdfUrl,
						pdf_file_name: _pdfFileName,
						pdfFileName: _camelPdfFileName,
						...rest
					} = pData;
					const existing = await Proposal.findByPk(remote_id, {
						paranoid: false,
						transaction,
					});
					if (existing)
						await assertOwnedClient(existing.clientId, franchiseeId, transaction);

					if (deleted_at) {
						if (existing) {
							queueStoredPdfRemoval(existing.pdfFileName);
							await existing.destroy({ transaction });
						}
					} else {
						await assertActiveOwnedClient(client_id, franchiseeId, transaction);
						const values = {
							...rest,
							id: remote_id,
							clientId: client_id,
							...(existing
								? {}
								: {
										pdfUrl: managedPdfUrl('proposal', remote_id),
										pdfFileName: null,
									}),
						};
						if (existing) await existing.update(values, { transaction });
						else await Proposal.create(values, { transaction });
					}
				}
			}
		}

		for (const filename of storedPdfsToRemove) {
			await queueManagedFileCleanup('pdf', filename, transaction);
		}
		for (const filename of storedPhotosToRemove) {
			await queueManagedFileCleanup('photo', filename, transaction);
		}
		await transaction.commit();
		committed = true;
		await reconcileManagedFileCleanupByStorageKeys([
			...storedPdfsToRemove,
			...storedPhotosToRemove,
		]);

		// 2. Fetch updates for the client
		const syncTime = last_sync_time ? new Date(last_sync_time) : new Date(0);

		const updatedClients = await Client.findAll({
			where: {
				franchiseeId,
				updatedAt: { [Op.gt]: syncTime },
			},
			paranoid: false,
		});

		// Get all client IDs for this franchisee to filter child entities
		const allFranchiseeClients = await Client.findAll({
			where: { franchiseeId },
			attributes: ['id'],
			paranoid: false,
		});
		const allClientIds = allFranchiseeClients.map((c) => c.id);

		const updatedItems = await Item.findAll({
			where: {
				clientId: { [Op.in]: allClientIds },
				updatedAt: { [Op.gt]: syncTime },
			},
			paranoid: false,
		});

		const allFranchiseeItems = await Item.findAll({
			where: { clientId: { [Op.in]: allClientIds } },
			attributes: ['id'],
			paranoid: false,
		});
		const allItemIds = allFranchiseeItems.map((i) => i.id);

		const updatedRectangles = await Rectangle.findAll({
			where: {
				itemId: { [Op.in]: allItemIds },
				updatedAt: { [Op.gt]: syncTime },
			},
			paranoid: false,
		});

		const updatedDefaultPrices = await DefaultPrice.findAll({
			where: {
				franchiseeId,
				updatedAt: { [Op.gt]: syncTime },
			},
			paranoid: false,
		});

		const updatedWarranties = await Warranty.findAll({
			where: {
				clientId: { [Op.in]: allClientIds },
				updatedAt: { [Op.gt]: syncTime },
			},
			paranoid: false,
		});

		const updatedProposals = await Proposal.findAll({
			where: {
				clientId: { [Op.in]: allClientIds },
				updatedAt: { [Op.gt]: syncTime },
			},
			paranoid: false,
		});

		return res.json({
			server_time: serverTime,
			updates: {
				clients: updatedClients.map((c) => ({
					remote_id: c.id,
					franchisee_id: c.franchiseeId,
					name: c.name,
					address: c.address,
					email: c.email,
					phone: c.phone,
					latitude: c.latitude,
					longitude: c.longitude,
					photos: canonicalPhotos(c.photos, c.id),
					discounted_price: c.discountedPrice,
					site_address: (c as any).siteAddress,
					updated_at: c.updatedAt.toISOString(),
					deleted_at: c.deletedAt ? c.deletedAt.toISOString() : null,
				})),
				items: updatedItems.map((i) => ({
					remote_id: i.id,
					client_id: i.clientId,
					name: i.name,
					price: i.price,
					enabled: i.enabled,
					updated_at: i.updatedAt.toISOString(),
					deleted_at: i.deletedAt ? i.deletedAt.toISOString() : null,
				})),
				rectangles: updatedRectangles.map((r) => ({
					remote_id: r.id,
					item_id: r.itemId,
					length: r.length,
					width: r.width,
					image_data: r.imageData,
					updated_at: r.updatedAt.toISOString(),
					deleted_at: r.deletedAt ? r.deletedAt.toISOString() : null,
				})),
				default_prices: updatedDefaultPrices.map((dp) => ({
					remote_id: dp.id,
					price: dp.price,
					enabled: dp.enabled,
					updated_at: dp.updatedAt.toISOString(),
					deleted_at: dp.deletedAt ? dp.deletedAt.toISOString() : null,
				})),
				warranties: updatedWarranties.map((w) => ({
					remote_id: w.id,
					client_id: w.clientId,
					start_date: w.startDate.toISOString(),
					duration_years: w.durationYears,
					pdf_url: w.pdfUrl,
					warranty_card_number: w.warrantyCardNumber,
					updated_at: w.updatedAt.toISOString(),
					deleted_at: w.deletedAt ? w.deletedAt.toISOString() : null,
				})),
				proposals: updatedProposals.map((p) => ({
					remote_id: p.id,
					client_id: p.clientId,
					pdf_url: p.pdfUrl,
					updated_at: p.updatedAt.toISOString(),
					deleted_at: p.deletedAt ? p.deletedAt.toISOString() : null,
				})),
			},
		});
	} catch (error) {
		if (!committed) await transaction.rollback();
		if (error instanceof OwnershipError) {
			return res.status(403).json({ error: 'Cross-franchisee sync mutation is forbidden' });
		}
		if (error instanceof ParentNotFoundError) {
			return res
				.status(400)
				.json({ error: 'Sync mutation references a missing parent record' });
		}
		if (error instanceof ActiveWarrantyConflictError) {
			return res.status(409).json({
				error: 'An active warranty already exists. Set replace_existing to true to replace it.',
			});
		}
		console.error('Sync error:', error);
		return res.status(500).json({ error: 'An error occurred during sync' });
	}
};
