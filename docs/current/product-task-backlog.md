# Product Task Backlog

Weights use a relative 1–10 engineering-effort scale and include implementation, automated tests, failure-path proof, and documentation. Tasks are ordered by ascending weight.

| ID | Weight | Priority | Risk | Status | Task | Dependencies |
| :--- | ---: | :--- | :--- | :--- | :--- | :--- |
| APP-101 | 2 | P1 | T1 | Integrated locally | Visible measurement validation | None |
| APP-102 | 2 | P1 | T1 | Integrated locally | Measurement deletion safety | PD-007 |
| APP-103 | 3 | P1 | T2 | Integrated; device proof required | Android permission minimization | None |
| APP-104 | 3 | P0 | T2 | Integrated and verified locally | Update manifest and enforcement contract | PD-003; PD-005 |
| APP-105 | 4 | P1 | T1 | Integrated locally | PDF Unicode font support | None |
| APP-106 | 4 | P0 | T2 | Contract frozen; queued | Shared-device session hardening | PD-010; APP-111 |
| APP-107 | 5 | P0 | T2 | Integrated and independently verified locally; external rollout gated | Update publishing and hosting workflow | APP-104; staging host; signing backup; pilot |
| APP-108 | 6 | P0 | T3 | Integrated and independently verified locally; operator rollout gated | User provisioning and lifecycle MVP | PD-009; APP-110 integration |
| APP-109 | 7 | P1 | T2 | Integrated and verified locally | Durable managed-file cleanup reconciliation | None |
| APP-110 | 8 | P0 | T3 | Integrated and independently verified locally | Sync-safe permanent warranty deletion | PD-001; PD-006; APP-109 |
| APP-111 | 8 | P0 | T3 | Contract frozen | Last-write-wins synchronization | PD-002; PD-008; APP-110 |
| APP-112 | 8 | P1 | T2 | Contract frozen; queued | Sync status and recovery UX | PD-011; APP-106; APP-111 |
| APP-113 | 9 | P0 | T3 | Contract frozen; externally gated | Optional and required Android updater | APP-104; APP-107 staging; APP-112; signing backup; pilot |

## Task contracts

### APP-101 — Visible measurement validation

Objective: invalid dimensions cannot be silently ignored.

Acceptance:

- Empty, non-numeric, zero, negative, and out-of-range dimensions show field-level errors.
- A failed save retains focus and the user's input.
- Valid length and width edits still save inline and recalculate area.

Gates: focused widget tests and `flutter analyze`.

### APP-102 — Measurement deletion safety

Objective: prevent accidental measurement deletion.

Decision: PD-007 selects a named confirmation with Cancel and one destructive Confirm action. Undo is excluded.

Acceptance:

- The user can cancel or reverse an accidental deletion.
- Image-bearing and synced measurements receive equivalent protection.
- Repeated input cannot delete more than one measurement.

Gates: focused widget and provider/database tests.

### APP-103 — Android permission minimization

Objective: request only permissions required by photo and location workflows.

Acceptance:

- Every manifest permission has a mapped product capability.
- Unused audio, video, and legacy storage permissions are removed.
- Photo capture/picker and location flows pass on supported Android versions.

Gates: manifest inspection, release build, and physical-device permission proof.

### APP-104 — Update manifest and enforcement contract

Objective: freeze one versioned contract that supports optional and required updates.

Acceptance:

- Schema includes latest version/code, minimum supported code, immutable HTTPS APK URL, SHA-256, size, publication time, and release notes.
- Client-state examples cover current, optional, required, disabled, malformed, and offline manifests.
- Host allowlist, checksum, version monotonicity, cache, and failure behavior are explicit.

Gates: schema fixtures, parser contract tests, and security review.

Frozen contract summary:

- Versioned strict schema with immutable HTTPS APK URL, exact host/path allowlist, SHA-256, byte size, monotonically increasing version code and manifest revision, publication time, and release notes.
- States are disabled, current, optional, required, malformed, and offline/fetch failure.
- Malformed or unreachable metadata cannot create a new block. A previously validated required policy remains enforced offline under PD-005.
- APP-107 publishes immutable artifacts before atomically replacing the no-store manifest. APP-113 verifies size, hash, package ID, version code, and release certificate before installation.

