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

  try {
    // Verify client belongs to franchisee
    const client = await Client.findOne({
      where: { id: client_id, franchiseeId }
    });

    if (!client) {
      return res.status(403).json({ error: 'Unauthorized: Client does not belong to your franchisee' });
    }

    // Enforce one-warranty rule: soft-delete any existing warranty for this client
    await Warranty.destroy({
      where: { clientId: client_id }
    });

    // The pdfUrl should be accessible via /uploads/:filename
    const pdfUrl = `${req.protocol}://${req.get('host')}/uploads/${file.filename}`;

    const warranty = await Warranty.create({
      clientId: client_id,
      startDate: new Date(start_date),
      durationYears: parseInt(duration_years),
      pdfUrl: pdfUrl,
      warrantyCardNumber: warranty_card_number,
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
