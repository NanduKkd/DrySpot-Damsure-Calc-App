import { DataTypes, Model } from 'sequelize';
import sequelize from '../config/database';

export class UserAdminAuditEvent extends Model {
  declare id: string;
  declare idempotencyKey: string;
  declare canonicalRequestSha256: string;
  declare outcome: 'succeeded' | 'noop' | 'rejected';
  declare createdAt: Date;
}

UserAdminAuditEvent.init(
  {
    id: { type: DataTypes.UUID, defaultValue: DataTypes.UUIDV4, primaryKey: true },
    idempotencyKey: { type: DataTypes.UUID, allowNull: false, unique: true },
    canonicalRequestSha256: { type: DataTypes.STRING(64), allowNull: false },
    actor: { type: DataTypes.STRING, allowNull: false },
    actorUid: { type: DataTypes.INTEGER, allowNull: false },
    authMode: { type: DataTypes.STRING, allowNull: false },
    scopeSnapshot: { type: DataTypes.JSON, allowNull: false },
    action: { type: DataTypes.STRING, allowNull: false },
    targetUserId: { type: DataTypes.UUID, allowNull: true },
    normalizedEmail: { type: DataTypes.STRING, allowNull: false },
    franchiseeId: { type: DataTypes.UUID, allowNull: false },
    reason: { type: DataTypes.STRING(255), allowNull: false },
    outcome: { type: DataTypes.STRING, allowNull: false },
    reasonCode: { type: DataTypes.STRING, allowNull: false },
    beforeState: { type: DataTypes.JSON, allowNull: true },
    afterState: { type: DataTypes.JSON, allowNull: true },
    hostname: { type: DataTypes.STRING, allowNull: false },
    appVersion: { type: DataTypes.STRING, allowNull: false },
    createdAt: { type: DataTypes.DATE, field: 'occurred_at' },
  },
  { sequelize, modelName: 'UserAdminAuditEvent', tableName: 'user_admin_audit_events', timestamps: false },
);