### APP-105 — PDF Unicode font support

Objective: render rupee symbols and supported local-language/customer text reliably.

Acceptance:

- PDFs embed an approved Unicode font.
- Rupee symbols, Malayalam text, names, addresses, and long lines are visually verified.
- Proposal and warranty PDFs remain readable and within expected page bounds.

Gates: PDF unit tests plus rendered-page visual evidence.

### APP-106 — Shared-device session hardening

Objective: make sequential sign-in by different accounts safe and understandable.

Acceptance:

- Only the active franchisee's records and pending sync work are visible or transmitted.
- Logout/login switching cannot reuse another franchisee's sync cursor or default prices.
- The chosen data-at-rest policy is implemented and explained to the user.
- Simultaneous multi-login and an account picker remain excluded unless separately approved.

Gates: provider/database tests and a real-device two-account scenario.

Frozen contract summary:

- Retain each tenant’s hidden local/offline data; do not add encryption or a wipe flow.
- Logout invalidates a session generation, clears credentials/API auth and all provider/UI state, but preserves tenant rows, dirty work, files, and tenant cursor.
- Sync uses an immutable session snapshot and rechecks it before requests and before applying responses. A stale session response changes nothing locally.
- Tenant scoping moves to database/data-access queries for clients, descendants, default prices, dirty work, photos, and cursor state.
- APP-111 owns the tenant-scoped cursor schema. APP-106 discards the legacy global cursor and must not create a competing cursor store.
- Real-device acceptance uses two real accounts and proves A’s offline work is invisible and unsent under B, then restored unchanged when A returns.

### APP-107 — Update publishing and hosting workflow

Objective: publish immutable, verifiable APK releases without manual metadata drift.

Acceptance:

- Publishing refuses reused version codes, mutable filenames, missing signing evidence, or checksum mismatch.
- Manifest replacement is atomic and supports optional or required enforcement.
- Rollback changes manifest policy without overwriting an existing APK.
- Publication remains blocked until signing backup and pilot gates pass.

Gates: staging-host integration, downloaded checksum proof, Nginx negative tests, and runbook recovery.

Frozen contract summary:

- Production remains on the exact legacy-disabled response until an approved transition to strict disabled v1 revision 1. The first available production policy uses revision 2 or greater.
- Android version code 1 is permanently reserved; the first publishable production APK uses a new code of at least 2 and an immutable `damsure-<versionCode>.apk` name.
- Staging and production use separate Android flavors, application IDs, signing identities, origins, Nginx roots, credentials, and monotonic ledgers. CI rejects a production APK containing the staging hostname or package ID.
- Publishing builds twice from a clean pinned commit, verifies reproducibility plus APK size/hash/package/version/certificate, uploads the immutable artifact first with no-clobber semantics, independently downloads and re-verifies it, then atomically replaces only `manifest.json`.
- Manifest revisions and maximum version codes never decrease. Emergency disable or rollback is a newer strict disabled/available policy; legacy metadata, older revisions, lower codes, and same-revision changed payloads are never restored.
- Dry-run and staging modes cannot write production. Production activation requires named approval, signing-backup restoration proof, the complete dependency set, and a production-signed physical-device pilot.

### APP-108 — User provisioning and lifecycle MVP

Objective: remove direct database manipulation from routine account management.

Acceptance:

- An authorized operator can create a user for one franchisee with a securely hashed initial credential.
- Operators can deactivate/reactivate users and revoke all active tokens.
- Duplicate email, foreign-franchisee assignment, weak credentials, and unauthorized actions are rejected.
- Audit evidence identifies who performed each lifecycle action.
- Public self-registration remains unavailable.

Gates: T3 authorization/tenancy tests, negative tests, audit proof, build, and independent verification.

Frozen contract summary:

- A compiled server-side CLI is the only APP-108 operator surface; web/API administration is excluded.
- Named SSH/sudo operators are mapped by a root-owned wrapper to explicit tenant allow-lists. Actor identity is derived from the validated operating-system identity, never a caller argument.
- Commands cover create, show, deactivate, reactivate, revoke-all-tokens, reset-password, and audit. No deletion, tenant reassignment, impersonation, bulk import, or role management is included.
- Credentials are generated securely or read without echo, bcrypt-hashed at cost 12, displayed once on `/dev/tty`, and prohibited from logs and audit records.
- An append-only audit table records actor, action, tenant/target, reason, idempotency key, redacted before/after lifecycle state, result, host, and application version. Database rules reject audit updates/deletes.
- The CLI runs compiled JavaScript after production dev dependencies are pruned.

