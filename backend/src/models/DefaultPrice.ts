import {
  Model,
  DataTypes,
  InferAttributes,
  InferCreationAttributes,
  CreationOptional,
  ForeignKey,
} from 'sequelize';
import sequelize from '../config/database';
import { Franchisee } from './Franchisee';

export class DefaultPrice extends Model<
  InferAttributes<DefaultPrice>,
  InferCreationAttributes<DefaultPrice>
> {
  declare id: CreationOptional<string>;
  declare franchiseeId: ForeignKey<Franchisee['id']>;
  declare price: number;
  declare enabled: boolean;
  declare lwwGeneration: CreationOptional<string>;
  declare lwwBranchSeq: CreationOptional<number>;
  declare lwwOperationRank: CreationOptional<number>;
  declare lwwWriterId: CreationOptional<string>;
  declare lwwChangeId: CreationOptional<string>;
  declare lwwPayloadHash: CreationOptional<string>;
  declare syncCursor: CreationOptional<string>;
  declare updatedAt: CreationOptional<Date>;
  declare deletedAt: CreationOptional<Date>;
}

DefaultPrice.init(
  {
    id: {
      type: DataTypes.UUID,
      defaultValue: DataTypes.UUIDV4,
      primaryKey: true,
    },
    franchiseeId: {
      type: DataTypes.UUID,
      allowNull: false,
      references: {
        model: 'franchisees',
        key: 'id',
      },
    },
    price: {
      type: DataTypes.DECIMAL(10, 2),
      allowNull: false,
    },
    enabled: {
      type: DataTypes.BOOLEAN,
      defaultValue: true,
      allowNull: false,
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
    updatedAt: {
      type: DataTypes.DATE,
    },
    deletedAt: {
      type: DataTypes.DATE,
      allowNull: true,
    },
  },
  {
    sequelize,
    modelName: 'DefaultPrice',
    tableName: 'default_prices',
    paranoid: true,
  }
);
