#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
output="$(mktemp "${TMPDIR:-/tmp}/app113-staging-parser.XXXXXX")"
trap 'rm -f "$output"' EXIT

if ! (
  cd "$repo_root/flutter"
  flutter test --no-pub \
    --flavor staging \
    --dart-define=DAMSURE_RELEASE_FLAVOR=staging \
    --dart-define=DAMSURE_STAGING_ORIGIN=https://staging.example.test \
    test/unit/release_manifest_staging_test.dart
) >"$output" 2>&1; then
  cat "$output" >&2
  exit 1
fi

cat "$output"
if rg -Fq 'Skip:' "$output" ||
    ! rg -Fq 'staging flavor binds only its compile-time release origin' "$output" ||
    ! rg -q -e '\+[1-9][0-9]*: All tests passed!' "$output"; then
  echo 'Staging parser gate did not execute its required test.' >&2
  exit 1
fi
