import { DataTypes, Model } from 'sequelize';
import sequelize from '../config/database';

/**
 * Permanent, minimal proof that a warranty UUID can never be live again.
 *
 * The tenant is retained for authorization and sync delivery. The optional
 * idempotency/replacement fields are the minimum replay state required after
 * the source warranty has been hard-deleted.
 */
export class WarrantyDeletionTombstone extends Model {
	public warrantyId!: string;
	public franchiseeId!: string;
	public deletionSequence!: string;
	public idempotencyKey!: string | null;
	public idempotencyAction!: string | null;
	public requestDigest!: string | null;
	public replacementWarrantyId!: string | null;
	public deletedAt!: Date;
}

WarrantyDeletionTombstone.init(
	{
		warrantyId: {
			type: DataTypes.UUID,
			primaryKey: true,
			allowNull: false,
		},
		franchiseeId: {
			type: DataTypes.UUID,
			allowNull: false,
		},
		deletionSequence: {
			type: DataTypes.BIGINT,
			allowNull: false,
			unique: true,
		},
		idempotencyKey: {
			type: DataTypes.STRING(128),
			allowNull: true,
		},
		idempotencyAction: {
			type: DataTypes.STRING(32),
			allowNull: true,
		},
		requestDigest: {
			type: DataTypes.STRING(64),
			allowNull: true,
		},
		replacementWarrantyId: {
			type: DataTypes.UUID,
			allowNull: true,
		},
		deletedAt: {
			type: DataTypes.DATE,
			allowNull: false,
		},
	},
	{
		sequelize,
		modelName: 'WarrantyDeletionTombstone',
		tableName: 'warranty_deletion_tombstones',
		timestamps: false,
		indexes: [
			{
				name: 'warranty_deletion_tombstones_tenant_cursor',
				fields: ['franchisee_id', 'deletion_sequence'],
			},
			{
				name: 'warranty_deletion_tombstones_tenant_idempotency_unique',
				unique: true,
				fields: ['franchisee_id', 'idempotency_key'],
			},
		],
	},
);
