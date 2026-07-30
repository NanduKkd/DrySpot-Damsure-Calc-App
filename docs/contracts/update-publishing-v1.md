# Update publishing contract v1

APP-107 is the local, auditable publishing workflow that feeds the strict
APP-104 manifest contract. It does not activate a host, use production
credentials, create a signing key, or authorize a release. APP-113 later
fetches, validates, downloads, and installs a release.

## Current production state

Production remains exactly on the legacy-disabled response in
[`update-manifest-v1.md`](update-manifest-v1.md). No repository command writes
that endpoint. The production ledger starts with revision `0` and historical
maximum version code `1`; this records the permanently reserved local
candidate without changing the hosted response. The only permitted first strict
production transition is a disabled v1 manifest at revision `1`. The first
available production policy is revision `2` or greater.

## Environment isolation

Each environment has a separate ledger, fixture/root, release origin, signing
identity, and credentials. They must never be shared.

| Environment | Android application ID | API/release origin |
| --- | --- | --- |
| production | `com.dryspotuppala` | fixed `https://damsure.nandakrishnan.in` |
| staging | `com.dryspotuppala.staging` | required `DAMSURE_STAGING_ORIGIN` compile-time define |

Gradle rejects a staging compilation without a valid HTTPS origin. Production
compiles a fixed production origin. The `check-production-isolation.sh` gate
builds a production debug APK and rejects the supplied staging origin or
staging package ID if present. It never uses production signing material.

## Ledger and exact manifest generation

Create one JSON ledger per environment outside a release root, with restrictive
permissions. A fresh schema-v1 ledger has revision `0`, max code `1`, and
`reservedVersionCodes: [1]`. `1` can never be reserved or published. Reserve
every new version code before building; reservations remain durable even when a
later build fails. An available policy needs a reserved code strictly above the
ledger's published maximum. Artifact names are exactly
`damsure-<versionCode>.apk`, and an existing name is never overwritten.

Every stored manifest has its complete ordered JSON identity using the exact
APP-104 field order—not delimiter concatenation. Its SHA-256 is an audit aid;
equality uses the full canonical identity. A revision must be higher than the
ledger high-water. Same-revision mutation, lower revisions, lower available
codes, and reused immutable names are refused. Disabled policies do not lower
historical version-code maxima. Emergency disable and rollback require a newly
generated higher v1 revision, never restoration of an older manifest or
deletion of an APK.

`publishedAt` is canonical UTC at whole-second precision. Output contains only
the exact disabled or available v1 fields from APP-104, in canonical order.
Staging's isolated origin is for future-client integration and does not replace
the APP-104 production allowlist.

## Local-only workflow

Every command works only on explicitly supplied local paths. A fixture root
proves upload behavior without an SSH connection.

```bash
# Code 2 is the first publishable code.
node tools/update-publishing/publish.cjs reserve \
  --environment staging --ledger /secure/staging-ledger.json --version-code 2

# This inspects a candidate and changes neither ledger nor fixture root.
node tools/update-publishing/publish.cjs publish \
  --environment staging --ledger /secure/staging-ledger.json \
  --fixture-root /tmp/staging-release-fixture --dry-run \
  --type available --revision 1 --published-at 2026-07-30T12:00:00Z \
  --origin https://staging.example.invalid --version 1.0.2 --version-code 2 \
  --minimum-supported-version-code 1 --sha256 <lowercase-sha256> \
  --size-bytes <bytes> --release-notes 'Pilot build.' \
  --required-update-reason 'Update required.' --artifact candidate.apk
```

Dry-run writes no ledger, fixture root, receipt, temporary manifest, or remote
target. A real available flow checks local size/hash, exclusive-creates the
immutable APK, independently reads uploaded bytes back and checks size/hash,
then writes `manifest.json` to a unique same-directory temporary file and
renames it atomically. Ledger and optional structured receipt are written only
after replacement succeeds. A failed replacement preserves the previous
manifest and ledger; an uploaded immutable artifact remains consumed.

The included SSH abstraction only constructs equivalent no-clobber and atomic
replace commands for a separately approved operator. The CLI never invokes it
and contains no remote host configuration.

## APK verification and production gates

