import { DataTypes, Model } from 'sequelize';
import sequelize from '../config/database';

export class Rectangle extends Model {
	public id!: string;
	public itemId!: string;
	public length!: number;
	public width!: number;
	public imageData!: string | null;
	public readonly updatedAt!: Date;
	public readonly deletedAt!: Date;
}

Rectangle.init(
	{
		id: {
			type: DataTypes.UUID,
			defaultValue: DataTypes.UUIDV4,
			primaryKey: true,
		},
		itemId: {
			type: DataTypes.UUID,
			allowNull: false,
		},
		length: {
			type: DataTypes.FLOAT,
			allowNull: false,
		},
		width: {
			type: DataTypes.FLOAT,
			allowNull: false,
		},
		imageData: {
			type: DataTypes.TEXT,
			allowNull: true,
		},
		deletedAt: {
			type: DataTypes.DATE,
			allowNull: true,
		},
	},
	{
		sequelize,
		modelName: 'Rectangle',
		tableName: 'rectangles',
		paranoid: true,
	},
);
