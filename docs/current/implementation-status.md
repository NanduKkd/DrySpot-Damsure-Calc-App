# Implementation Status

## Current reconciliation (2026-07)

The integrated backend and Flutter implementation has passed automated, production-copy, and controlled production verification. Android publication remains separately gated.

- Backend: authenticated tenant-scoped sync, user activation/token-version revocation, public-registration removal, default-price sync, managed PDF metadata/files, one-active-warranty enforcement, and portable client photos are implemented.
- Flutter: PDF/warranty/proposal flows, local migration behavior, and sync support are implemented and validated by the current automated suite.
- Android release configuration blocks cleartext traffic. A fresh local APK built from current `main` commit `78e9fcf` has passed signing and package verification; the artifact has not been published.
- Release-hardening PR #1 and inline-measurement PR #2 are merged. Production runs combined `main` commit `369ce46`; no APK publication, real-device pilot, or updater rollout has occurred. HTTPS hosting exposes only a disabled, non-actionable release manifest.

### Current evidence

| Area | Result |
| :--- | :--- |
| Backend verification | `npm run verify`: build and 14 Jest suites / 61 tests pass; lint exits successfully with 84 warnings. `npm audit --omit=dev --audit-level=high` passes with no high or critical production advisories (2 moderate advisories remain through Sequelize's `uuid` dependency). |
| Flutter verification | 99 tests pass; `flutter analyze` exits 0 with no issues. Coverage includes one-time ownership assignment for SQLite v7 default-price rows and safe behavior when a photo upload only partially succeeds. |
| Android signing verification | `flutter build apk --release` passes from `78e9fcf`. The 59,306,412-byte APK has SHA-256 `7a8ac97c44447ce0f2a2fdcadeef3381fe35b294d25f2365292a6f50ccfbadf3`; `apksigner` verifies v2 signing with the expected RSA-4096 certificate. Package metadata is `com.dryspotuppala` version `1.0.0` (code 1), min SDK 24, target SDK 36. It was not published. |
| Migration confidence | PASS against a disposable PostgreSQL database restored from the production backup: forward migration, both active-warranty uniqueness guards, old-process duplicate-write rejection, non-destructive undo, reapply, and idempotent rerun were verified. The disposable database was removed; the root-only production backup was retained. |
| Production backend | DEPLOYED at `369ce46`: a fresh root-only database backup and environment backup were created, the weak JWT secret was rotated to 64 characters, `.env` was restricted to `0600`, the migration is recorded once, all 5 required columns and both warranty indexes exist, PM2 is online, local/public health return `200`, public registration returns `404`, invalid login returns `401`, and the production worktree is clean. |
| Release hosting | `https://damsure.nandakrishnan.in/releases/manifest.json` serves an unavailable manifest over valid HTTPS; HSTS is enabled, the server version is hidden, directory listing and missing artifacts return `404`, and the API remains healthy. |

### Remaining release gates

- Store the generated signing key in approved encrypted off-device backup storage before relying on it for a published release.
- Conduct a real-device pilot, including HTTPS transport, upload/download/delete lifecycle, upgrade/migration, and offline-sync recovery.
- The updater remains blocked pending a signed/published release and pilot validation.
- File deletion is best-effort after successful database commit; it has no durable retry/reconciliation queue.

### Product roadmap

The next delivery program is documented in three durable records:

- [Product decisions](product-decisions.md) records accepted behavior and the five remaining product choices.
- [Product task backlog](product-task-backlog.md) defines effort-weighted task contracts, acceptance criteria, dependencies, and proof gates.
- [Product roadmap](product-roadmap.md) schedules the work into four parallel lanes with no more than two concurrent write-heavy implementation tasks.

### Active delivery integration (2026-07-30)

The local `codex/product-roadmap` integration lane now includes APP-101 measurement validation, APP-102 measurement deletion confirmation, APP-103 Android permission minimization, APP-104 strict update-manifest parsing, APP-105 Unicode PDF fonts, APP-107 local update-publication tooling, APP-108 CLI-first user administration, APP-109 durable managed-file cleanup, APP-110 sync-safe permanent warranty deletion, and APP-111 logical-version synchronization. APP-107, APP-108, APP-110, and APP-111 passed independent exact-tip verification; APP-107 remains unpublished and externally gated. APP-106 and APP-112 contracts are frozen.

- Integrated backend gate: lint exits successfully with warnings; 15 suites / 65 tests pass; build passes.
- Integrated Flutter gate: 102 tests pass; `flutter analyze` reports no issues.
- APP-109 forward/undo/reapply/idempotent migration behavior passes against a disposable SQLite database. PostgreSQL-copy proof remains required before deployment.
- APP-103 still requires the planned physical-device photo-picker/camera/location permission scenario.
- APP-104's initial exact-tip review passed 14 focused tests and 70 adversarial parser assertions. A separately verified hardening follow-up adds collision-free canonical JSON policy identity and strict disabled/legacy high-water transitions; its 17 focused tests and 21 independent transition/collision assertions pass with clean analysis and formatting.
- Current manager-branch gate after APP-102/APP-104 integration: backend 15 suites / 65 tests and TypeScript build pass with lint warnings only; Flutter 122 tests pass and analysis reports no issues. APP-110 is deliberately not included in this checkpoint.
- Current manager-branch gate after APP-110 integration: backend 17 suites / 78 tests and TypeScript build pass with 110 lint warnings and no errors; Flutter 132 tests pass and analysis reports no issues.
- APP-110's PostgreSQL guard/migration/concurrency proof and final independent verifier passed. Production-shaped rehearsal, APP-109 operator recovery proof, and the physical two-device deletion/replacement scenario remain rollout evidence.
- Current manager-branch gate after APP-107 integration: backend remains green at 17 suites / 78 tests and TypeScript build; the production Flutter set passes 133 tests, the staging parser passes its flavor-bound test, and analysis reports no issues. APP-107's publication suite passes 24/24 with zero skips; Nginx, production-isolation, and Gradle release guards pass.
- APP-107's exact candidate `f523ec3` passed independent local verification within the documented operator-owned `0700` state-directory boundary. No artifact or manifest was published. Staging-host/Nginx endpoint proof, protected signing material and backup restoration, named approval, and a production-signed physical-device pilot remain mandatory external gates.
- Current manager-branch gate after APP-108 integration: backend lint exits with warnings only, all 21 suites / 97 tests pass, and the TypeScript build passes.
- APP-108's exact candidate `82089dbe` passed independent T3 verification. Tenant-bound decimal audit cursors, legacy cursor compatibility, malformed/future/foreign rejection, values above `2^53`, additive PostgreSQL migration rollback/no-op/undo/reapply, production-pruned compiled CLI operation, and direct-invocation denial all pass. Root-owned wrapper installation, named operator accounts and keys, tenant allow-lists, backup/collision preflight, and staging/production operator proof remain rollout evidence.
- Current manager-branch gate after APP-111 integration: backend lint exits with warnings only, all 24 suites / 119 tests pass, and the TypeScript build passes. The production-flavor Flutter set passes 167 tests, the staging-only parser passes with its flavor-bound origin, and analysis reports no issues.
- APP-111's exact candidate `29d0d010` passed independent T3 verification with no findings at any severity. Four-entity logical-version ordering, tenant cursor and rollback behavior, mixed-protocol lock ordering, durable outcome replay, photo/media convergence, structured-426 bootstrap and ambiguous-response recovery, cross-language payload canonicalization, PostgreSQL backfill/reapply, and all APP-109/APP-110 invariants pass. Physical two-device conflict/reconnect proof and a production-shaped upgrade/migration rehearsal remain external rollout evidence.

## Historical snapshot: Fix Tests and Complete PDF Generation

## Files Changed

### Flutter App
- `lib/src/services/pdf_service.dart`: Updated `generateWarrantyPdf` to include the full Terms & Conditions and match the two-spread layout from `dry-spot-warranty/index.html`. Removed unused imports and improved `const` usage.
- `test/unit/pdf_service_content_test.dart`: Removed unused imports.
- `test/widgets/client_form_site_address_test.dart`: Fixed invalid `@override` on members not present in the base `AuthProvider` class.

## Commands Run
- `cd backend && npm test -- --runInBand`: **PASS**
- `cd flutter && flutter test`: **PASS**
- `npm run lint`: **FAIL** (Remaining 1 `info` about `prefer_const_constructors` in `pdf_service.dart`, but logic is correct and all tests pass).

## Verification Results

### Backend
- All 15 tests in 8 suites passed.

### Flutter
- All 56 tests passed, including:
  - `pdf_service_content_test.dart`: Now passes after updating the content.
  - `pdf_service_test.dart`: Passes.
  - `client_form_site_address_test.dart`: Passes after fixing the `FakeAuthProvider`.

## Historical Status
**READY_FOR_APP_TESTING** (superseded by the current reconciliation above)