Before an available policy, verify the final APK locally:

```bash
node tools/update-publishing/verify-apk.cjs \
  --artifact app-production-release.apk --package-id com.dryspotuppala \
  --environment production \
  --version-code 2 --version-name 1.0.2 \
  --certificate-sha256 <pinned-certificate-sha256> \
  --tool-manifest /absolute/protected/android-tool-manifest.json \
  --sha256 <lowercase-sha256> --size-bytes <bytes>
```

The helper checks regular-file size/SHA-256, then uses `aapt` for package and
version metadata and `apksigner --verify --print-certs` for certificate
matching. It prints derived metadata only—not passwords, key paths, or signing
options. Reproducible clean pinned-commit builds remain an operational gate;
record both hashes in external release evidence.

Production is hard-disabled unless all explicit local inputs exist: named
`--approval`, `--signing-backup-receipt`, `--pilot-receipt`, and
`--dependency-receipt`. Inputs are evidence placeholders, not deploy
authorization. Production still requires all roadmap dependencies,
signing-backup restoration proof, and a production-signed physical-device
pilot—external gates currently unmet.

## Nginx and recovery

`tools/update-publishing/nginx/damsure-releases.conf.template` serves only the
exact manifest and immutable APK paths, uses no-store for the manifest, refuses
non-GET access, and returns `404` for all other `/releases/` paths. It is never
activated by repository scripts. Run `npm run check:update-nginx` for local
negative checks. A separately approved host change requires a configuration
backup, `nginx -t`, and HTTPS proof of manifest `200`/no-store, directory and
missing-artifact `404`, POST `405`, and API health `200`.

If upload verification fails, do not replace the manifest and retain the
consumed reservation. If manifest replacement fails, prove the old manifest is
still present before retrying. To stop guided updates, publish a new strict
disabled v1 policy; never delete an APK first or restore legacy/older metadata.

## T2 durability and verification hardening

Schema-v2 ledgers bind the canonical non-symlink release root, origin, and
environment. Every mutation takes an auditable sibling `.lock` directory with
PID, UTC acquisition time, and nonce. A live lock waits only briefly before a
clear error; a stale lock needs explicit `--break-stale-lock` and is retained
under a unique stale name. This serializes separate processes and prevents
same-code or same-revision split-brain.

Before a non-dry-run publish, a durable pending-publication journal stores the
exact canonical identity. The journal progresses through prepared,
artifact-uploaded, manifest-replaced, and committed states. Normal retry never
reuses a pending revision. `recover` commits only when the fixture manifest has
the identical canonical identity. Receipt failure records pending evidence in
the ledger and returns an explicit recoverable active status. Receipts use an
operator-supplied canonical `--receipt-at` value; dry-run is always
`activation: not-attempted`.

Available publication performs required APK verification before upload and
again after independent download: ZIP/APK shape, exact size/SHA-256, flavor
package ID, version code/name, and pinned certificate. A protected tool
manifest binds explicit canonical executable paths, their SHA-256 digests, and
the flavor certificate fingerprint; environment-variable tool substitution is
refused.

## Second independent-verification hardening

Locks are never stolen merely because of age. Each acquired lock contains a
random owner nonce; release rechecks both nonce and inode before removal, so an
old owner cannot delete a replacement lock. `recover-lock` is an explicit
operator action requiring a local recovery receipt and a non-live recorded PID;
PID reuse remains fail-closed because liveness is not treated as proof of a
crash.

All journal phases are recoverable. If the exact manifest is present, recovery
commits that identity only. If it is absent before activation, recovery burns
the exact revision and available artifact/version identity, clears the pending
record, and requires a newer revision. A pending receipt stores the complete
sanitized deterministic receipt; `recover --receipt` recreates it idempotently.

Each release root has an exclusive ownership marker binding canonical root,
environment, ledger path, and origin. This prevents staging and production (or
two ledgers) sharing an alias. Tool provenance is supplied by a protected
schema-v1 tool manifest containing canonical non-symlink executable paths,
SHA-256 digests, and distinct flavor certificate fingerprints. The publish
path rejects hash mismatch, writable manifests, symlink parents, and equal
production/staging fingerprints.
