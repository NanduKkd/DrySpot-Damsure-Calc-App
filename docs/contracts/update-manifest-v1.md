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
  "releaseNotes": "Improved calculation reliability."
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

`schemaVersion` is exactly integer `1`. Revisions, version codes, and byte
sizes are positive JSON integers. The minimum supported code must not exceed
the latest code. Versions are final three-component numeric versions
`X.Y.Z` (no prerelease or build suffixes). SHA-256 is exactly 64 lowercase hex
characters. `publishedAt` is canonical UTC RFC3339 at whole-second precision
(`YYYY-MM-DDTHH:MM:SSZ`) and at most five minutes after the trusted reference.
Release notes are non-empty, trimmed strings of at most 4,000 characters;
disabled reasons use the same rule with a 500-character limit.

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
fields. No other legacy or partial response is supported.

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
them. APP-113 should persist the accepted manifest revision, canonical payload
fingerprint, latest version code, and minimum-supported version code after its
transport and APK gates. It must reject a lower revision, a different payload
at the same revision, and a lower latest or minimum version code. It also owns
APK byte-size/hash, package ID, version code, signing certificate, download,
install, retry, and startup-gate behavior.
