import {
	CreationOptional,
	DataTypes,
	InferAttributes,
	InferCreationAttributes,
	Model,
} from 'sequelize';
import sequelize from '../config/database';

export class SyncV2Request extends Model<
	InferAttributes<SyncV2Request>,
	InferCreationAttributes<SyncV2Request>
> {
	declare franchiseeId: string;
	declare requestId: string;
	declare requestHash: string;
	declare responseCursor: string;
	declare responseJson: string;
	declare createdAt: CreationOptional<Date>;
	declare updatedAt: CreationOptional<Date>;
}

SyncV2Request.init(
	{
		franchiseeId: {
			type: DataTypes.UUID,
			primaryKey: true,
			allowNull: false,
		},
		requestId: {
			type: DataTypes.UUID,
			primaryKey: true,
			allowNull: false,
		},
		requestHash: {
			type: DataTypes.STRING(64),
			allowNull: false,
		},
		responseCursor: {
			type: DataTypes.BIGINT,
			allowNull: false,
		},
		responseJson: {
			type: DataTypes.TEXT,
			allowNull: false,
		},
		createdAt: DataTypes.DATE,
		updatedAt: DataTypes.DATE,
	},
	{
		sequelize,
		modelName: 'SyncV2Request',
		tableName: 'sync_v2_requests',
	},
);
