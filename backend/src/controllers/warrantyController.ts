import { Response } from 'express';
import { AuthRequest } from '../middleware/authMiddleware';
import { Warranty, Client } from '../models';

export const uploadWarranty = async (req: AuthRequest, res: Response) => {
  const { client_id, start_date, duration_years } = req.body;
  const franchiseeId = req.user?.franchiseeId;

  try {
    // Verify client belongs to franchisee
    const client = await Client.findOne({
      where: { id: client_id, franchiseeId }
    });

    if (!client) {
      return res.status(403).json({ error: 'Unauthorized: Client does not belong to your franchisee' });
    }

    // In a real app, we would handle the multipart file upload here.
    // For this implementation, we'll assume the file is uploaded and we get a URL.
    const pdfUrl = `https://storage.example.com/warranties/${client_id}_${Date.now()}.pdf`;

    const warranty = await Warranty.create({
      clientId: client_id,
      startDate: new Date(start_date),
      durationYears: parseInt(duration_years),
      pdfUrl: pdfUrl,
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
