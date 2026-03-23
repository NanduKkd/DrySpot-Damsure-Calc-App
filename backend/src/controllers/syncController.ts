import { Response } from 'express';
import { Op } from 'sequelize';
import { AuthRequest } from '../middleware/authMiddleware';
import { Client, Item, Rectangle, DefaultPrice, sequelize } from '../models';

export const sync = async (req: AuthRequest, res: Response) => {
  const { last_sync_time, changes } = req.body;
  const franchiseeId = req.user?.franchiseeId;

  if (!franchiseeId) {
    return res.status(401).json({ error: 'Franchisee ID not found in token' });
  }

  const transaction = await sequelize.transaction();

  try {
    const serverTime = new Date().toISOString();

    // 1. Process incoming changes from client
    if (changes) {
      // Upsert Clients
      if (changes.clients && changes.clients.length > 0) {
        for (const clientData of changes.clients) {
          const { remote_id, deleted_at, discounted_price, ...rest } = clientData;
          
          if (deleted_at) {
              await Client.destroy({ where: { id: remote_id, franchiseeId }, transaction });
          } else {
              await Client.upsert({
                  id: remote_id,
                  franchiseeId,
                  discountedPrice: discounted_price,
                  ...rest
              }, { transaction });
          }
        }
      }

      // Upsert Items
      if (changes.items && changes.items.length > 0) {
        for (const itemData of changes.items) {
          const { remote_id, client_id, deleted_at, ...rest } = itemData;
          
          if (deleted_at) {
              await Item.destroy({ where: { id: remote_id }, transaction });
          } else {
              await Item.upsert({
                  id: remote_id,
                  clientId: client_id,
                  ...rest
              }, { transaction });
          }
        }
      }

      // Upsert Rectangles
      if (changes.rectangles && changes.rectangles.length > 0) {
        for (const rectData of changes.rectangles) {
          const { remote_id, item_id, deleted_at, ...rest } = rectData;
          
          if (deleted_at) {
              await Rectangle.destroy({ where: { id: remote_id }, transaction });
          } else {
              await Rectangle.upsert({
                  id: remote_id,
                  itemId: item_id,
                  ...rest
              }, { transaction });
          }
        }
      }

      // Upsert Default Prices
      if (changes.default_prices && changes.default_prices.length > 0) {
        for (const dpData of changes.default_prices) {
          const { remote_id, deleted_at, ...rest } = dpData;
          
          if (deleted_at) {
              await DefaultPrice.destroy({ where: { id: remote_id, franchiseeId }, transaction });
          } else {
              await DefaultPrice.upsert({
                  id: remote_id,
                  franchiseeId,
                  ...rest
              }, { transaction });
          }
        }
      }
    }

    await transaction.commit();

    // 2. Fetch updates for the client
    const syncTime = last_sync_time ? new Date(last_sync_time) : new Date(0);

    const updatedClients = await Client.findAll({
      where: {
        franchiseeId,
        updatedAt: { [Op.gt]: syncTime },
      },
      paranoid: false,
    });

    // Also need items and rectangles related to the franchisee's clients
    // But since clients can be updated without their items being updated,
    // and items can be updated without their clients being updated,
    // we should ideally fetch all items/rectangles updated after syncTime
    // that belong to the franchisee's clients.

    // Get all client IDs for this franchisee to filter items and rectangles
    const allFranchiseeClients = await Client.findAll({
        where: { franchiseeId },
        attributes: ['id'],
        paranoid: false
    });
    const allClientIds = allFranchiseeClients.map(c => c.id);

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
        paranoid: false
    });
    const allItemIds = allFranchiseeItems.map(i => i.id);

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

    return res.json({
      server_time: serverTime,
      updates: {
        clients: updatedClients.map(c => ({
          remote_id: c.id,
          name: c.name,
          address: c.address,
          email: c.email,
          phone: c.phone,
          latitude: c.latitude,
          longitude: c.longitude,
          photos: c.photos,
          discounted_price: c.discountedPrice,
          updated_at: c.updatedAt.toISOString(),
          deleted_at: c.deletedAt ? c.deletedAt.toISOString() : null,
        })),
        items: updatedItems.map(i => ({
          remote_id: i.id,
          client_id: i.clientId,
          name: i.name,
          price: i.price,
          enabled: i.enabled,
          updated_at: i.updatedAt.toISOString(),
          deleted_at: i.deletedAt ? i.deletedAt.toISOString() : null,
        })),
        rectangles: updatedRectangles.map(r => ({
          remote_id: r.id,
          item_id: r.itemId,
          length: r.length,
          width: r.width,
          updated_at: r.updatedAt.toISOString(),
          deleted_at: r.deletedAt ? r.deletedAt.toISOString() : null,
        })),
        default_prices: updatedDefaultPrices.map(dp => ({
          remote_id: dp.id,
          price: dp.price,
          enabled: dp.enabled,
          updated_at: dp.updatedAt.toISOString(),
          deleted_at: dp.deletedAt ? dp.deletedAt.toISOString() : null,
        })),
      },
    });
  } catch (error) {
    await transaction.rollback();
    console.error('Sync error:', error);
    return res.status(500).json({ error: 'An error occurred during sync' });
  }
};
