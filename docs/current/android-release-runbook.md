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
