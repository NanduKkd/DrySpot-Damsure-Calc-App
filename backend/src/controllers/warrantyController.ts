import { Request, Response } from 'express';
import { AuthRequest } from '../middleware/authMiddleware';
import { Warranty, Client } from '../models';
import path from 'path';

export const uploadWarranty = async (req: AuthRequest, res: Response) => {
  const { client_id, start_date, duration_years, warranty_card_number } = req.body;
  const franchiseeId = req.user?.franchiseeId;
  const file = req.file;

  if (!file) {
    return res.status(400).json({ error: 'No PDF file uploaded' });
  }

  if (!franchiseeId) {
    return res.status(401).json({ error: 'Unauthorized: Franchisee ID not found in token' });
  }

  if (typeof client_id !== 'string' || client_id.trim().length === 0) {
    return res.status(400).json({ error: 'client_id is required' });
  }

  const parsedStartDate = new Date(start_date);
  if (Number.isNaN(parsedStartDate.getTime())) {
    return res.status(400).json({ error: 'start_date must be a valid date' });
  }

  const parsedDurationYears = Number.parseInt(duration_years, 10);
  if (Number.isNaN(parsedDurationYears) || parsedDurationYears <= 0) {
    return res.status(400).json({ error: 'duration_years must be a positive integer' });
  }

  if (typeof warranty_card_number !== 'string' || warranty_card_number.trim().length === 0) {
    return res.status(400).json({ error: 'warranty_card_number is required' });
  }

  try {
    // Resolve the target client first so we can return accurate error messages.
    const client = await Client.findByPk(client_id, {
      paranoid: false,
      attributes: ['id', 'franchiseeId', 'deletedAt'],
    });

    if (!client) {
      return res.status(404).json({ error: 'Client not found. Please sync client data and try again' });
    }

    if (client.franchiseeId !== franchiseeId) {
      return res.status(403).json({ error: 'Unauthorized: Client does not belong to your franchisee' });
    }

    if (client.deletedAt) {
      return res.status(409).json({ error: 'Client is deleted and cannot receive a warranty' });
    }

    // Enforce one-warranty rule: soft-delete any existing warranty for this client
    await Warranty.destroy({
      where: { clientId: client.id }
    });

    // The pdfUrl should be accessible via /uploads/:filename
    const pdfUrl = `${req.protocol}://${req.get('host')}/uploads/${file.filename}`;

    const warranty = await Warranty.create({
      clientId: client.id,
      startDate: parsedStartDate,
      durationYears: parsedDurationYears,
      pdfUrl: pdfUrl,
      warrantyCardNumber: warranty_card_number.trim(),
    });

    return res.status(201).json(warranty);
  } catch (error) {
    console.error('Warranty upload error:', error);
    return res.status(500).json({ error: 'An error occurred during warranty upload' });
  }
};

export const getWarranties = async (req: AuthRequest, res: Response) => {
  const { client_id } = req.params;
  const franchiseeId = req.user?.franchiseeId;

  try {
    const client = await Client.findOne({
      where: { id: client_id, franchiseeId }
    });

    if (!client) {
      return res.status(403).json({ error: 'Unauthorized' });
    }

    const warranties = await Warranty.findAll({
      where: { clientId: client_id },
      order: [['createdAt', 'DESC']],
    });

    return res.json(warranties);
  } catch (error) {
    console.error('Get warranties error:', error);
    return res.status(500).json({ error: 'An error occurred while fetching warranties' });
  }
};
