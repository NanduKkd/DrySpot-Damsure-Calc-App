#!/usr/bin/env bash
set -euo pipefail

template="${1:-$(cd "$(dirname "$0")" && pwd)/nginx/damsure-releases.conf.template}"
rg -Fq 'location = /releases/manifest.json' "$template"
rg -Fq 'no-store, max-age=0' "$template"
rg -Fq 'location ~ ^/releases/(damsure-[1-9][0-9]*\.apk)$' "$template"
rg -Fq 'location /releases/' "$template"
rg -Fq 'return 404;' "$template"
if rg -n 'autoindex\s+on|proxy_pass' "$template"; then
  echo "Release template allows directory exposure or proxying." >&2
  exit 1
fi
echo "Nginx release template negative checks passed."
