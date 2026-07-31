import {
	CreationOptional,
	DataTypes,
	InferAttributes,
	InferCreationAttributes,
	Model,
} from 'sequelize';
import sequelize from '../config/database';

/**
 * A tenant-bound idempotency receipt for one client-photo upload.  It stores
 * only opaque IDs and the canonical managed URL; it never stores request
 * bodies, device paths, or credentials.
 */
export class ClientPhotoUpload extends Model<
	InferAttributes<ClientPhotoUpload>,
	InferCreationAttributes<ClientPhotoUpload>
> {
	declare franchiseeId: string;
	declare uploadId: string;
	declare clientId: string;
	declare fileSha256: string;
	declare canonicalUrl: string;
	declare storageKey: string;
	declare responseCursor: string;
	declare status: 'staged' | 'completed' | 'deleted';
	declare deletedAt: Date | null;
	declare createdAt: CreationOptional<Date>;
	declare updatedAt: CreationOptional<Date>;
}

ClientPhotoUpload.init(
	{
		franchiseeId: {
			type: DataTypes.UUID,
			primaryKey: true,
			allowNull: false,
		},
		uploadId: {
			type: DataTypes.UUID,
			primaryKey: true,
			allowNull: false,
		},
		clientId: {
			type: DataTypes.UUID,
			allowNull: false,
		},
		fileSha256: {
			type: DataTypes.STRING(64),
			allowNull: false,
		},
		canonicalUrl: {
			type: DataTypes.STRING(255),
			allowNull: false,
		},
		storageKey: {
			type: DataTypes.STRING(255),
			allowNull: false,
		},
		responseCursor: {
			type: DataTypes.BIGINT,
			allowNull: false,
		},
		status: {
			type: DataTypes.STRING(16),
			allowNull: false,
			defaultValue: 'staged',
		},
		deletedAt: {
			type: DataTypes.DATE,
			allowNull: true,
		},
		createdAt: DataTypes.DATE,
		updatedAt: DataTypes.DATE,
	},
	{
		sequelize,
		modelName: 'ClientPhotoUpload',
		tableName: 'client_photo_uploads',
	},
);
