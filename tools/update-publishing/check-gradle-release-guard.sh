#!/usr/bin/env bash
set -euo pipefail

build_file="$(cd "$(dirname "$0")/../.." && pwd)/flutter/android/app/build.gradle.kts"
rg -Fq 'create("productionRelease")' "$build_file"
rg -Fq 'create("stagingRelease")' "$build_file"
rg -Fq 'productionCertificateSha256' "$build_file"
rg -Fq 'certificatesAreDistinct' "$build_file"
rg -Fq 'Regex("(?i)^(assemble|bundle|package|sign).*release")' "$build_file"

for task in assembleProductionRelease assembleStagingRelease bundleProductionRelease bundleStagingRelease packageProductionRelease packageStagingRelease signProductionRelease signStagingRelease; do
  [[ "$task" =~ ^(assemble|bundle|package|sign).*[Rr]elease$ ]]
done
echo "Gradle flavored release guard coverage verified without signing material."
