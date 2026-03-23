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
