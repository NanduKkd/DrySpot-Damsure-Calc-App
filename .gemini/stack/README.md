# Project Stack Documentation

This directory contains detailed documentation for the Flutter + Node.js stack used in this project.

## Architecture Overview

```text
project/
├── flutter/      # Flutter application
└── backend/      # Node.js + Express API
```

## Technology Stack

### Flutter App
- **Framework:** Flutter 3.x
- **Language:** Dart 3.x
- **State Management:** Stateful widgets / ChangeNotifier / Riverpod when justified
- **Networking:** `http` or `dio`
- **Testing:** `flutter test` + `integration_test`

### Backend
- **Runtime:** Node.js 20+
- **Framework:** ExpressJS
- **Database:** PostgreSQL 15+
- **ORM:** Sequelize
- **Language:** TypeScript
- **Testing:** Jest / Supertest

### Development Tools
- **Package Manager:** `flutter pub` + `npm`
- **Linting:** `flutter analyze` + ESLint
- **Formatting:** `dart format` + Prettier

## Stack-Specific Documentation

- [Flutter Stack](./flutter/README.md) - Mobile app development guidelines
- [Backend Stack](./backend/README.md) - Backend development guidelines

## Quick Links

- [Flutter: Project Structure](./flutter/project-structure.md)
- [Flutter: Coding Standards](./flutter/coding-standards.md)
- [Flutter: API Communication](./flutter/api-communication.md)
- [Backend: Project Structure](./backend/project-structure.md)
- [Backend: Database Models](./backend/database-models.md)
- [Backend: API Design](./backend/api-design.md)
- [Testing Guide](./testing.md) - Testing strategy, tools, and commands

## Development Commands

From the project root, use these commands:

```bash
# Development services
npm run dev                 # Start both flutter + backend
npm run dev:detach          # Start in background
npm run dev:stop            # Stop detached services
npm run dev:flutter         # Flutter only
npm run dev:backend         # Backend only

# Logs
npm run logs                # View all logs
npm run logs:flutter        # View Flutter logs
npm run logs:backend        # View backend logs

# Tests
npm run test                       # Run all tests with summary
npm run test:flutter               # All Flutter tests
npm run test:backend               # All backend tests
npm run test:flutter:unit          # Flutter unit/widget tests
npm run test:flutter:integration   # Flutter integration tests
npm run test:backend:unit          # Backend unit tests
npm run test:backend:integration   # Backend integration tests

# Linting
npm run lint                # Lint both
npm run lint:flutter        # Analyze Flutter app
npm run lint:backend        # Lint backend
```
