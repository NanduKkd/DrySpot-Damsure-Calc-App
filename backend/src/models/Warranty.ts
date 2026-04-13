import { DataTypes, Model } from 'sequelize';
import sequelize from '../config/database';

export class Warranty extends Model {
  public id!: string;
  public clientId!: string;
  public warrantyCardNumber!: string;
  public startDate!: Date;
  public durationYears!: number;
  public pdfUrl!: string;
  public readonly createdAt!: Date;
  public readonly updatedAt!: Date;
  public readonly deletedAt!: Date;
}

Warranty.init(
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
    warrantyCardNumber: {
      type: DataTypes.STRING,
      allowNull: false,
    },
    startDate: {
      type: DataTypes.DATE,
      allowNull: false,
    },
    durationYears: {
      type: DataTypes.INTEGER,
      allowNull: false,
    },
    pdfUrl: {
      type: DataTypes.STRING,
      allowNull: false,
    },
    deletedAt: {
      type: DataTypes.DATE,
      allowNull: true,
    },
  },
  {
    sequelize,
    modelName: 'Warranty',
    tableName: 'warranties',
    paranoid: true,
  }
);
