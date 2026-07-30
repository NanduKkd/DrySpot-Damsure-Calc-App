# Test Results

## Current integrated validation (2026-07)

| Test Area | Status | Evidence / limitation |
| :--- | :--- | :--- |
| Backend verification | PASS | `npm run verify`: build passes; 14 Jest suites / 59 tests pass. Lint exits 0 with 84 warnings. Production dependency audit passes at the high threshold with 2 moderate Sequelize/`uuid` advisories remaining. |
| Flutter verification | PASS | 99 tests pass; `flutter analyze` exits 0 with no issues. |
| Android release packaging and signing | PASS | `flutter build apk --release` passed. `app-release.apk` SHA-256: `b0b77a82deaeec29c0d37fbb7a5521956a082afd9ed191c94d8885e8c8bdbcc4`; `apksigner` verified v2 signing with an RSA-4096 certificate (SHA-256 `09:9D:60:6D:05:CC:99:3C:D4:04:C0:2A:31:4D:7F:01:A0:F7:B8:02:43:DF:FA:79:F5:52:A7:B1:72:51:0A:EF`) and minSdk 24. The APK was not published. |
| PostgreSQL migration | PASS (production-copy rehearsal) | A root-only compressed backup of production was restored into a disposable database. Forward migration verified the added columns, `SequelizeMeta`, newest non-deleted warranty backfill, both unique guards, and rejection of an old-process duplicate active-warranty insert. Undo removed both indexes/meta while retaining columns/data; reapply restored both guards and a second forward run was a no-op. The disposable database was dropped and its absence verified; production was not mutated. |
| Hosted release manifest | PASS (disabled state) | `https://damsure.nandakrishnan.in/releases/manifest.json` returned `200 application/json` with `updatesEnabled: false`, `Cache-Control: no-store`, HSTS, and no server-version disclosure; release directory and missing APK requests returned `404`, POST returned `405`, and API health remained `200`. |
| Real-device / production | NOT RUN | No real-device pilot, production deploy, or APK publication. The release branch is pushed in a draft PR. Local signing material is ignored with restrictive permissions; approved encrypted off-device backup remains required. |

Security-focused backend coverage includes tenant ownership across sync mutations/deletions, revoked/inactive JWT users, default/short JWT-secret rejection, public registration removal, managed warranty/proposal file metadata in both snake_case and camelCase input, active-warranty replacement/conflict behavior, and portable client-photo upload, filtering, access, and cleanup behavior.

This document records the execution of the test cases defined in the test plan.

## Historical baseline summary

| Test Area | Status | Notes |
| :--- | :--- | :--- |
| Backend Tests | PENDING | Baseline tests pass; new tests not yet created. |
| Flutter Tests | PENDING | Baseline tests pass; new tests not yet created. |
| Integration Tests | PENDING | UI and integration tests not yet run. |

## Historical baseline status

Before starting the new implementation, existing tests were run to ensure a stable baseline.

- **Backend Baseline**: `npm --prefix backend run test` -> **PASS**
- **Flutter Baseline**: `cd flutter && flutter test` -> **PASS**

## Historical execution logs

### 2026-04-08 10:00:00 (Baseline Verification)

| ID | Status | Command | Result |
| :--- | :--- | :--- | :--- |
| BASE-BE | PASS | `npm --prefix backend run test` | 8/8 passed, 15 tests total. |
| BASE-FL | PASS | `cd flutter && flutter test` | 56 tests passed. |

## Historical pending items (superseded where implemented)

| ID | Status | Reason |
| :--- | :--- | :--- |
| BE-1 | PENDING | `Proposal` model does not exist yet. |
| BE-2 | PENDING | `uploadWarranty` logic not yet updated. |
| BE-3 | PENDING | `sync` logic for PDFs not yet implemented. |
| FL-1 | PENDING | `proposals` table and model do not exist yet. |
| FL-2 | PENDING | `SyncService` update pending. |
| FL-3 | PENDING | `WarrantyFormScreen` does not exist yet. |
| FL-4 | PENDING | `PdfManagementScreen` does not exist yet. |
| FL-5 | PENDING | UI logic for one-warranty constraint pending. |

Historical status: **READY_FOR_DEV**. Current status and remaining gates are recorded above.
