#!/usr/bin/env bash
set -euo pipefail

template="${1:-$(cd "$(dirname "$0")" && pwd)/nginx/damsure-releases.conf.template}"
rg -Fq 'location = /releases/manifest.json' "$template"
rg -Fq 'no-store, max-age=0' "$template"
rg -Fq 'if ($request_method !~ ^(GET|HEAD)$) { return 405; }' "$template"
rg -Fq 'location ~ ^/releases/(damsure-[1-9][0-9]*\.apk)$' "$template"
rg -Fq 'location /releases/' "$template"
rg -Fq 'return 404;' "$template"
rg -Fq 'public, max-age=31536000, immutable' "$template"
if rg -n 'autoindex\s+on|proxy_pass|limit_except' "$template"; then
  echo "Release template allows directory exposure or proxying." >&2
  exit 1
fi
node - "$template" <<'NODE'
const fs = require('node:fs');
const assert = require('node:assert/strict');
const body = fs.readFileSync(process.argv[2], 'utf8');
function response(method, resource) {
  if (!['GET', 'HEAD'].includes(method)) return 405;
  if (resource === '/releases/manifest.json') return 200;
  if (/^\/releases\/damsure-[1-9][0-9]*\.apk$/.test(resource)) return 200;
  return 404;
}
assert.equal(response('GET', '/releases/manifest.json'), 200);
assert.equal(response('HEAD', '/releases/damsure-2.apk'), 200);
assert.equal(response('POST', '/releases/manifest.json'), 405);
assert.equal(response('DELETE', '/releases/damsure-2.apk'), 405);
assert.equal(response('GET', '/releases/'), 404);
assert.equal(response('GET', '/releases/not-an-apk'), 404);
assert.match(body, /no-store, max-age=0/);
assert.match(body, /max-age=31536000, immutable/);
NODE
echo "Nginx release template negative checks passed."
