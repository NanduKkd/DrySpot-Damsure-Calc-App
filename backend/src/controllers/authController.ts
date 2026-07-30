import { Request, Response } from 'express';
import bcrypt from 'bcrypt';
import jwt from 'jsonwebtoken';
import { User } from '../models/User';
import { Franchisee } from '../models/Franchisee';
import { JWT_SECRET } from '../config/jwt';

export const login = async (req: Request, res: Response) => {
  const { email, password } = req.body;

  try {
    const user = await User.findOne({ 
      where: { email },
      include: [{ model: Franchisee }]
    });

    if (!user || !user.isActive) {
      return res.status(401).json({ error: 'Invalid email or password' });
    }

    const isMatch = await bcrypt.compare(password, user.password);

    if (!isMatch) {
      return res.status(401).json({ error: 'Invalid email or password' });
    }

    const token = jwt.sign(
      { id: user.id, franchiseeId: user.franchiseeId, tokenVersion: user.tokenVersion },
      JWT_SECRET,
      { expiresIn: '30d' }
    );

    return res.json({
      token,
      user: {
        id: user.id,
        name: user.name,
        email: user.email,
        franchisee_id: user.franchiseeId,
        franchisee_name: (user as any).Franchisee?.name,
      },
    });
  } catch (error) {
    console.error('Login error:', error);
    return res.status(500).json({ error: 'An error occurred during login' });
  }
};

export const register = async (req: Request, res: Response) => {
  // Accounts are provisioned by a trusted administrative workflow.  Leaving a
  // public endpoint here made arbitrary franchisee membership self-service.
  return res.status(403).json({ error: 'Public registration is disabled' });
};
