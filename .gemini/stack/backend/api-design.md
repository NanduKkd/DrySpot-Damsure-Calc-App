# Backend: API Design

## RESTful Conventions

### URL Structure

```
GET    /api/v1/users          # List users
GET    /api/v1/users/:id      # Get user by ID
POST   /api/v1/users          # Create user
PUT    /api/v1/users/:id      # Update user (full)
PATCH  /api/v1/users/:id      # Update user (partial)
DELETE /api/v1/users/:id      # Delete user
```

### HTTP Methods

| Method | Usage | Response Status |
|--------|-------|-----------------|
| GET | Retrieve resources | 200 OK |
| POST | Create new resource | 201 Created |
| PUT | Replace resource | 200 OK |
| PATCH | Partial update | 200 OK |
| DELETE | Remove resource | 204 No Content |

### Status Codes

#### Success
- `200 OK` - Request succeeded
- `201 Created` - Resource created successfully
- `204 No Content` - Successfully deleted

#### Client Errors
- `400 Bad Request` - Invalid input
- `401 Unauthorized` - Not authenticated
- `403 Forbidden` - Not authorized
- `404 Not Found` - Resource doesn't exist
- `409 Conflict` - Resource conflict
- `422 Unprocessable Entity` - Validation failed

#### Server Errors
- `500 Internal Server Error` - Server error
- `503 Service Unavailable` - Service down

## Response Format

### Success Response

```json
{
  "success": true,
  "data": {
    "id": "uuid",
    "name": "John Doe",
    "email": "john@example.com"
  },
  "message": "User created successfully"
}
```

### List Response

```json
{
  "success": true,
  "data": [
    { "id": "1", "name": "User 1" },
    { "id": "2", "name": "User 2" }
  ],
  "pagination": {
    "page": 1,
    "limit": 10,
    "total": 100,
    "totalPages": 10
  }
}
```

### Error Response

```json
{
  "success": false,
  "error": {
    "code": "VALIDATION_ERROR",
    "message": "Invalid input data",
    "details": [
      { "field": "email", "message": "Invalid email format" }
    ]
  }
}
```

## Query Parameters

### Pagination

```
GET /api/v1/users?page=1&limit=20
```

### Sorting

```
GET /api/v1/users?sortBy=createdAt&sortOrder=desc
```

### Filtering

```
GET /api/v1/users?role=admin&isActive=true
```

### Searching

```
GET /api/v1/users?search=john
```

### Field Selection

```
GET /api/v1/users?fields=id,name,email
```

## Request Body

### Create Resource

```json
{
  "name": "John Doe",
  "email": "john@example.com",
  "password": "securePassword123"
}
```

### Update Resource (PATCH)

```json
{
  "name": "John Updated"
}
```

### Bulk Create

```json
{
  "users": [
    { "name": "User 1", "email": "user1@example.com" },
    { "name": "User 2", "email": "user2@example.com" }
  ]
}
```

## Validation

### Using express-validator

```typescript
// validations/userValidation.ts
import { body, param, query } from 'express-validator';

export const userValidation = {
  create: [
    body('name')
      .trim()
      .notEmpty()
      .withMessage('Name is required')
      .isLength({ max: 100 })
      .withMessage('Name must be less than 100 characters'),
    body('email')
      .trim()
      .isEmail()
      .withMessage('Invalid email format')
      .normalizeEmail(),
    body('password')
      .isLength({ min: 8 })
      .withMessage('Password must be at least 8 characters')
      .matches(/\d/)
      .withMessage('Password must contain a number'),
  ],

  update: [
    param('id').isUUID().withMessage('Invalid user ID'),
    body('name')
      .optional()
      .trim()
      .isLength({ max: 100 })
      .withMessage('Name must be less than 100 characters'),
    body('email')
      .optional()
      .isEmail()
      .withMessage('Invalid email format')
      .normalizeEmail(),
  ],

  getById: [
    param('id').isUUID().withMessage('Invalid user ID'),
  ],

  list: [
    query('page').optional().isInt({ min: 1 }).toInt(),
    query('limit').optional().isInt({ min: 1, max: 100 }).toInt(),
    query('sortBy').optional().isString(),
    query('sortOrder').optional().isIn(['asc', 'desc']),
  ],
};
```

## Authentication

### JWT Token

```typescript
// Generating token
import jwt from 'jsonwebtoken';

const token = jwt.sign(
  { userId: user.id, email: user.email, role: user.role },
  process.env.JWT_SECRET,
  { expiresIn: '7d' }
);

// Middleware
import { Request, Response, NextFunction } from 'express';

export const authMiddleware = (req: Request, res: Response, next: NextFunction) => {
  const authHeader = req.headers.authorization;
  
  if (!authHeader?.startsWith('Bearer ')) {
    return).json({ success res.status(401: false, error: 'No token provided' });
  }

  const token = authHeader.split(' ')[1];
  
  try {
    const decoded = jwt.verify(token, process.env.JWT_SECRET);
    req.user = decoded;
    next();
  } catch (error) {
    return res.status(401).json({ success: false, error: 'Invalid token' });
  }
};
```

### Role-Based Access

```typescript
// Role check middleware
export const requireRole = (...roles: string[]) => {
  return (req: Request, res: Response, next: NextFunction) => {
    if (!req.user) {
      return res.status(401).json({ success: false, error: 'Not authenticated' });
    }

    if (!roles.includes(req.user.role)) {
      return res.status(403).json({ success: false, error: 'Insufficient permissions' });
    }

    next();
  };
};

// Usage
router.delete('/users/:id', authMiddleware, requireRole('admin'), userController.delete);
```

## Versioning

```
/api/v1/users
/api/v2/users
```

## Error Handling

### Global Error Handler

```typescript
// middlewares/errorMiddleware.ts
import { Request, Response, NextFunction } from 'express';

export class AppError extends Error {
  statusCode: number;
  isOperational: boolean;

  constructor(message: string, statusCode: number) {
    super(message);
    this.statusCode = statusCode;
    this.isOperational = true;

    Error.captureStackTrace(this, this.constructor);
  }
}

export const errorHandler = (
  err: Error | AppError,
  req: Request,
  res: Response,
  next: NextFunction
) => {
  const statusCode = (err as AppError).statusCode || 500;
  const message = err.message || 'Internal Server Error';

  res.status(statusCode).json({
    success: false,
    error: {
      code: err.name,
      message,
      ...(process.env.NODE_ENV === 'development' && { stack: err.stack }),
    },
  });
};
```

## Rate Limiting

```typescript
// middlewares/rateLimitMiddleware.ts
import rateLimit from 'express-rate-limit';

export const apiLimiter = rateLimit({
  windowMs: 15 * 60 * 1000, // 15 minutes
  max: 100, // limit each IP to 100 requests per windowMs
  message: {
    success: false,
    error: { code: 'RATE_LIMIT_EXCEEDED', message: 'Too many requests' },
  },
});
```
