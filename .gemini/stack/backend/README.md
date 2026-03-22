# Backend Stack - Node.js with ExpressJS, PostgreSQL & Sequelize

## Overview

The backend is built using Node.js with ExpressJS framework, PostgreSQL database, and Sequelize ORM.

## Technology Choices

### Core
- **Node.js** 20.x - JavaScript runtime
- **ExpressJS** 4.x - Web framework
- **TypeScript** 5.x - Type safety

### Database
- **PostgreSQL** 15.x - Relational database
- **Sequelize** 6.x - ORM for database operations

### Authentication
- **JWT** - JSON Web Tokens
- **bcrypt** - Password hashing
- **express-validator** - Input validation

### Development Tools
- **nodemon** - Auto-restart on changes
- **ESLint** - Linting
- **Prettier** - Formatting
- **Husky** - Git hooks

### Testing
- **Jest** - Unit testing
- **Supertest** - HTTP testing
- **faker** - Test data generation

## Directory Structure

```
backend/
├── src/
│   ├── config/           # Configuration files
│   ├── controllers/      # Route handlers
│   ├── middlewares/      # Express middlewares
│   ├── models/           # Sequelize models
│   ├── routes/           # Route definitions
│   ├── services/         # Business logic
│   ├── types/            # TypeScript types
│   ├── utils/            # Utility functions
│   ├── validations/      # Validation schemas
│   ├── app.ts            # Express app
│   └── server.ts         # Entry point
├── .env                  # Environment variables
├── tsconfig.json         # TypeScript config
├── eslint.config.js     # ESLint config
├── .prettierrc          # Prettier config
└── package.json
```

## Key Conventions

### File Naming
- Controllers: `PascalCase` (e.g., `UserController.ts`)
- Services: `PascalCase` (e.g., `UserService.ts`)
- Models: `PascalCase` singular (e.g., `User.ts`)
- Routes: `kebab-case` (e.g., `user-routes.ts`)
- Middlewares: `kebab-case` (e.g., `auth-middleware.ts`)
- Utils: `camelCase` (e.g., `dateUtils.ts`)

### MVC Pattern

```
Request → Routes → Controllers → Services → Models → Database
                  ↓
              Middlewares
```

## Development Workflow

### Starting Development
```bash
cd backend
npm install
npm run dev
```

### Building for Production
```bash
npm run build
npm start
```

### Running Tests
```bash
npm run test
```

### Linting & Formatting
```bash
npm run lint
npm run format
```

## Database Configuration

### Environment Variables

```
DB_HOST=localhost
DB_PORT=5432
DB_NAME=myapp_dev
DB_USER=postgres
DB_PASSWORD=secret
DB_POOL_MIN=2
DB_POOL_MAX=10
```

### Sequelize Setup

```typescript
// config/database.ts
import { Sequelize } from 'sequelize';
import config from './config';

export const sequelize = new Sequelize({
  database: config.database.name,
  username: config.database.user,
  password: config.database.password,
  host: config.database.host,
  port: config.database.port,
  dialect: 'postgres',
  pool: {
    min: config.database.pool.min,
    max: config.database.pool.max,
  },
  logging: config.isDevelopment ? console.log : false,
});
```

## API Structure

### Controller Pattern

```typescript
// controllers/userController.ts
import { Request, Response, NextFunction } from 'express';
import { userService } from '@/services/userService';

export const userController = {
  getAll: async (req: Request, res: Response, next: NextFunction) => {
    try {
      const users = await userService.findAll();
      res.json({ success: true, data: users });
    } catch (error) {
      next(error);
    }
  },

  getById: async (req: Request, res: Response, next: NextFunction) => {
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

### Service Pattern

```typescript
// services/userService.ts
import { User } from '@/models';
import type { CreateUserDTO, UpdateUserDTO } from '@/types';

export const userService = {
  findAll: async () => {
    return User.findAll();
  },

  findById: async (id: string) => {
    return User.findByPk(id);
  },

  create: async (data: CreateUserDTO) => {
    return User.create(data);
  },

  update: async (id: string, data: UpdateUserDTO) => {
    const user = await User.findByPk(id);
    if (!user) return null;
    return user.update(data);
  },

  delete: async (id: string) => {
    const user = await User.findByPk(id);
    if (!user) return false;
    await user.destroy();
    return true;
  },
};
```

## See Also

- [Project Structure](./project-structure.md)
- [Database Models](./database-models.md)
- [API Design](./api-design.md)
