import { DataTypes, Model } from 'sequelize';
import sequelize from '../config/database';

export type ManagedFileKind = 'pdf' | 'photo';

/** A durable request to remove a server-managed upload after its metadata is gone. */
export class ManagedFileCleanup extends Model {
  public id!: string;
  public storageKey!: string;
  public kind!: ManagedFileKind;
  public attempts!: number;
  public nextAttemptAt!: Date;
  public lastError!: string | null;
  public exhaustedAt!: Date | null;
  public readonly createdAt!: Date;
  public readonly updatedAt!: Date;
}

ManagedFileCleanup.init(
  {
    id: {
      type: DataTypes.UUID,
      defaultValue: DataTypes.UUIDV4,
      primaryKey: true,
    },
    storageKey: {
      type: DataTypes.STRING,
      allowNull: false,
      unique: true,
    },
    kind: {
      type: DataTypes.STRING,
      allowNull: false,
    },
    attempts: {
      type: DataTypes.INTEGER,
      allowNull: false,
      defaultValue: 0,
    },
    nextAttemptAt: {
      type: DataTypes.DATE,
      allowNull: false,
      defaultValue: DataTypes.NOW,
    },
    lastError: {
      type: DataTypes.TEXT,
      allowNull: true,
    },
    exhaustedAt: {
      type: DataTypes.DATE,
      allowNull: true,
    },
  },
  {
    sequelize,
    modelName: 'ManagedFileCleanup',
    tableName: 'managed_file_cleanups',
  },
);
