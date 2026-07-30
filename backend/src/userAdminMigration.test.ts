import { Franchisee, User, sequelize } from './models';

// eslint-disable-next-line @typescript-eslint/no-var-requires
const migration = require('../migrations/20260730020000-add-user-admin-lifecycle.js');

describe('APP-108 migration', () => {
  it('redacts normalization collisions and preserves data on non-destructive down/reapply', async () => {
    const queryInterface = sequelize.getQueryInterface();
    await Franchisee.findOrCreate({ where: { id: '10000000-0000-4000-8000-000000000001' }, defaults: { name: 'migration tenant' } });
    await migration.down(queryInterface);
    await User.create({ id: '50000000-0000-4000-8000-000000000001', name: 'One', email: 'Case@Example.com', password: 'hash', franchiseeId: '10000000-0000-4000-8000-000000000001', isActive: true, tokenVersion: 0 });
    await User.create({ id: '50000000-0000-4000-8000-000000000002', name: 'Two', email: 'case@example.com', password: 'hash', franchiseeId: '10000000-0000-4000-8000-000000000001', isActive: true, tokenVersion: 0 });
    await expect(migration.up(queryInterface, (await import('sequelize')).Sequelize)).rejects.toThrow('case-fold collisions');
    await User.destroy({ where: { id: '50000000-0000-4000-8000-000000000002' } });
    await migration.up(queryInterface, (await import('sequelize')).Sequelize);
    await migration.down(queryInterface);
    expect(await User.findByPk('50000000-0000-4000-8000-000000000001')).not.toBeNull();
    await migration.up(queryInterface, (await import('sequelize')).Sequelize);
    await User.destroy({ where: { id: '50000000-0000-4000-8000-000000000001' } });
  });
});
