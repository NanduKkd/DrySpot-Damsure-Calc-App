# Backend: Database Models

## Overview

This document describes the database modeling conventions using Sequelize ORM.

## Model Conventions

### Naming

- **Model name:** PascalCase, singular (e.g., `User`, `Product`)
- **Table name:** snake_case, plural (e.g., `users`, `products`)
- **Primary key:** `id` (UUID, auto-generated)
- **Timestamps:** `createdAt`, `updatedAt`

### Standard Fields

```typescript
// Every model should have these
{
  id: {
    type: DataTypes.UUID,
    defaultValue: DataTypes.UUIDV4,
    primaryKey: true,
  },
  createdAt: {
    type: DataTypes.DATE,
    defaultValue: DataTypes.NOW,
  },
  updatedAt: {
    type: DataTypes.DATE,
    defaultValue: DataTypes.NOW,
  },
}
```

## Model Definition Pattern

```typescript
// models/user.ts
import { DataTypes, Model, Optional } from 'sequelize';
import { sequelize } from '@/config/database';
import bcrypt from 'bcrypt';

interface UserAttributes {
  id: string;
  email: string;
  password: string;
  name: string;
  isActive: boolean;
  role: 'admin' | 'user' | 'guest';
  createdAt?: Date;
  updatedAt?: Date;
}

interface UserCreationAttributes extends Optional<UserAttributes, 'id' | 'isActive' | 'role'> {}

export class User extends Model<UserAttributes, UserCreationAttributes> implements UserAttributes {
  declare id: string;
  declare email: string;
  declare password: string;
  declare name: string;
  declare isActive: boolean;
  declare role: 'admin' | 'user' | 'guest';
  declare readonly createdAt: Date;
  declare readonly updatedAt: Date;

  async comparePassword(candidatePassword: string): Promise<boolean> {
    return bcrypt.compare(candidatePassword, this.password);
  }
}

User.init(
  {
    id: {
      type: DataTypes.UUID,
      defaultValue: DataTypes.UUIDV4,
      primaryKey: true,
    },
    email: {
      type: DataTypes.STRING(255),
      allowNull: false,
      unique: true,
      validate: { isEmail: true },
    },
    password: {
      type: DataTypes.STRING(255),
      allowNull: false,
    },
    name: {
      type: DataTypes.STRING(100),
      allowNull: false,
    },
    isActive: {
      type: DataTypes.BOOLEAN,
      defaultValue: true,
    },
    role: {
      type: DataTypes.ENUM('admin', 'user', 'guest'),
      defaultValue: 'user',
    },
  },
  {
    sequelize,
    modelName: 'User',
    tableName: 'users',
    timestamps: true,
    paranoid: true, // Soft deletes
    hooks: {
      beforeCreate: async (user: User) => {
        if (user.password) {
          user.password = await bcrypt.hash(user.password, 12);
        }
      },
      beforeUpdate: async (user: User) => {
        if (user.changed('password')) {
          user.password = await bcrypt.hash(user.password, 12);
        }
      },
    },
  }
);
```

## Associations

### Defining Associations

```typescript
// models/index.ts
import { User } from './user';
import { Post } from './post';
import { Comment } from './comment';

// User hasMany Posts
User.hasMany(Post, { foreignKey: 'userId', as: 'posts' });
Post.belongsTo(User, { foreignKey: 'userId', as: 'author' });

// Post hasMany Comments
Post.hasMany(Comment, { foreignKey: 'postId', as: 'comments' });
Comment.belongsTo(Post, { foreignKey: 'postId', as: 'post' });

// User hasMany Comments
User.hasMany(Comment, { foreignKey: 'userId', as: 'comments' });
Comment.belongsTo(User, { foreignKey: 'userId', as: 'author' });

// Many-to-Many example
import { Project } from './project';
import { UserProject } from './userProject';

User.belongsToMany(Project, { through: UserProject, as: 'projects' });
Project.belongsToMany(User, { through: UserProject, as: 'members' });
```

### Association Patterns

| Relationship | Code |
|--------------|------|
| One-to-One | `ModelA.hasOne(ModelB)` |
| One-to-Many | `ModelA.hasMany(ModelB)` |
| Many-to-Many | `ModelA.belongsToMany(ModelB, { through: JunctionModel })` |

## Data Types

### Common Sequelize Types

```typescript
{
  // Strings
  email: DataTypes.STRING(255),
  name: DataTypes.STRING(100),
  bio: DataTypes.TEXT,
  
  // Numbers
  age: DataTypes.INTEGER,
  price: DataTypes.DECIMAL(10, 2),
  
  // Boolean
  isActive: DataTypes.BOOLEAN,
  
  // Date
  birthDate: DataTypes.DATEONLY,
  
  // UUID
  id: DataTypes.UUID,
  
  // Enum
  role: DataTypes.ENUM('admin', 'user', 'guest'),
  
  // JSON
  metadata: DataTypes.JSONB,
}
```

## Indexes

### Adding Indexes

```typescript
{
  indexes: [
    {
      unique: true,
      fields: ['email'],
    },
    {
      name: 'idx_user_name',
      fields: ['name'],
    },
    {
      name: 'idx_user_role_active',
      fields: ['role', 'isActive'],
    },
  ],
}
```

## Migrations

### Creating a Migration

```bash
npx sequelize-cli migration:generate --name create-users
```

### Migration Template

```typescript
// migrations/20260101000000-create-users.js
'use strict';

module.exports = {
  async up(queryInterface, Sequelize) {
    await queryInterface.createTable('users', {
      id: {
        type: Sequelize.UUID,
        defaultValue: Sequelize.UUIDV4,
        primaryKey: true,
      },
      email: {
        type: Sequelize.STRING(255),
        allowNull: false,
        unique: true,
      },
      password: {
        type: Sequelize.STRING(255),
        allowNull: false,
      },
      name: {
        type: Sequelize.STRING(100),
        allowNull: false,
      },
      createdAt: {
        type: Sequelize.DATE,
        allowNull: false,
        defaultValue: Sequelize.NOW,
      },
      updatedAt: {
        type: Sequelize.DATE,
        allowNull: false,
        defaultValue: Sequelize.NOW,
      },
    });

    await queryInterface.addIndex('users', ['email'], { unique: true });
  },

  async down(queryInterface, Sequelize) {
    await queryInterface.dropTable('users');
  },
};
```

## Soft Deletes

```typescript
// Enable paranoid mode for soft deletes
User.init(
  { /* fields */ },
  {
    sequelize,
    paranoid: true, // Adds deletedAt
  }
);

// Query - automatically excludes soft deleted
const activeUsers = await User.findAll();

// Include soft deleted
const allUsers = await User.findAll({ paranoid: false });

// Force delete
await user.destroy({ force: true });

// Soft delete
await user.destroy();
```

## Scopes

```typescript
// Define scopes
User.addScope('active', {
  where: { isActive: true },
});

User.addScope('byRole', (role: string) => ({
  where: { role },
}));

// Use scopes
const activeAdmins = await User.scope('active', 'byRole').findAll({
  where: { role: 'admin' },
});
```
