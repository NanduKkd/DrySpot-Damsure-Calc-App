# Update manifest contract v1

APP-104 defines validation only. It does not fetch the manifest, persist a
policy, download an APK, install an APK, block startup, or publish a release.
Those responsibilities are APP-107 and APP-113.

## Trust boundary

The sole manifest URL is `https://damsure.nandakrishnan.in/releases/manifest.json`.
It is a constant and is never derived from the user-configurable API URL.
The response must be treated as no-store. An available artifact URL is accepted
only when it is byte-for-byte exactly
`https://damsure.nandakrishnan.in/releases/damsure-<latestVersionCode>.apk`.
This excludes alternate hosts, ports (including an explicit `:443`),
credentials, query strings, fragments, redirects encoded as a URL, and path or
version-code mismatches.

The parser receives a trusted UTC reference time from its caller; it does not
read the device clock. APP-113 must establish that reference from a trusted
release-response time source and persist validated policy separately.

## Strict JSON shapes

Only the following exact field sets are accepted. All unknown, omitted, or
wrongly typed fields reject the entire response.

Available manifest:

```json
{
  "schemaVersion": 1,
  "updatesEnabled": true,
  "manifestRevision": 42,
  "latestVersion": "1.4.0",
  "latestVersionCode": 10400,
  "minimumSupportedVersionCode": 10300,
  "artifactUrl": "https://damsure.nandakrishnan.in/releases/damsure-10400.apk",
  "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "sizeBytes": 12345678,
  "publishedAt": "2026-07-30T10:00:00Z",
  "releaseNotes": "Improved calculation reliability.",
  "requiredUpdateReason": "Please update to continue using Damsure."
}
```

Disabled manifest:

```json
{
  "schemaVersion": 1,
  "updatesEnabled": false,
  "manifestRevision": 43,
  "publishedAt": "2026-07-30T10:05:00Z",
  "reason": "Updates are temporarily unavailable."
}
```

`schemaVersion` is exactly Dart/JSON integer `1`; `1.0` is rejected. Manifest
revisions, version codes, and byte sizes are positive signed 32-bit JSON
integers (at most `2147483647`); wrong numeric types and larger values are
rejected. The minimum supported code must not exceed the latest code. Versions
are final three-component numeric versions `X.Y.Z` (no prerelease or build
suffixes). SHA-256 is exactly 64 lowercase hex characters. `publishedAt` is
canonical UTC RFC3339 at whole-second precision (`YYYY-MM-DDTHH:MM:SSZ`) and at
most five minutes after the trusted reference.
Release notes are non-empty, trimmed strings of at most 4,000 characters.
`requiredUpdateReason` is separately required on every available manifest and
is a non-empty, trimmed string of at most 500 characters. Disabled reasons use
the same 500-character rule.

Migration compatibility is limited to the exact currently hosted four-field
response:

```json
{
  "status": "unavailable",
  "updatesEnabled": false,
  "message": "No Android release has been published.",
  "publishedAt": null
}
```

It is disabled-only, has synthetic revision zero, and may not carry any extra
fields. Its message text is exact; arbitrary legacy messages are rejected. No
other legacy or partial response is supported.

## Classification and failure behavior

For a valid available policy: installed code below `minimumSupportedVersionCode`
is **required**; otherwise below `latestVersionCode` is **optional**; otherwise
it is **current**. This deliberately classifies an installed newer build as
current and never proposes a downgrade. Valid disabled metadata is **disabled**.
Every parsing failure is **malformed** and retains no URL, release notes, or
server-provided reason for a caller to display.

An unavailable/fetch failure is not classified by this pure parser. Under
PD-005, it cannot create a new required block. APP-113 must retain an already
validated required policy while offline and may relax it only under the stated
valid-policy rules.

## APP-113 anti-rollback integration

The parser provides explicit high-water validation helpers but does not persist
them. APP-113 should persist each accepted strict v1 policy immediately after
trusted transport, strict parsing, and anti-rollback validation: its revision,
canonical payload fingerprint, and the historical maximum latest and minimum
version codes. The canonical fingerprint is ordered JSON with the exact v1
available fields in the contract order and their native JSON types; it includes
`requiredUpdateReason`. This is unambiguous for strings containing delimiters
and does not require a hash dependency. Strict disabled v1 policies likewise
use ordered JSON over exactly their five fields.

The client must reject a lower revision and a different payload at the same
revision for both available and strict disabled v1 policies. It must reject a
lower latest or minimum version code on a later available policy. A newer
strict disabled policy may relax cached required policy under PD-005, but it
retains the historical version-code maximums for a later available policy.
The exact legacy disabled response is accepted only when no v1 policy
high-water exists; it is never persisted and never advances or clears that
high-water. It must be rejected after any v1 state exists.

This accepted-policy state is separate from downloaded-artifact state: only an
APK that subsequently passes byte-size, hash, package ID, version code, and
signing-certificate verification may be offered for installation. APP-113 also
owns download, install, retry, and startup-gate behavior.
