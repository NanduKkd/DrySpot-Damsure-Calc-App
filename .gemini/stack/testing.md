# Testing Guide

## Overview

This project uses a layered testing strategy:

| Test Type | Purpose | Location |
|-----------|---------|----------|
| Flutter unit/widget | Widget rendering and local logic | `flutter/test/` |
| Flutter integration | Full app flows on simulator/emulator/device | `flutter/integration_test/` |
| Backend unit | Service and utility logic | `backend/src/**/*.test.ts` |
| Backend integration | API routes and persistence flows | `backend/tests/integration/` |

## Flutter Testing

### Unit and Widget Tests
- Run with `flutter test`
- Use fake clients or repositories for network-dependent widgets
- Keep tests deterministic and device-independent

### Integration Tests
- Run with `flutter test integration_test`
- Cover navigation, data loading, and failure states
- Record blockers if no suitable emulator, simulator, or device is available

## Backend Testing

### Unit Tests
- Run with `npm run test:unit`
- Focus on services and reusable helpers

### Integration Tests
- Run with `npm run test:integration`
- Focus on Express routes and database-facing behavior

## Root Commands

```bash
npm run test                      # Run Flutter + backend tests with summary
npm run test:flutter             # Flutter tests
npm run test:flutter:unit        # Flutter unit/widget tests
npm run test:flutter:integration # Flutter integration tests
npm run test:backend             # Backend tests
npm run test:backend:unit        # Backend unit tests
npm run test:backend:integration # Backend integration tests
```

## Logs

```text
logs/
├── flutter/
│   └── dev.log
├── backend/
│   └── dev.log
└── test/
    ├── flutter-unit.log
    ├── flutter-integration.log
    ├── backend-unit.log
    └── backend-integration.log
```

## See Also

- [Flutter Stack](./flutter/README.md)
- [Backend Stack](./backend/README.md)
- [Flutter: Coding Standards](./flutter/coding-standards.md)
