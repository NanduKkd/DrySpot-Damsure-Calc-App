# Workflow

This repo is designed around two user-facing entry points.

## 1. Feature Intake

Run:

- `./geminiba`

What happens:

1. You describe the feature and answer the BA's questions.
2. The BA writes `docs/current/requirements.md`.
3. When the BA session exits successfully, the internal pipeline runs automatically:
   - architect
   - tests-writer
   - dev

The internal pipeline writes deterministic status files under `docs/current/`.

## 2. Bug Intake

Run:

- `./geminibug-reproducer`

What happens:

1. You report one or more simulator-, emulator-, or device-tested bugs.
2. The bug agent writes `docs/current/bug-report.md`.
3. When the bug session exits successfully, the internal bugfix pipeline runs automatically:
   - tests-writer
   - dev

## Contract Files

These are the files the internal pipeline is expected to use:

- `docs/current/requirements.md`
- `docs/current/technical-design.md`
- `docs/current/test-plan.md`
- `docs/current/test-results.md`
- `docs/current/implementation-status.md`
- `docs/current/bug-report.md`
- `docs/current/bugfix-status.md`

## User Responsibilities

1. Run the BA flow for a feature and answer its questions well.
2. Run the app in a simulator, emulator, or physical device, test it manually, and report bug batches through the bug agent.
