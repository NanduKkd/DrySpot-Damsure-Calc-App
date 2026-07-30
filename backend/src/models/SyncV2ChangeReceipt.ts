import {
	CreationOptional,
	DataTypes,
	InferAttributes,
	InferCreationAttributes,
	Model,
} from 'sequelize';
import sequelize from '../config/database';

export class SyncV2ChangeReceipt extends Model<
	InferAttributes<SyncV2ChangeReceipt>,
	InferCreationAttributes<SyncV2ChangeReceipt>
> {
	declare franchiseeId: string;
	declare changeId: string;
	declare entityType: string;
	declare entityId: string;
	declare generation: string;
	declare branchSeq: number;
	declare operationRank: number;
	declare writerId: string;
	declare payloadHash: string;
	declare createdAt: CreationOptional<Date>;
	declare updatedAt: CreationOptional<Date>;
}

SyncV2ChangeReceipt.init(
	{
		franchiseeId: {
			type: DataTypes.UUID,
			primaryKey: true,
			allowNull: false,
		},
		changeId: {
			type: DataTypes.UUID,
			primaryKey: true,
			allowNull: false,
		},
		entityType: {
			type: DataTypes.STRING(32),
			allowNull: false,
		},
		entityId: {
			type: DataTypes.UUID,
			allowNull: false,
		},
		generation: {
			type: DataTypes.BIGINT,
			allowNull: false,
		},
		branchSeq: {
			type: DataTypes.INTEGER,
			allowNull: false,
		},
		operationRank: {
			type: DataTypes.SMALLINT,
			allowNull: false,
		},
		writerId: {
			type: DataTypes.UUID,
			allowNull: false,
		},
		payloadHash: {
			type: DataTypes.STRING(64),
			allowNull: false,
		},
		createdAt: DataTypes.DATE,
		updatedAt: DataTypes.DATE,
	},
	{
		sequelize,
		modelName: 'SyncV2ChangeReceipt',
		tableName: 'sync_v2_change_receipts',
	},
);
