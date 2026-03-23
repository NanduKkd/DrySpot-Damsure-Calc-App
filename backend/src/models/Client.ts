import { DataTypes, Model } from 'sequelize';
import sequelize from '../config/database';

export class Client extends Model {
  public id!: string;
  public franchiseeId!: string;
  public name!: string;
  public address!: string;
  public email!: string;
  public phone!: string;
  public latitude!: number;
  public longitude!: number;
  public photos!: string; // JSON String
  public discountedPrice!: number | null;
  public readonly updatedAt!: Date;
  public readonly deletedAt!: Date;
}

Client.init(
  {
    id: {
      type: DataTypes.UUID,
      defaultValue: DataTypes.UUIDV4,
      primaryKey: true,
    },
    franchiseeId: {
      type: DataTypes.UUID,
      allowNull: false,
    },
    name: {
      type: DataTypes.STRING,
      allowNull: false,
    },
    address: {
      type: DataTypes.STRING,
      allowNull: true,
    },
    email: {
      type: DataTypes.STRING,
      allowNull: true,
      validate: {
        isEmail: true,
      },
      set(val: string | null) {
        this.setDataValue('email', val === '' ? null : val);
      },
    },
    phone: {
      type: DataTypes.STRING,
      allowNull: true,
    },
    latitude: {
      type: DataTypes.FLOAT,
      allowNull: true,
    },
    longitude: {
      type: DataTypes.FLOAT,
      allowNull: true,
    },
    photos: {
      type: DataTypes.TEXT,
      allowNull: true,
      defaultValue: '[]',
    },
    discountedPrice: {
      type: DataTypes.FLOAT,
      allowNull: true,
    },
    deletedAt: {
      type: DataTypes.DATE,
      allowNull: true,
    },
  },
  {
    sequelize,
    modelName: 'Client',
    tableName: 'clients',
    paranoid: true, // handles soft deletes
  }
);
