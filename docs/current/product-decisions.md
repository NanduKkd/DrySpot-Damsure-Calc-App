# Product Decisions

Last reconciled: 30 July 2026

## Accepted decisions

### PD-001 — Warranty deletion is permanent and user-confirmed

- Replacing or deleting a warranty must require an explicit confirmation that names the warranty and explains that the warranty record and stored PDF cannot be recovered.
- The warranty row and PDF are permanently deleted.
- Because devices can be offline, permanent deletion must publish a separate deletion tombstone long enough for other devices to observe it. The deleted warranty itself is not retained as a soft-deleted business record.
- Confirmation is required in both the mobile flow and any future administrative flow. The server must never infer confirmation from the existence of a second warranty.

### PD-002 — Sync conflicts use last-write-wins

- The newest valid edit wins for clients, items, rectangles, and default prices.
- Deletes participate in the same ordering and must not be silently reversed by an older offline edit.
- Server-managed fields, tenant ownership, PDF storage metadata, and warranty invariants are never decided by last-write-wins.
- The implementation contract must define timestamp validation, clock-skew handling, and deterministic tie-breaking before code changes begin.

### PD-003 — Updates support optional and required modes

- An optional update may be dismissed and the app remains usable.
- A required update blocks normal app use until a compliant version is installed.
- Required updates are represented by a minimum-supported version, not only a generic boolean, so newer supported releases remain usable.
- A blocked app must still show the reason, target version, release notes, retry action, and a safe HTTPS download action.
- The client must reject disabled, incomplete, non-HTTPS, foreign-host, non-increasing, or checksum-mismatched update metadata.

## Current behavior clarified

### Device login model

- The app stores one token, user, and franchisee in `SharedPreferences`; therefore only one account is active at a time.
- A user can sign out and then sign in with another account. There is no simultaneous multi-login, account list, or one-tap account switcher.
- SQLite data from previous franchisees remains on the device. Client lists, default prices, dirty payloads, and sync timestamps are filtered or keyed by the active franchisee.
- Logout clears session identifiers but does not erase the local database.

Roadmap assumption: retain one active login at a time. A separate task will harden and test sequential account switching and decide whether shared-device data needs encryption, a local wipe option, or an account switcher.

### Current user provisioning

- The mobile app exposes login only.
- Public registration is not routed.
- There is no administrative API, screen, invitation flow, password-reset flow, or supported provisioning command.
- Accounts currently have to be created directly in the database with a bcrypt password hash and a franchisee ID.
- The backend can reject inactive users and revoke all of a user's tokens through `isActive` and `tokenVersion`, but no operator-facing workflow exposes those controls.

## Decisions still required

1. User administration surface: operator CLI, web admin UI, or both.
2. Shared-device policy: retain hidden tenant data, encrypt it, or offer a local wipe on logout.
3. Measurement deletion interaction: confirmation dialog, Undo, or both.
4. Last-write-wins clock policy: accepted clock skew and tie-breaking rule.
5. Required-update emergency policy: whether an already-open offline session receives a grace period.
