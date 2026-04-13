import { Request, Response } from 'express';
import { AuthRequest } from '../middleware/authMiddleware';
import { Proposal, Client } from '../models';

export const uploadProposal = async (req: AuthRequest, res: Response) => {
  const { client_id } = req.body;
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

    // The pdfUrl should be accessible via /uploads/:filename
    const pdfUrl = `${req.protocol}://${req.get('host')}/uploads/${file.filename}`;

    const proposal = await Proposal.create({
      clientId: client_id,
      pdfUrl: pdfUrl,
    });

    return res.status(201).json(proposal);
  } catch (error) {
    console.error('Proposal upload error:', error);
    return res.status(500).json({ error: 'An error occurred during proposal upload' });
  }
};

export const getProposals = async (req: AuthRequest, res: Response) => {
  const { client_id } = req.params;
  const franchiseeId = req.user?.franchiseeId;

  try {
    const client = await Client.findOne({
      where: { id: client_id, franchiseeId }
    });

    if (!client) {
      return res.status(403).json({ error: 'Unauthorized' });
    }

    const proposals = await Proposal.findAll({
      where: { clientId: client_id },
      order: [['createdAt', 'DESC']],
    });

    return res.json(proposals);
  } catch (error) {
    console.error('Get proposals error:', error);
    return res.status(500).json({ error: 'An error occurred while fetching proposals' });
  }
};

export const deleteProposal = async (req: AuthRequest, res: Response) => {
  const { id } = req.params;
  const franchiseeId = req.user?.franchiseeId;

  try {
    const proposal = await Proposal.findOne({
      where: { id },
      include: [{
        model: Client,
        where: { franchiseeId }
      }]
    });

    if (!proposal) {
      return res.status(404).json({ error: 'Proposal not found or unauthorized' });
    }

    await proposal.destroy();

    return res.status(204).send();
  } catch (error) {
    console.error('Delete proposal error:', error);
    return res.status(500).json({ error: 'An error occurred while deleting the proposal' });
  }
};
