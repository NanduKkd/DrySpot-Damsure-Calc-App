# Android release hosting runbook

The release metadata endpoint is `https://damsure.nandakrishnan.in/releases/manifest.json`. It is served by Nginx from `/var/www/damsure-releases/` and is intentionally separate from the API proxy. The `/releases/` directory has no listing; missing artifacts return `404`.

## Disabled state (current)

No APK is published. The manifest is deliberately non-actionable and must remain so until a signed release has passed the release gate:

```json
{
  "status": "unavailable",
  "updatesEnabled": false,
  "message": "No Android release has been published.",
  "publishedAt": null
}
```

Do not add a version, artifact URL, checksum, or `updatesEnabled: true` to this manifest until the client-side updater has been implemented and its verification contract tested. Never copy a development, unsigned, or unverified APK into `/var/www/damsure-releases/`.

## Safe publishing sequence

1. Complete the Android release runbook: build a signed artifact with the permanent backed-up key, verify its signing certificate, and record its SHA-256.
2. Test the exact artifact on a real Android device, including installation/upgrade and sync recovery. Keep the disabled manifest in place during this pilot.
3. Use an immutable, versioned filename such as `damsure-<version-code>.apk`; never replace an existing filename. Copy the verified APK into `/var/www/damsure-releases/` with root ownership and non-writable permissions for the web user.
4. Verify over HTTPS that the APK returns the expected content type and bytes. Recalculate the downloaded SHA-256 and compare it with the release record.
5. Only after those checks, replace the manifest atomically with the client-approved active schema containing the HTTPS APK URL, version information, SHA-256, publication time, and explicit update enablement. Verify the manifest over HTTPS before announcing it.

The active manifest schema is intentionally not finalized by this runbook: the mobile client must reject incomplete fields, non-HTTPS URLs, foreign hosts, mismatched hashes, non-increasing versions, and disabled/unavailable manifests before hosting is enabled.

## Cache and integrity rules

- The manifest response uses `Cache-Control: no-store, max-age=0`; do not loosen it.
- Artifact responses currently use `Cache-Control: public, max-age=3600`. Versioned filenames are mandatory so cache refreshes can never change the bytes associated with a published version.
- Use a SHA-256 calculated from the final uploaded APK and verify it again by downloading the HTTPS URL. Android signing-certificate verification remains mandatory; a checksum alone is not sufficient.
- Preserve older verified artifacts until the pilot and rollback windows have closed.

## Rollback and server validation

To stop guided updates immediately, atomically restore the disabled manifest above. Do not delete an APK first: an existing manifest could then point to a missing artifact.

For any Nginx change, first save the current Damsure site configuration in `/root/nginx-config-backups/`, run `nginx -t`, and reload Nginx only when that command succeeds. Re-check the manifest, directory-listing rejection, missing-artifact rejection, and API health after reload. A validated configuration backup can be restored and tested before another reload if recovery is needed.

This hosting endpoint does not itself authorize an update. APK publication and manifest activation are separate, deliberate release actions.

## Staging release host

`https://staging.damsure.nandakrishnan.in/releases/manifest.json` is the
isolated staging release endpoint. Nginx serves it from
`/var/www/damsure-staging-releases/`; it does not proxy API traffic and all
non-release paths return `404`. The staging release root, manifest history,
ledger, APKs, certificate, signing identity, and receipts must remain separate
from production.

Staging currently serves strict manifest revision `1` and immutable artifact
`damsure-2.apk`, package `com.dryspotuppala.staging`, version `1.0.2` / code `2`.
The artifact is 61,571,654 bytes with SHA-256
`020c155b37d8dacd73faed58aa7e194a1e225db11043a804c70cc44c403373d5`.
The protected local ledger, receipt, signer backup, and exact publication
fixture are under `/Users/nandakrishnan/.damsure-staging-signing/`.

The staging artifact and manifest were uploaded using no-overwrite and atomic
replacement semantics, then independently downloaded over public HTTPS and
verified byte-for-byte. Production remained unchanged. Future staging releases
must reserve a new version code and manifest revision and must never overwrite
`damsure-2.apk` or restore an older manifest.
