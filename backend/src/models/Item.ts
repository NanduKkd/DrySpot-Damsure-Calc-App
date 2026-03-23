import { DataTypes, Model } from 'sequelize';
import sequelize from '../config/database';

export class Item extends Model {
  public id!: string;
  public clientId!: string;
  public name!: string;
  public price!: number;
  public enabled!: boolean;
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
