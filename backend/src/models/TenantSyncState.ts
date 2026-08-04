import {
	CreationOptional,
	DataTypes,
	InferAttributes,
	InferCreationAttributes,
	Model,
} from 'sequelize';
import sequelize from '../config/database';

export class TenantSyncState extends Model<
	InferAttributes<TenantSyncState>,
	InferCreationAttributes<TenantSyncState>
> {
	declare franchiseeId: string;
	declare cursor: CreationOptional<string>;
	declare createdAt: CreationOptional<Date>;
	declare updatedAt: CreationOptional<Date>;
}

TenantSyncState.init(
	{
		franchiseeId: {
			type: DataTypes.UUID,
			primaryKey: true,
			allowNull: false,
		},
		cursor: {
			type: DataTypes.BIGINT,
			allowNull: false,
			defaultValue: '1',
		},
		createdAt: DataTypes.DATE,
		updatedAt: DataTypes.DATE,
	},
	{
		sequelize,
		modelName: 'TenantSyncState',
		tableName: 'tenant_sync_state',
	},
);
