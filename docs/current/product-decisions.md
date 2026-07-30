# Product Decisions

Last reconciled: 30 July 2026

## Accepted decisions

### PD-004 — Measurement inputs use a defensive per-dimension limit

- Length and width must each be finite, greater than zero, and no more than 10,000 feet.
- The ceiling applies per dimension; APP-101 does not add a separate total-area cap.
- Invalid inline edits must retain the user's text and focus so the value can be corrected in place.

### PD-005 — A previously validated required update remains enforced offline

- A malformed, unavailable, or unreachable manifest cannot create a new required-update block.
- Once a valid manifest establishes that the installed version is below the minimum supported version, the required block remains in force while offline.
- The app may offer retry and a previously validated safe download target, but it cannot relax the minimum-version policy without a newer valid manifest or a valid disabled manifest.

### PD-006 — Permanent warranty deletion is online and server-authoritative

- APP-110 deletion requires connectivity and a named, version-bound confirmation.
- A minimal tenant-scoped tombstone is retained indefinitely; finite retention is excluded until device acknowledgments and a stale-device full-resync barrier exist.
- Replacement is one atomic server transaction that tombstones the explicitly confirmed old warranty and creates the new warranty.
- Tombstones override every later warranty edit regardless of device timestamps.
- Database deletion is complete once the transaction commits. Physical PDF cleanup is handled by the durable reconciliation mechanism from APP-109; the user does not wait for unlink completion.
- Legacy soft-deleted warranty rows may be hard-deleted only after an idempotent tombstone backfill succeeds.

### PD-007 — Measurement deletion requires confirmation

- Deleting a measurement opens a confirmation that identifies it by its dimensions.
- The user can cancel or deliberately confirm the destructive action. Undo is excluded from APP-102.
- Local, synced, and image-bearing measurements receive the same protection.
- Repeated taps or submissions cannot delete more than the one confirmed measurement.

### PD-008 — Sync conflicts use logical versions, not device clocks

- “Newest” means logically or causally newest. Device wall-clock time is diagnostic only and never decides a winner.
- Each mutable client, item, rectangle, and default-price record carries a server-observed generation plus a bounded local branch sequence, operation rank, installation writer ID, and change ID.
- The greatest valid logical version wins deterministically. At the same generation and branch sequence, delete beats update; an update based on a strictly newer generation may restore those four soft-deleted entity types.
- The server returns one outcome per submitted change. Flutter clears pending state only by compare-and-set against the acknowledged change ID; an aggregate HTTP success never clears unrelated or newer local work.
- Pull synchronization uses a tenant-scoped monotonic cursor, not `updated_at`.
- Warranty deletion is the permanent exception: an APP-110 tombstone defeats every later mutation, and a historically used warranty UUID cannot be reused by another tenant.

### PD-009 — User administration is CLI-first

- APP-108 delivers a compiled server-side operator CLI over a reusable administration service. Web administration, invitations, and self-service password recovery are separately scoped.
- Production operators use named Unix/SSH accounts and personal keys. A root-owned wrapper and restricted sudo rule map the operating-system identity to an explicit franchisee allow-list.
- No public admin route or mobile administration screen is added.
- Creation, deactivation, reactivation, password reset, and token revocation are transactional, idempotent, tenant-scoped, and append an immutable audit event.
- Initial/reset credentials are generated securely or read from a no-echo TTY/stdin path, displayed once on `/dev/tty`, and never placed in arguments, logs, JSON, or audit data.

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

1. Shared-device policy: retain hidden tenant data, encrypt it, or offer a local wipe on logout.
