import { DataTypes, Model } from 'sequelize';
import sequelize from '../config/database';

/**
 * Singleton allocator for the monotonic warranty-deletion cursor.
 *
 * Keeping allocation in a locked row works in both PostgreSQL and the SQLite
 * test environment and lets the tombstone's warranty UUID remain its primary
 * key.
 */
export class WarrantyDeletionSequence extends Model {
	public id!: number;
	public lastValue!: string;
}

WarrantyDeletionSequence.init(
	{
		id: {
			type: DataTypes.INTEGER,
			primaryKey: true,
			allowNull: false,
		},
		lastValue: {
			type: DataTypes.BIGINT,
			allowNull: false,
			defaultValue: 0,
		},
	},
	{
		sequelize,
		modelName: 'WarrantyDeletionSequence',
		tableName: 'warranty_deletion_sequence',
		timestamps: false,
	},
);