### APP-109 — Durable managed-file cleanup reconciliation

Objective: retry physical PDF/photo deletion after committed metadata deletion.

Acceptance:

- Failed cleanup creates an idempotent retry record without reversing the business transaction.
- Retries use bounded backoff and cannot select paths outside managed storage.
- Operators can inspect exhausted retries and reconcile orphan files safely.
- Retrying an already-removed file succeeds idempotently.

Gates: failure injection, traversal negatives, retry/idempotency tests, and operational recovery proof.

### APP-110 — Sync-safe permanent warranty deletion

Objective: permanently delete a confirmed warranty and PDF without allowing offline resurrection.

Acceptance:

- Confirmation names the destructive action and requires a deliberate user response.
- The warranty row and PDF are permanently removed after authorization and transaction success.
- A separate tenant-scoped deletion tombstone reaches offline devices before retention expiry.
- Older edits cannot recreate the warranty after its tombstone.
- A new warranty can be created only after the confirmed deletion succeeds.

Gates: T3 authorization, offline-resurrection, concurrent replacement, file-failure, idempotency, migration, and independent verification.

Frozen contract summary:

- Online, server-authoritative deletion with a named, version-bound confirmation and idempotency key.
- Permanently retained minimal tenant tombstone with a monotonic sequence cursor; tombstones always beat later edits.
- Atomic replacement locks the client, tombstones the confirmed old warranty, queues managed-file cleanup, hard-deletes the old row, and creates the new active warranty in one transaction.
- Flutter applies tombstones before live updates and clears dirty state only from per-change outcomes.
- APP-109 is a hard dependency for the transactional cleanup outbox and operator reconciliation path.

## Active manager program

| Task | Owner | Execution task | Baseline / result |
| :--- | :--- | :--- | :--- |
| APP-101 | Portfolio manager | `019fb3a7-ec62-7302-af36-fefc0667e8bc` | Integrated as `b7ac581`; focused tests and analyze pass |
| APP-103 | Portfolio manager | `019fb3a7-ec63-7dd2-b9d8-5c653622d49f` | Integrated as `b29b631`; automated gates pass, device proof pending |
| APP-104 design | Portfolio manager | `019fb3a7-ec62-7302-af36-ff12211ab995` | Read-only contract frozen against `54b5c5b` |
| APP-104 implementation | Portfolio manager | `019fb3c8-5ff6-7df1-8c41-9c2d5acc363c` | Integrated as `0d8ded9` + `fa6d360` + `fe0c79a`; verifier `019fb3d6-cb2e-79b1-b7d6-5f2fcb6e0821` passed both exact tips |
| APP-105 | Portfolio manager | `019fb3ac-5e7b-73b3-80f9-a8d3b42e2c77` | Integrated as `e6144d0`; Unicode render evidence and gates pass |
| APP-109 | Portfolio manager | `019fb3b0-1b41-7971-8506-629401f2cf41` | Integrated as `bb6ee08` + `7319450`; verifier `019fb3b5-eeae-7660-b05e-4ebd8e12f2a1` passed |
| APP-110 design | Portfolio manager | `019fb3a7-ec62-7302-af36-fed3cac99170` | Read-only T3 contract frozen |
| APP-110 implementation | Portfolio manager | `019fb3c0-7c30-72e3-aab7-945028c25c35` | Integrated as `53d29f2` + `d12006b` + `1797dee` + `5255d7b`; verifier `019fb3db-2529-78f1-95d4-3b0f844d3f97` passed the exact final tip |
| APP-111 | Portfolio manager | `019fb3b0-1b41-7971-8506-627611c50f1e` | Read-only T3 contract frozen |
| APP-102 | Portfolio manager | `019fb3c0-7c2f-7ad1-9dd0-97ef9edfaaa8` | Integrated as `7575cc7`; 8 focused tests and analyze pass |
| APP-108 | Portfolio manager | Design `019fb3bd-1ebf-7130-8fc2-1458f6351c36`; implementation `019fb437-b9e2-7223-8176-e588dfbe3fd7`; verifier `019fb497-c2fb-70b2-a45b-7a9bc7abb934` | Integrated as `e46c08d` + `e176c21` + `174a58a` + `2305f39` + `0510eec`; exact candidate `82089dbe` passed independent T3 verification; operator installation and production proof remain external |
| APP-106 | Portfolio manager | `019fb3c3-fa6c-70e1-8afb-19d2e9f33b75` | Read-only T2 contract frozen; implementation follows APP-111 |
| APP-112 | Portfolio manager | `019fb3d0-8e9b-7430-8a7e-0a2a8d7ed245` | Read-only T2 contract frozen; implementation follows APP-106 and APP-111 |
| APP-113 | Portfolio manager | `019fb3d4-7ccd-7952-b35e-91af07a71f5a` | Read-only T3 contract frozen; implementation follows APP-112 and external staging/signing gates |
| APP-107 | Portfolio manager | Design `019fb3ee-3c42-79d2-b3d4-1b6a718ec025`; implementation `019fb3f2-1ad3-7062-9093-e35a4404421a`; verifier `019fb3ff-648b-7480-8816-9798720b993f` | Integrated as `7c224ff` + `18e5ee4` + `fe767ca` + `427e207` + `f836f9f` + `7588b5f` + `0202f20` + `7878b9b`; exact candidate `f523ec3` passed independent local verification; staging, signing, pilot, approval, and production activation remain external |

