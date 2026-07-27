import { Request, Response, NextFunction } from 'express';
import jwt from 'jsonwebtoken';
import { User } from '../models/User';
import { JWT_SECRET } from '../config/jwt';

export interface AuthRequest extends Request {
  user?: {
    id: string;
    franchiseeId: string;
  };
}

export const authenticate = async (req: AuthRequest, res: Response, next: NextFunction) => {
  const authHeader = req.headers.authorization;

  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    return res.status(401).json({ error: 'Unauthorized: No token provided' });
  }

  const token = authHeader.split(' ')[1];

  try {
    const decoded = jwt.verify(token, JWT_SECRET) as {
      id: string;
      franchiseeId: string;
      tokenVersion?: number;
    };
    const user = await User.findByPk(decoded.id);

    if (
      !user ||
      !user.isActive ||
      // Tokens minted before tokenVersion was introduced are version 0. They
      // remain valid only until an administrator revokes the user by incrementing
      // tokenVersion, preserving a safe upgrade path for existing sessions.
      (decoded.tokenVersion ?? 0) !== user.tokenVersion ||
      decoded.franchiseeId !== user.franchiseeId
    ) {
      return res.status(401).json({ error: 'Unauthorized: Invalid token' });
    }

    req.user = { id: user.id, franchiseeId: user.franchiseeId };
    next();
  } catch (error) {
    return res.status(401).json({ error: 'Unauthorized: Invalid token' });
  }
};
