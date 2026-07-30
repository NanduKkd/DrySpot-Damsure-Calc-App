# Product Task Backlog

Weights use a relative 1–10 engineering-effort scale and include implementation, automated tests, failure-path proof, and documentation. Tasks are ordered by ascending weight.

| ID | Weight | Priority | Risk | Status | Task | Dependencies |
| :--- | ---: | :--- | :--- | :--- | :--- | :--- |
| APP-101 | 2 | P1 | T1 | Ready | Visible measurement validation | None |
| APP-102 | 2 | P1 | T1 | Draft | Measurement deletion safety | Interaction decision |
| APP-103 | 3 | P1 | T2 | Ready | Android permission minimization | None |
| APP-104 | 3 | P0 | T2 | Ready | Update manifest and enforcement contract | PD-003 |
| APP-105 | 4 | P1 | T1 | Ready | PDF Unicode font support | None |
| APP-106 | 4 | P0 | T2 | Draft | Shared-device session hardening | Shared-device policy |
| APP-107 | 5 | P0 | T2 | Blocked | Update publishing and hosting workflow | APP-104; signing backup; pilot |
| APP-108 | 6 | P0 | T3 | Draft | User provisioning and lifecycle MVP | Administration-surface decision |
| APP-109 | 7 | P1 | T2 | Ready | Durable managed-file cleanup reconciliation | None |
| APP-110 | 8 | P0 | T3 | Ready for design | Sync-safe permanent warranty deletion | PD-001 |
| APP-111 | 8 | P0 | T3 | Ready for design | Last-write-wins synchronization | PD-002; clock policy |
| APP-112 | 8 | P1 | T2 | Pending | Sync status and recovery UX | APP-111 |
| APP-113 | 9 | P0 | T3 | Pending | Optional and required Android updater | APP-104; APP-107 test endpoint |

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

Blocker: choose confirmation, Undo, or both.

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

### APP-107 — Update publishing and hosting workflow

Objective: publish immutable, verifiable APK releases without manual metadata drift.

Acceptance:

- Publishing refuses reused version codes, mutable filenames, missing signing evidence, or checksum mismatch.
- Manifest replacement is atomic and supports optional or required enforcement.
- Rollback changes manifest policy without overwriting an existing APK.
- Publication remains blocked until signing backup and pilot gates pass.

Gates: staging-host integration, downloaded checksum proof, Nginx negative tests, and runbook recovery.

### APP-108 — User provisioning and lifecycle MVP

Objective: remove direct database manipulation from routine account management.

Acceptance:

- An authorized operator can create a user for one franchisee with a securely hashed initial credential.
- Operators can deactivate/reactivate users and revoke all active tokens.
- Duplicate email, foreign-franchisee assignment, weak credentials, and unauthorized actions are rejected.
- Audit evidence identifies who performed each lifecycle action.
- Public self-registration remains unavailable.

Gates: T3 authorization/tenancy tests, negative tests, audit proof, build, and independent verification.

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

### APP-112 — Sync status and recovery UX

Objective: make pending work, conflicts, failures, and recovery visible.

Acceptance:

- Users can see last successful sync, current activity, pending record/photo counts, and actionable errors.
- Retry preserves dirty data and cannot duplicate uploads.
- Last-write-wins outcomes are explained when a local edit loses.
- Authentication, network, validation, and required-update failures are distinguished.

Gates: provider/service tests, focused widget tests, offline/reconnect proof, and user validation.

### APP-113 — Optional and required Android updater

Objective: safely download and enforce releases using APP-104.

Acceptance:

- Optional updates are dismissible and remind according to policy.
- Installed versions below the minimum supported code cannot enter normal app flows.
- The APK is downloaded only from the approved HTTPS host and verified by size and SHA-256 before install.
- Disabled, stale, malformed, downgraded, foreign-host, and checksum-mismatched manifests fail closed.
- Offline required-update behavior follows the approved emergency policy.

Gates: parser/security tests, update-state widget tests, staging download verification, upgrade-over-installed-app proof, and independent T3 verification.
