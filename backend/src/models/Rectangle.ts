import { DataTypes, Model } from 'sequelize';
import sequelize from '../config/database';

export class Rectangle extends Model {
	public id!: string;
	public itemId!: string;
	public length!: number;
	public width!: number;
	public imageData!: string | null;
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
		modelName: 'Rectangle',
		tableName: 'rectangles',
		paranoid: true,
	},
);
