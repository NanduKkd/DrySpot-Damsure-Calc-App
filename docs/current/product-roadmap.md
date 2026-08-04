# Product Roadmap

This roadmap derives from [product decisions](product-decisions.md) and the detailed [product task backlog](product-task-backlog.md). One coordinator owns integration. At most two write-heavy tasks should be active at once; additional capacity should be used for design, read-only review, or verification.

## Parallel workstreams

| Lane | Scope | Ordered tasks | Primary shared surface |
| :--- | :--- | :--- | :--- |
| A — Mobile quality | Fast field-workflow safety and platform quality | APP-101 → APP-102 → APP-105 → APP-103 → APP-106 | Flutter UI, providers, Android project |
| B — Identity and operations | Account lifecycle and cleanup reliability | APP-109 → APP-108 | Backend managed storage, auth/models, operations |
| C — Data consistency | Destructive warranty lifecycle and conflicts | APP-110 → APP-111 → APP-112 | Sync protocol, warranty controllers, local database |
| D — Releases | Optional/required update delivery | APP-104 → APP-107 → APP-113 | Manifest contract, hosting, Flutter startup |

Lane C is serialized because permanent deletion and last-write-wins share sync semantics, tombstones, migrations, and destructive concurrency. APP-112 follows their accepted protocol. APP-113 must not overlap APP-112 in Flutter because both change startup/global recovery UX.

## Delivery waves

### Wave 0 — Freeze contracts in parallel

Run as parallel design work with no source-code mutation:

1. APP-110 deletion-tombstone design and retention policy.
2. APP-111 last-write-wins clock/tie policy.
3. APP-104 optional/required manifest contract.
4. APP-108 administration-surface decision.
5. APP-106 shared-device data-at-rest decision.

Exit: APP-104, APP-106, APP-108, APP-110, and APP-111 have complete acceptance contracts and no unresolved product dependency.

### Wave 1 — Two independent implementation lanes

- Slot 1, Lane A: APP-101 and APP-102, followed by APP-105 and APP-103.
- Slot 2, Lane B: APP-108.

These lanes are independent in code and runtime. Integrate each task separately and rerun Flutter gates after the final Lane A rebase.

### Wave 2 — Data safety plus release hosting

- Slot 1, operations prerequisite: APP-109, then Lane C APP-110 and APP-111.
- Slot 2, Lane D: APP-107 against the frozen APP-104 contract.

APP-109 must provide the durable cleanup outbox before APP-110 changes warranty deletion. Do not run APP-110 and APP-111 concurrently. Both are T3 and require exact-commit independent verification.

### Wave 3 — Operational resilience

- Slot 1, Lane B: APP-108.
- Slot 2, Lane A: APP-106.

APP-106 should use two real accounts and a physical device. APP-109 uses isolated failure injection and must not operate against production storage.

### Wave 4 — User-facing recovery

1. APP-112 sync status and recovery UX.
2. APP-113 optional/required Android updater.

These are serialized through the Flutter integration lane. APP-113 may be developed against a staging manifest while production remains disabled.

## Publication milestone

Publication is allowed only when:

- APP-103, APP-104, APP-106, APP-107, APP-110, APP-111, APP-112, and APP-113 are accepted;
- the permanent signing key has an approved encrypted off-device backup with tested recovery;
- a physical-device pilot passes upgrade, required-update, optional-update, offline sync, tenant switching, PDF/photo lifecycle, and warranty deletion;
- the final APK version code is new, its signature and checksum are recorded, and the production manifest is changed atomically from disabled to the approved release policy.

APP-101, APP-102, and APP-105 are strongly recommended before the pilot. APP-108 and APP-109 may be released in the same train or operated through a documented temporary process, but direct ad-hoc database provisioning and unmonitored cleanup are not acceptable for broad distribution.
