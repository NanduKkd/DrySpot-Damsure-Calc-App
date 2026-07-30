# Implementation Status

## Current reconciliation (2026-07)

The integrated backend and Flutter implementation has passed automated and production-copy migration verification. Production deployment and Android publication remain separately gated.

- Backend: authenticated tenant-scoped sync, user activation/token-version revocation, public-registration removal, default-price sync, managed PDF metadata/files, one-active-warranty enforcement, and portable client photos are implemented.
- Flutter: PDF/warranty/proposal flows, local migration behavior, and sync support are implemented and validated by the current automated suite.
- Android release configuration blocks cleartext traffic and a local signed release APK has passed signing verification. The artifact has not been published.
- The release branch is pushed in a draft pull request. No production deployment, APK publication, real-device pilot, or updater rollout has occurred. HTTPS hosting exposes only a disabled, non-actionable release manifest.

### Current evidence

| Area | Result |
| :--- | :--- |
| Backend verification | `npm run verify`: build and 14 Jest suites / 61 tests pass; lint exits successfully with 84 warnings. `npm audit --omit=dev --audit-level=high` passes with no high or critical production advisories (2 moderate advisories remain through Sequelize's `uuid` dependency). |
| Flutter verification | 99 tests pass; `flutter analyze` exits 0 with no issues. Coverage includes one-time ownership assignment for SQLite v7 default-price rows and safe behavior when a photo upload only partially succeeds. |
| Android signing verification | `flutter build apk --release` passes. The resulting APK passed `apksigner` v2 verification with an RSA-4096 certificate; its SHA-256 is recorded in test results. It was not published. |
| Migration confidence | PASS against a disposable PostgreSQL database restored from the production backup: forward migration, both active-warranty uniqueness guards, old-process duplicate-write rejection, non-destructive undo, reapply, and idempotent rerun were verified. The disposable database was removed; the root-only production backup was retained. |
| Release hosting | `https://damsure.nandakrishnan.in/releases/manifest.json` serves an unavailable manifest over valid HTTPS; HSTS is enabled, the server version is hidden, directory listing and missing artifacts return `404`, and the API remains healthy. |

### Remaining release gates

- Store the generated signing key in approved encrypted off-device backup storage before relying on it for a published release.
- Conduct a real-device pilot, including HTTPS transport, upload/download/delete lifecycle, upgrade/migration, and offline-sync recovery.
- The updater remains blocked pending a signed/published release and pilot validation.
- File deletion is best-effort after successful database commit; it has no durable retry/reconciliation queue.

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
