# Android release signing

The permanent Damsure release key is a local secret. Its active files are
`flutter/android/app/damsure-release.jks` and `flutter/android/key.properties`.
Both are ignored by Git and must remain mode `0600`. The configured alias is
`damsure-release-2026`; do not create a replacement key for an update.

The matching local backup is at `/Users/nandakrishnan/.damsure-release-signing/`:

- directory: mode `0700`;
- `damsure-release-2026.p12`, `key.properties`, and `README.md`: mode `0600`.

The backup `README.md` contains the non-secret restoration procedure. Never commit,
email, chat, or upload the keystore or `key.properties`; they contain the signing
credentials. Before the first publication, create and confirm a separate encrypted,
access-controlled, off-device backup of both files. Publication is blocked until that
backup exists and its restoration procedure has been tested.

The expected signing certificate SHA-256 fingerprint is:

```
09:9D:60:6D:05:CC:99:3C:D4:04:C0:2A:31:4D:7F:01:A0:F7:B8:02:43:DF:FA:79:F5:52:A7:B1:72:51:0A:EF
```

## Version discipline

Set the release version in `flutter/pubspec.yaml` as `version: X.Y.Z+N`. `N` becomes
Android `versionCode` and must be strictly greater than every APK already installed,
shared, or published for `com.dryspotuppala`. Never reuse a version code, including
after a failed or withdrawn distribution. Record the version, APK checksum, and
certificate fingerprint with every release candidate.

## Local signed APK verification

Run these commands from `flutter/`; they never print a password. `keytool` prompts
for the keystore password when needed.

```bash
flutter build apk --release

APK=build/app/outputs/flutter-apk/app-release.apk
APKSIGNER="$ANDROID_HOME/build-tools/36.1.0/apksigner"
"$APKSIGNER" verify --verbose --print-certs "$APK"
shasum -a 256 "$APK"
keytool -list -v -keystore android/app/damsure-release.jks -alias damsure-release-2026
```

The verifier must report one RSA-4096 signer whose SHA-256 certificate digest matches
the fingerprint above. The current application has `minSdkVersion=24`; an APK
Signature Scheme v2 verification is required. Retain the artifact checksum with the
release record before uploading it anywhere.

Release builds prohibit cleartext HTTP. Debug builds alone permit it for a local
development server. Use HTTPS for every release API, APK, and update-manifest URL.

## Staging signing and origin

Staging uses the separate Android application ID `com.dryspotuppala.staging`,
origin `https://staging.damsure.nandakrishnan.in`, and signing alias
`damsure-staging-release-2026`. Its signing files are
`flutter/android/app/damsure-staging-release.jks` and
`flutter/android/staging-key.properties`; both are ignored and must remain mode
`0600`. The matching local backup is under
`/Users/nandakrishnan/.damsure-staging-signing/` with a `0700` directory and
`0600` contents.

The staging certificate SHA-256 fingerprint is recorded in
`flutter/android/release-certificates.properties`. It must remain distinct from
the production certificate. Build staging explicitly with both compile-time
defines:

```bash
flutter build apk --release --flavor staging \
  --build-name=1.0.2 --build-number=2 \
  --dart-define=DAMSURE_RELEASE_FLAVOR=staging \
  --dart-define=DAMSURE_STAGING_ORIGIN=https://staging.damsure.nandakrishnan.in
```

The command above reproduces the currently published staging artifact's package
version. Every later staging build must use the next reserved version code and
the corresponding version name from the protected staging ledger; never rely
on `pubspec.yaml` defaults for a publication candidate.

After every staging build, run the protected verifier before upload. This step
is mandatory because Gradle validates the declared production/staging
fingerprints are distinct, while the verifier binds the actual signed APK to
the committed staging fingerprint:

```bash
APK=build/app/outputs/flutter-apk/app-staging-release.apk
SHA256="$(shasum -a 256 "$APK" | awk '{print $1}')"
SIZE_BYTES="$(stat -f %z "$APK")"
node ../tools/update-publishing/verify-apk.cjs \
  --artifact "$APK" --environment staging \
  --package-id com.dryspotuppala.staging \
  --version-code 2 --version-name 1.0.2 \
  --certificate-sha256 87:EB:D5:D8:7E:CD:4F:91:AA:F7:BF:37:24:7B:7F:94:81:03:FA:48:24:CD:3C:79:65:AE:66:73:EF:55:66:50 \
  --tool-manifest /Users/nandakrishnan/.damsure-staging-signing/android-tool-manifest.json \
  --sha256 "$SHA256" --size-bytes "$SIZE_BYTES"
```

For the current revision-1 artifact, the verifier must report version `1.0.2`
/ code `2`, the fingerprint above, size `61,571,654`, and SHA-256
`020c155b37d8dacd73faed58aa7e194a1e225db11043a804c70cc44c403373d5`.
Do not upload if any field differs.

Never use the staging key for a production artifact or publish a staging APK
under the production release origin.
