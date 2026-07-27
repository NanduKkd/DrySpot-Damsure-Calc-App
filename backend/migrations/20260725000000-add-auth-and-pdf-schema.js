'use strict';

const { QueryTypes } = require('sequelize');

const hasColumn = async (queryInterface, table, column) => {
  const columns = await queryInterface.describeTable(table);
  return Object.prototype.hasOwnProperty.call(columns, column);
};

const requireTable = async (queryInterface, table) => {
  try {
    await queryInterface.describeTable(table);
  } catch (_) {
    throw new Error(
      `Required table "${table}" does not exist. This is a delta migration for an existing Damsure database; do not use it to initialise an empty database.`,
    );
  }
};

const hasActiveWarrantyIndex = async (queryInterface) => {
  const indexes = await queryInterface.showIndex('warranties');
  return indexes.some((index) =>
    index.unique &&
    index.fields.length === 1 &&
    (index.fields[0].attribute || index.fields[0].name) === 'active_client_id',
  );
};

module.exports = {
  async up(queryInterface, Sequelize) {
    await Promise.all(['users', 'warranties', 'proposals'].map((table) => requireTable(queryInterface, table)));

    if (!(await hasColumn(queryInterface, 'users', 'is_active'))) {
      await queryInterface.addColumn('users', 'is_active', {
        type: Sequelize.BOOLEAN,
        allowNull: false,
        defaultValue: true,
      });
    }
    if (!(await hasColumn(queryInterface, 'users', 'token_version'))) {
      await queryInterface.addColumn('users', 'token_version', {
        type: Sequelize.INTEGER,
        allowNull: false,
        defaultValue: 0,
      });
    }
    if (!(await hasColumn(queryInterface, 'warranties', 'pdf_file_name'))) {
      await queryInterface.addColumn('warranties', 'pdf_file_name', {
        type: Sequelize.STRING,
        allowNull: true,
      });
    }
    if (!(await hasColumn(queryInterface, 'proposals', 'pdf_file_name'))) {
      await queryInterface.addColumn('proposals', 'pdf_file_name', {
        type: Sequelize.STRING,
        allowNull: true,
      });
    }
    if (!(await hasColumn(queryInterface, 'warranties', 'active_client_id'))) {
      await queryInterface.addColumn('warranties', 'active_client_id', {
        type: Sequelize.UUID,
        allowNull: true,
      });
    }

    // Legacy databases may contain several non-deleted warranties per client.
    // Preserve the newest one as active before applying the unique guard.
    await queryInterface.bulkUpdate('warranties', { active_client_id: null }, {});
    const activeWarranties = await queryInterface.sequelize.query(
      'SELECT id, client_id FROM warranties WHERE deleted_at IS NULL ORDER BY client_id, created_at DESC, id DESC',
      { type: QueryTypes.SELECT },
    );
    const activeClientIds = new Set();
    for (const warranty of activeWarranties) {
      if (activeClientIds.has(warranty.client_id)) continue;
      activeClientIds.add(warranty.client_id);
      await queryInterface.bulkUpdate(
        'warranties',
        { active_client_id: warranty.client_id },
        { id: warranty.id },
      );
    }

    if (!(await hasActiveWarrantyIndex(queryInterface))) {
      await queryInterface.addIndex('warranties', ['active_client_id'], {
        name: 'warranties_active_client_id_unique',
        unique: true,
      });
    }
  },

  async down(queryInterface) {
    // Deliberately retain added columns and their data. Removing them would be
    // destructive after deployment; only remove the reversible uniqueness guard.
    if (await hasActiveWarrantyIndex(queryInterface)) {
      await queryInterface.removeIndex('warranties', 'warranties_active_client_id_unique');
    }
  },
};
