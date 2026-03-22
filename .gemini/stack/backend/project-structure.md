# Backend: Project Structure

## Overview

This document describes the project structure for the Node.js/Express backend.

## Root Level

```
backend/
├── src/
├── .env
├── tsconfig.json
├── tsconfig.build.json
├── eslint.config.js
├── .prettierrc
├── .eslintignore
├── .prettierignore
├── nodemon.json
└── package.json
```

## Source Directory (`src/`)

```
src/
├── config/               # Configuration
│   ├── database.ts       # Sequelize setup
│   ├── app.ts            # App config
│   └── index.ts          # Config exports
├── controllers/          # Route handlers
│   ├── userController.ts
│   └── index.ts
├── middlewares/          # Express middlewares
│   ├── authMiddleware.ts
│   ├── errorMiddleware.ts
│   ├── validationMiddleware.ts
│   └── index.ts
├── models/               # Sequelize models
│   ├── user.ts
│   ├── index.ts          # Model associations
│   └── migrations/       # Database migrations
├── routes/              # Route definitions
│   ├── userRoutes.ts
│   └── index.ts
├── services/             # Business logic
│   ├── userService.ts
│   └── index.ts
├── types/               # TypeScript types/DTOs
│   ├── userTypes.ts
│   └── index.ts
├── utils/               # Utility functions
│   ├── dateUtils.ts
│   ├── stringUtils.ts
│   └── index.ts
├── validations/         # Validation schemas
│   ├── userValidation.ts
│   └── index.ts
├── app.ts              # Express app setup
└── server.ts           # Entry point
```

## Controllers Directory

```
controllers/
├── userController.ts
├── authController.ts
├── productController.ts
└── index.ts            # Barrel export
```

### Controller Structure

```typescript
// controllers/userController.ts
import { Request, Response, NextFunction } from 'express';
import { userService } from '@/services/userService';

export const userController = {
  async getAll(req: Request, res: Response, next: NextFunction) {
    try {
      const users = await userService.findAll();
      res.json({ success: true, data: users });
    } catch (error) {
      next(error);
    }
  },

  async getById(req: Request, res: Response, next: NextFunction) {
    try {
      const user = await userService.findById(req.params.id);
      if (!user) {
        return res.status(404).json({ success: false, message: 'User not found' });
      }
      res.json({ success: true, data: user });
    } catch (error) {
      next(error);
    }
  },
};
```

## Services Directory

```
services/
├── userService.ts
├── authService.ts
├── productService.ts
└── index.ts
```

### Service Structure

```typescript
// services/userService.ts
import { User } from '@/models';
import type { CreateUserDTO, UpdateUserDTO } from '@/types';
import { AppError } from '@/utils/appError';

export const userService = {
  async findAll() {
    return User.findAll({
      attributes: { exclude: ['password'] },
    });
  },

  async findById(id: string) {
    const user = await User.findByPk(id, {
      attributes: { exclude: ['password'] },
    });
    if (!user) {
      throw new AppError('User not found', 404);
    }
    return user;
  },

  async create(data: CreateUserDTO) {
    return User.create(data);
  },

  async update(id: string, data: UpdateUserDTO) {
    const user = await User.findByPk(id);
    if (!user) {
      throw new AppError('User not found', 404);
    }
    return user.update(data);
  },

  async delete(id: string) {
    const user = await User.findByPk(id);
    if (!user) {
      throw new AppError('User not found', 404);
    }
    await user.destroy();
  },
};
```

## Models Directory

```
models/
├── user.ts
├── product.ts
├── order.ts
├── index.ts            # Model associations
└── migrations/         # Sequelize migrations
```

### Model Structure

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
  createdAt?: Date;
  updatedAt?: Date;
}

interface UserCreationAttributes extends Optional<UserAttributes, 'id'> {}

export class User extends Model<UserAttributes, UserCreationAttributes> implements UserAttributes {
  declare id: string;
  declare email: string;
  declare password: string;
  declare name: string;
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
      type: DataTypes.STRING,
      allowNull: false,
      unique: true,
      validate: { isEmail: true },
    },
    password: {
      type: DataTypes.STRING,
      allowNull: false,
    },
    name: {
      type: DataTypes.STRING,
      allowNull: false,
    },
  },
  {
    sequelize,
    modelName: 'User',
    tableName: 'users',
    hooks: {
      beforeCreate: async (user: User) => {
        if (user.password) {
          user.password = await bcrypt.hash(user.password, 12);
        }
      },
    },
  }
);
```

## Routes Directory

```
routes/
├── userRoutes.ts
├── authRoutes.ts
├── productRoutes.ts
└── index.ts
```

### Route Structure

```typescript
// routes/userRoutes.ts
import { Router } from 'express';
import { userController } from '@/controllers/userController';
import { validate } from '@/middlewares/validationMiddleware';
import { userValidation } from '@/validations/userValidation';
import { authMiddleware } from '@/middlewares/authMiddleware';

const router = Router();

router.get('/', userController.getAll);
router.get('/:id', userController.getById);

router.post(
  '/',
  authMiddleware,
  validate(userValidation.create),
  userController.create
);

router.put(
  '/:id',
  authMiddleware,
  validate(userValidation.update),
  userController.update
);

router.delete('/:id', authMiddleware, userController.delete);

export default router;
```

## Middlewares Directory

```
middlewares/
├── authMiddleware.ts
├── errorMiddleware.ts
├── validationMiddleware.ts
├── rateLimitMiddleware.ts
└── index.ts
```

## Validations Directory

```
validations/
├── userValidation.ts
├── authValidation.ts
└── index.ts
```

## Import Conventions

```typescript
// Order of imports
// 1. External
import { Request, Response, NextFunction } from 'express';
import bcrypt from 'bcrypt';

// 2. Internal - config
import { sequelize } from '@/config';

// 3. Internal - models
import { User } from '@/models';

// 4. Internal - services
import { userService } from '@/services';

// 5. Internal - controllers
import { userController } from '@/controllers';

// 6. Internal - middlewares
import { authMiddleware } from '@/middlewares';

// 7. Internal - types
import type { CreateUserDTO } from '@/types';

// 8. Internal - utils
import { AppError } from '@/utils';
```

## File Naming Conventions

| Type | Convention | Example |
|------|------------|---------|
| Controllers | PascalCase | `UserController.ts` |
| Services | PascalCase | `UserService.ts` |
| Models | PascalCase (singular) | `User.ts` |
| Routes | kebab-case | `user-routes.ts` |
| Middlewares | kebab-case | `auth-middleware.ts` |
| Validations | kebab-case | `user-validation.ts` |
| Utils | camelCase | `dateUtils.ts` |
| Types | PascalCase | `UserTypes.ts` |
| Config | camelCase | `database.ts` |
