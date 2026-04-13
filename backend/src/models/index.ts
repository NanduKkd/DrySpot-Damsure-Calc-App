import sequelize from '../config/database';
import { Franchisee } from './Franchisee';
import { User } from './User';
import { Client } from './Client';
import { Item } from './Item';
import { Rectangle } from './Rectangle';
import { Warranty } from './Warranty';
import { Proposal } from './Proposal';
import { DefaultPrice } from './DefaultPrice';

// Associations
Franchisee.hasMany(User, { foreignKey: 'franchiseeId' });
User.belongsTo(Franchisee, { foreignKey: 'franchiseeId' });

Franchisee.hasMany(Client, { foreignKey: 'franchiseeId' });
Client.belongsTo(Franchisee, { foreignKey: 'franchiseeId' });

Franchisee.hasMany(DefaultPrice, { foreignKey: 'franchiseeId' });
DefaultPrice.belongsTo(Franchisee, { foreignKey: 'franchiseeId' });

Client.hasMany(Item, { foreignKey: 'clientId', as: 'items' });
Item.belongsTo(Client, { foreignKey: 'clientId' });

Item.hasMany(Rectangle, { foreignKey: 'itemId', as: 'rectangles' });
Rectangle.belongsTo(Item, { foreignKey: 'itemId' });

Client.hasMany(Warranty, { foreignKey: 'clientId' });
Warranty.belongsTo(Client, { foreignKey: 'clientId' });

Client.hasMany(Proposal, { foreignKey: 'clientId' });
Proposal.belongsTo(Client, { foreignKey: 'clientId' });

export {
  sequelize,
  Franchisee,
  User,
  Client,
  Item,
  Rectangle,
  Warranty,
  Proposal,
  DefaultPrice,
};
