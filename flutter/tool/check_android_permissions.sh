#!/usr/bin/env bash

# Verifies the merged Android manifest exposes only the permissions tied to a
# Damsure capability. Run this after dependency changes as plugins can add
# manifest permissions transitively.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FLUTTER_DIR="$(dirname "$SCRIPT_DIR")"

cd "$FLUTTER_DIR"
flutter build apk --debug --flavor production \
  --dart-define=DAMSURE_RELEASE_FLAVOR=production

MERGED_MANIFEST=$(find "$FLUTTER_DIR/build/app/intermediates/merged_manifests/productionDebug" \
  -path '*/AndroidManifest.xml' -print -quit)

if [[ -z "$MERGED_MANIFEST" || ! -f "$MERGED_MANIFEST" ]]; then
  echo "Debug merged AndroidManifest.xml was not produced." >&2
  exit 1
fi

required_permissions=(
  "android.permission.INTERNET"
  "android.permission.ACCESS_NETWORK_STATE"
  "android.permission.ACCESS_COARSE_LOCATION"
  "android.permission.ACCESS_FINE_LOCATION"
  "android.permission.REQUEST_INSTALL_PACKAGES"
)

# Photo capture and gallery selection use Android intents/photo picker; no
# broad shared-media permission is needed. Audio and external-storage access
# are outside the product's capabilities.
forbidden_permissions=(
  "android.permission.CAMERA"
  "android.permission.RECORD_AUDIO"
  "android.permission.READ_EXTERNAL_STORAGE"
  "android.permission.WRITE_EXTERNAL_STORAGE"
  "android.permission.MANAGE_EXTERNAL_STORAGE"
  "android.permission.READ_MEDIA_IMAGES"
  "android.permission.READ_MEDIA_VIDEO"
  "android.permission.READ_MEDIA_AUDIO"
  "android.permission.READ_MEDIA_VISUAL_USER_SELECTED"
)

for permission in "${required_permissions[@]}"; do
  if ! grep -Fq "android:name=\"$permission\"" "$MERGED_MANIFEST"; then
    echo "Missing required permission: $permission" >&2
    exit 1
  fi
done

for permission in "${forbidden_permissions[@]}"; do
  if grep -Fq "android:name=\"$permission\"" "$MERGED_MANIFEST"; then
    echo "Forbidden permission present: $permission" >&2
    exit 1
  fi
done

actual_permissions=$(grep -o 'android:name="android.permission.[^"]*"' "$MERGED_MANIFEST" | \
  sed 's/android:name="//; s/"//' | sort -u)
expected_permissions=$(printf '%s\n' "${required_permissions[@]}" | sort)

if [[ "$actual_permissions" != "$expected_permissions" ]]; then
  echo "Merged Android manifest permissions do not match the approved capability map." >&2
  echo "Expected:" >&2
  printf '%s\n' "$expected_permissions" >&2
  echo "Actual:" >&2
  printf '%s\n' "$actual_permissions" >&2
  exit 1
fi

echo "Android permissions verified: INTERNET (API sync/photo transfer), ACCESS_NETWORK_STATE (sync reconnect status),"
echo "ACCESS_COARSE_LOCATION and ACCESS_FINE_LOCATION (current client location),"
echo "REQUEST_INSTALL_PACKAGES (user-initiated verified private-APK handoff)."
