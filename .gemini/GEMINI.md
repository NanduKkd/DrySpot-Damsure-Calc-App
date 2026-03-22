# Project Gemini Configuration

This repository is a deterministic AI workflow for Flutter + Node.js development.

## User-Facing Entry Points

- `./geminiba`
  Use this to gather or refine requirements with the user.
  When the BA session exits successfully, the internal implementation pipeline runs automatically in sequence.

- `./geminibug-reproducer`
  Use this to collect one or more simulator-, emulator-, or device-tested bugs from the user.
  When the bug session exits successfully, the internal bugfix pipeline runs automatically in sequence.

## Internal Roles

These roles are not intended for normal user-facing operation:

- `system-architect.md`
- `system-tests-writer.md`
- `system-dev.md`

## Deterministic File Contracts

All internal roles must use these exact paths.

- `docs/current/requirements.md`
- `docs/current/technical-design.md`
- `docs/current/test-plan.md`
- `docs/current/test-results.md`
- `docs/current/implementation-status.md`
- `docs/current/bug-report.md`
- `docs/current/bugfix-status.md`

Do not invent alternative document locations when these files are appropriate.

## Project Environment Documentation

- **[Stack Overview](./stack/README.md)** - Complete technology stack overview
- **[Flutter Stack](./stack/flutter/README.md)** - Flutter application development guide
- **[Backend Stack](./stack/backend/README.md)** - Node.js backend with ExpressJS, PostgreSQL, and Sequelize
- **[Testing Guide](./stack/testing.md)** - Testing strategy, tools, and commands
