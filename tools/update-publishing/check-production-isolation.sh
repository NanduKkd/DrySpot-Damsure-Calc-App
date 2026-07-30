#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 https://staging.example.invalid" >&2
  exit 2
fi
staging_origin="$1"
if [[ ! "$staging_origin" =~ ^https://[^/]+$ ]]; then
  echo "Staging origin must be an HTTPS origin without a path." >&2
  exit 2
fi

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
flutter_dir="$repo_root/flutter"
production_id='com.dryspotuppala'
staging_id='com.dryspotuppala.staging'

rg -Fq "applicationId = \"$production_id\"" "$flutter_dir/android/app/build.gradle.kts"
rg -Fq "applicationId = \"$staging_id\"" "$flutter_dir/android/app/build.gradle.kts"
rg -Fq "DAMSURE_STAGING_ORIGIN" "$flutter_dir/lib/src/config/app_config.dart"
rg -Fq "productionServerUrl = 'https://damsure.nandakrishnan.in'" "$flutter_dir/lib/src/config/app_config.dart"
if rg -F -- "$staging_origin" "$flutter_dir/lib" "$flutter_dir/android"; then
  echo "Source unexpectedly embeds the supplied staging origin." >&2
  exit 1
fi

cd "$flutter_dir"
flutter build apk --debug --flavor production --no-pub
apk='build/app/outputs/flutter-apk/app-production-debug.apk'
[[ -f "$apk" ]]

if command -v aapt >/dev/null 2>&1; then
  aapt dump badging "$apk" | rg -Fq "package: name='$production_id'"
fi
if unzip -p "$apk" | strings | rg -F -e "$staging_origin" -e "$staging_id"; then
  echo "Production APK contains a staging origin or staging application ID." >&2
  exit 1
fi
echo "Production flavor isolation verified: $production_id; staging origin and package absent."
