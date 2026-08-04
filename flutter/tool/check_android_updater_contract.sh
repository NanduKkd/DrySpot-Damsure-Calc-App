#!/usr/bin/env bash

# Static guard for the native half of APP-113. Runtime/device installation
# remains an external T3 gate, but production source must never drift toward
# broad storage, an exported provider, or caller-controlled trust values.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FLUTTER_DIR="$(dirname "$SCRIPT_DIR")"
MANIFEST="$FLUTTER_DIR/android/app/src/main/AndroidManifest.xml"
HANDLER="$FLUTTER_DIR/android/app/src/main/kotlin/com/dryspotuppala/UpdateInstallHandler.kt"
ACTIVITY="$FLUTTER_DIR/android/app/src/main/kotlin/com/dryspotuppala/MainActivity.kt"
GRADLE="$FLUTTER_DIR/android/app/build.gradle.kts"
PATHS="$FLUTTER_DIR/android/app/src/main/res/xml/update_file_paths.xml"

require() {
  local file="$1"
  local pattern="$2"
  if ! grep -Fq "$pattern" "$file"; then
    echo "Missing APP-113 Android guard: $pattern ($file)" >&2
    exit 1
  fi
}

forbid() {
  local file="$1"
  local pattern="$2"
  if grep -Fq "$pattern" "$file"; then
    echo "Forbidden APP-113 Android surface: $pattern ($file)" >&2
    exit 1
  fi
}

require "$MANIFEST" 'android.permission.REQUEST_INSTALL_PACKAGES'
require "$MANIFEST" 'androidx.core.content.FileProvider'
require "$MANIFEST" 'android:authorities="${applicationId}.update_file_provider"'
require "$MANIFEST" 'android:exported="false"'
require "$MANIFEST" 'android:grantUriPermissions="true"'
require "$PATHS" '<cache-path name="verified_updates" path="updates/" />'
forbid "$PATHS" 'external-path'
forbid "$PATHS" 'path="."'
require "$HANDLER" 'getPackageArchiveInfo'
require "$HANDLER" 'GET_SIGNING_CERTIFICATES'
require "$HANDLER" 'PackageInfoFlags.of'
require "$HANDLER" 'apkContentsSigners'
require "$HANDLER" 'hasMultipleSigners()'
require "$HANDLER" 'signingCertificateHistory.size != 1'
require "$HANDLER" 'UPDATE_EXPECTED_PACKAGE_ID'
require "$HANDLER" 'UPDATE_PINNED_CERTIFICATE_SHA256'
require "$HANDLER" 'FileProvider.getUriForFile'
require "$HANDLER" 'FLAG_GRANT_READ_URI_PERMISSION'
require "$ACTIVITY" 'ACTION_MANAGE_UNKNOWN_APP_SOURCES'
forbid "$HANDLER" 'ACTION_INSTALL_PACKAGE'
require "$GRADLE" 'UPDATE_EXPECTED_PACKAGE_ID'
require "$GRADLE" 'UPDATE_PINNED_CERTIFICATE_SHA256'
require "$GRADLE" 'requireProductionDefinesAtCompileTime'
require "$GRADLE" 'requireStagingOriginAtCompileTime'

echo "APP-113 Android updater static contract verified."