Integrated evidence at `7319450`:

- Backend `npm run verify`: lint exits with warnings only; 15 suites / 65 tests pass; TypeScript build passes.
- Flutter `flutter test && flutter analyze`: 102 tests pass; analysis reports no issues.
- APP-109 disposable SQLite migration: forward creates the cleanup table and due index; undo retains the table/data surface and removes only the due index; reapply succeeds; a second forward run is a no-op.
- PostgreSQL migration rehearsal and the APP-103 physical-device permission scenario remain release evidence, not local completion blockers.

Prior integrated checkpoint after APP-102 and the final APP-104 hardening:

- Backend `npm run verify`: lint exits with 91 warnings and no errors; 15 suites / 65 tests pass; TypeScript build passes.
- Flutter `flutter test && flutter analyze`: 122 tests pass; analysis reports no issues.
- APP-110 remains excluded from this checkpoint until its failed T3 candidate is remediated and independently reverified.

Current integrated checkpoint after APP-110:

- Backend `npm run verify`: lint exits with 110 warnings and no errors; 17 suites / 78 tests pass; TypeScript build passes.
- Flutter `flutter test && flutter analyze`: 132 tests pass; analysis reports no issues.
- APP-110's exact final tip passed independent T3 review, including PostgreSQL forward/idempotent/non-destructive-down/reapply, old-writer and lock-inversion proofs, global UUID reservation, opaque cross-tenant behavior, replacement idempotency, cleanup rollback, and end-to-end Flutter CAS/tombstone convergence.
- Production-shaped migration rehearsal and the physical two-device deletion/replacement scenario remain deployment evidence, not local integration blockers.

Current integrated checkpoint after APP-108:

- Backend `npm run verify`: lint exits with warnings and no errors; 21 suites / 97 tests pass; TypeScript build passes.
- APP-108's exact final candidate `82089dbe` passed independent T3 review, including tenant-bound current and legacy cursors, cross-tenant rejection, exact decimal sequences above `2^53`, no skips or duplicates, additive PostgreSQL migration rollback/no-op/undo/reapply, pruned compiled CLI proof, and direct-invocation denial.
- Named Unix/SSH operators, personal keys, tenant allow-lists, root wrapper/sudoers installation, backup and normalization-collision preflight, and staging/production operator runs remain deployment evidence.

### APP-111 — Last-write-wins synchronization

Objective: make the newest valid edit win deterministically across devices.

Acceptance:

- Every mutable entity compares incoming and stored edit versions before mutation.
- Older updates and deletes are ignored without clearing the sender's state incorrectly.
- Newer deletes beat older edits; newer edits follow the approved post-delete policy.
- Equal versions resolve deterministically.
- Invalid and excessive future timestamps follow the approved clock policy.
- Server-managed and tenant-owned fields remain outside conflict resolution.

