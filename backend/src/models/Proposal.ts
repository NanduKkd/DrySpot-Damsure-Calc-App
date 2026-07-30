import { DataTypes, Model } from 'sequelize';
import sequelize from '../config/database';

export class Proposal extends Model {
  public id!: string;
  public clientId!: string;
  public pdfUrl!: string;
  public pdfFileName!: string;
  public readonly createdAt!: Date;
  public readonly updatedAt!: Date;
  public readonly deletedAt!: Date;
}

Proposal.init(
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
    pdfUrl: {
      type: DataTypes.STRING,
      allowNull: false,
    },
    pdfFileName: {
      type: DataTypes.STRING,
      allowNull: true,
    },
    deletedAt: {
      type: DataTypes.DATE,
      allowNull: true,
    },
  },
  {
    sequelize,
    modelName: 'Proposal',
    tableName: 'proposals',
    paranoid: true, // handles soft deletes
  }
);
