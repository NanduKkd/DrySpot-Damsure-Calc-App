'use strict';

const table = 'managed_file_cleanups';

module.exports = {
  async up(queryInterface, Sequelize) {
    const tables = await queryInterface.showAllTables();
    if (!tables.includes(table)) {
      await queryInterface.createTable(table, {
        id: { type: Sequelize.UUID, primaryKey: true, allowNull: false },
        storage_key: { type: Sequelize.STRING, allowNull: false, unique: true },
        kind: { type: Sequelize.STRING, allowNull: false },
        attempts: { type: Sequelize.INTEGER, allowNull: false, defaultValue: 0 },
        next_attempt_at: { type: Sequelize.DATE, allowNull: false, defaultValue: Sequelize.literal('CURRENT_TIMESTAMP') },
        last_error: { type: Sequelize.TEXT, allowNull: true },
        exhausted_at: { type: Sequelize.DATE, allowNull: true },
        created_at: { type: Sequelize.DATE, allowNull: false, defaultValue: Sequelize.literal('CURRENT_TIMESTAMP') },
        updated_at: { type: Sequelize.DATE, allowNull: false, defaultValue: Sequelize.literal('CURRENT_TIMESTAMP') },
      });
    }
    const indexes = await queryInterface.showIndex(table);
    if (!indexes.some((index) => index.name === 'managed_file_cleanups_due')) {
      await queryInterface.addIndex(table, ['exhausted_at', 'next_attempt_at'], { name: 'managed_file_cleanups_due' });
    }
  },

  async down(queryInterface) {
    // Retain retry records: dropping this table would discard unresolved
    // operational work and can strand managed-file orphans.
    const tables = await queryInterface.showAllTables();
    if (tables.includes(table)) {
      const indexes = await queryInterface.showIndex(table);
      if (indexes.some((index) => index.name === 'managed_file_cleanups_due')) {
        await queryInterface.removeIndex(table, 'managed_file_cleanups_due');
      }
    }
  },
};
