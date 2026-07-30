import { Response } from 'express';
import { randomUUID } from 'crypto';
import path from 'path';
import { AuthRequest } from '../middleware/authMiddleware';
import { Proposal, Client } from '../models';
import { removeStoredPdf, removeUploadedFile } from '../middleware/uploadMiddleware';

const pdfUrlFor = (id: string) => `/api/proposal/${id}/download`;

export const uploadProposal = async (req: AuthRequest, res: Response) => {
  const file = req.file;
  if (!file) return res.status(400).json({ error: 'No PDF file uploaded' });
  try {
    const client = await Client.findOne({ where: { id: req.body.client_id, franchiseeId: req.user?.franchiseeId } });
    if (!client) {
      await removeUploadedFile(file);
      return res.status(403).json({ error: 'Unauthorized: Client does not belong to your franchisee' });
    }
    const id = randomUUID();
    const proposal = await Proposal.create({ id, clientId: client.id, pdfUrl: pdfUrlFor(id), pdfFileName: file.filename });
    return res.status(201).json(proposal);
  } catch (error) {
    await removeUploadedFile(file);
    console.error('Proposal upload error:', error);
    return res.status(500).json({ error: 'An error occurred during proposal upload' });
  }
};

export const getProposals = async (req: AuthRequest, res: Response) => {
  const client = await Client.findOne({ where: { id: req.params.client_id, franchiseeId: req.user?.franchiseeId } });
  if (!client) return res.status(403).json({ error: 'Unauthorized' });
  return res.json(await Proposal.findAll({ where: { clientId: client.id }, order: [['createdAt', 'DESC']] }));
};

export const downloadProposal = async (req: AuthRequest, res: Response) => {
  const proposal = await Proposal.findOne({ where: { id: req.params.id }, include: [{ model: Client, where: { franchiseeId: req.user?.franchiseeId } }] });
  if (!proposal) return res.status(404).json({ error: 'Proposal not found or unauthorized' });
  const filename = proposal.pdfFileName || path.basename(new URL(proposal.pdfUrl, 'http://localhost').pathname);
  return res.type('application/pdf').sendFile(path.join(__dirname, '../../uploads', filename), (error) => {
    if (error && !res.headersSent) res.status(404).json({ error: 'Proposal PDF not found' });
  });
};

export const deleteProposal = async (req: AuthRequest, res: Response) => {
  const proposal = await Proposal.findOne({ where: { id: req.params.id }, include: [{ model: Client, where: { franchiseeId: req.user?.franchiseeId } }] });
  if (!proposal) return res.status(404).json({ error: 'Proposal not found or unauthorized' });
  const pdfUrl = proposal.pdfUrl;
  await proposal.destroy();
  await removeStoredPdf(pdfUrl, proposal.pdfFileName);
  return res.status(204).send();
};