Gates: cross-device integration matrix, clock-skew/future-time negatives, delete/update races, idempotency, and independent T3 verification.

Frozen contract summary:

- Server-authoritative logical versions replace device timestamps for ordering.
- The comparison tuple is causal generation, bounded local branch sequence, operation rank, installation writer ID, and change ID; delete wins an otherwise equal comparison.
- Server timestamps are authoritative, device timestamps are diagnostics only, and a future clock cannot dominate a later edit.
- Each submitted change receives an explicit applied, already-applied, superseded, rejected, permanently-deleted, or unauthorized outcome.
- Flutter clears dirty state only by compare-and-set against the submitted change. Pull applies data and advances a tenant-scoped monotonic cursor in one local transaction.
- Existing v1 dirty data is drained before a cursor-zero v2 bootstrap. Old clients are rejected before mutation only after the compatibility window closes.
- APP-110 permanent warranty tombstones override this general protocol and must land first.

### APP-112 — Sync status and recovery UX

Objective: make pending work, conflicts, failures, and recovery visible.

Acceptance:

- Users can see last successful sync, current activity, pending record/photo counts, and actionable errors.
- Retry preserves dirty data and cannot duplicate uploads.
- Last-write-wins outcomes are explained when a local edit loses.
- Authentication, network, validation, and required-update failures are distinguished.

Gates: provider/service tests, focused widget tests, offline/reconnect proof, and user validation.

Frozen contract summary:

- A typed, immutable sync view state is bound to APP-106's tenant and session generation. Stale-session results change no database, cursor, provider, or UI state.
- The UI shows the last server-confirmed successful apply, current phase, tenant-only dirty-record/photo counts, APP-111 outcome summaries, and unresolved recovery actions.
- Reconnect is informational and requires a manual retry. Runs are single-flight and never clear dirty data from an aggregate HTTP success.
- Applied, already-applied, superseded, rejected, permanently-deleted, and unauthorized outcomes retain APP-111's exact local semantics and receive distinct user-safe explanations.
- Authentication, authorization, validation, required-update, network, local-storage, and unexpected protocol failures have typed recovery actions; raw exception/server text is never shown.
- Photo uploads gain a stable tenant-scoped idempotency key and durable queue so a lost success response cannot create a duplicate asset on retry.
- Automatic/background sync, merge/diff UI, restoring a losing edit, and changes to APP-111 ordering/cursor rules are excluded.

### APP-113 — Optional and required Android updater

Objective: safely download and enforce releases using APP-104.

Acceptance:

- Optional updates are dismissible and remind according to policy.
- Installed versions below the minimum supported code cannot enter normal app flows.
- The APK is downloaded only from the approved HTTPS host and verified by size and SHA-256 before install.
- Disabled, stale, malformed, downgraded, foreign-host, and checksum-mismatched manifests fail closed.
- Offline required-update behavior follows the approved emergency policy.

Gates: parser/security tests, update-state widget tests, staging download verification, upgrade-over-installed-app proof, and independent T3 verification.

Frozen contract summary:

- Cached update policy is loaded and enforced before authentication restore or any normal app flow. A validated required policy remains blocking across restart and offline use.
- Trusted HTTPS transport, strict parsing, anti-rollback validation, and atomic policy persistence occur before download. Downloaded/verified artifact state is separate from accepted policy state.
- Production manifest and APK requests use the exact release origin/path, reject redirects, and never carry API credentials. Trusted response time comes from the authenticated HTTPS response, not the device clock.
- Optional updates may be dismissed for 24 trusted hours; reconnect and checks do not trigger background download. A newer target or required policy overrides dismissal.
- APKs stream to app-private cache with bounded size/free-space checks. Reuse and installer handoff require size, SHA-256, package ID, version name/code, and pinned signing-certificate revalidation.
- Android uses a non-exported, narrowly scoped `FileProvider` and the system package installer. Silent installation, shared storage, broad storage permission, background/range downloads, and user-configurable endpoints are excluded.
- APP-107 staging, signing-key backup recovery, a production-signed physical-device upgrade pilot, and exact-commit/exact-APK independent T3 verification remain mandatory external gates.
