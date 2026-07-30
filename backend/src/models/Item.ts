import { DataTypes, Model } from 'sequelize';
import sequelize from '../config/database';

export class Item extends Model {
  public id!: string;
  public clientId!: string;
  public name!: string;
  public price!: number;
  public enabled!: boolean;
  public lwwGeneration!: string;
  public lwwBranchSeq!: number;
  public lwwOperationRank!: number;
  public lwwWriterId!: string;
  public lwwChangeId!: string;
  public lwwPayloadHash!: string;
  public syncCursor!: string;
  public readonly updatedAt!: Date;
  public readonly deletedAt!: Date;
}

Item.init(
  {
    id: {
      type: DataTypes.UUID,
      defaultValue: DataTypes.UUIDV4,
      primaryKey: true,
    },
    clientId: {
      type: DataTypes.UUID,
      allowNull: false,
    },
    name: {
      type: DataTypes.STRING,
      allowNull: false,
    },
    price: {
      type: DataTypes.DECIMAL(10, 2),
      allowNull: false,
      defaultValue: 0,
    },
    enabled: {
      type: DataTypes.BOOLEAN,
      allowNull: false,
      defaultValue: true,
    },
    lwwGeneration: {
      type: DataTypes.BIGINT,
      allowNull: false,
      defaultValue: '1',
    },
    lwwBranchSeq: {
      type: DataTypes.INTEGER,
      allowNull: false,
      defaultValue: 1,
    },
    lwwOperationRank: {
      type: DataTypes.SMALLINT,
      allowNull: false,
      defaultValue: 0,
    },
    lwwWriterId: {
      type: DataTypes.UUID,
      allowNull: false,
      defaultValue: DataTypes.UUIDV4,
    },
    lwwChangeId: {
      type: DataTypes.UUID,
      allowNull: false,
      defaultValue: DataTypes.UUIDV4,
    },
    lwwPayloadHash: {
      type: DataTypes.STRING(64),
      allowNull: false,
      defaultValue: '0'.repeat(64),
    },
    syncCursor: {
      type: DataTypes.BIGINT,
      allowNull: false,
      defaultValue: '1',
    },
    deletedAt: {
      type: DataTypes.DATE,
      allowNull: true,
    },
  },
  {
    sequelize,
    modelName: 'Item',
    tableName: 'items',
    paranoid: true,
  }
);
