#!/usr/bin/env node
'use strict';

const { verifyApkArtifact } = require('./lib.cjs');

function arg(name) {
  const index = process.argv.indexOf(`--${name}`);
  return index < 0 ? undefined : process.argv[index + 1];
}

async function main() {
  const artifactPath = arg('artifact');
  const expectedPackageId = arg('package-id');
  const expectedVersionCode = Number(arg('version-code'));
  const expectedVersionName = arg('version-name');
  const expectedCertificateSha256 = arg('certificate-sha256');
  const toolManifestPath = arg('tool-manifest');
  const environment = arg('environment');
  if (!artifactPath || !expectedPackageId || !Number.isInteger(expectedVersionCode) || !expectedVersionName || !expectedCertificateSha256 || !toolManifestPath || !['production', 'staging'].includes(environment)) {
    throw new Error('usage: verify-apk.cjs --artifact APK --environment production|staging --package-id ID --version-code N --version-name X.Y.Z --certificate-sha256 SHA256 --tool-manifest PROTECTED_ABSOLUTE_PATH --sha256 SHA256 --size-bytes N');
  }
  const result = await verifyApkArtifact({ artifactPath, expectedPackageId, expectedVersionCode, expectedCertificateSha256,
    expectedVersionName, expectedSha256: arg('sha256'), expectedSizeBytes: arg('size-bytes') ? Number(arg('size-bytes')) : undefined,
    toolManifestPath, environment });
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
}

main().catch((error) => { process.stderr.write(`APK verification failed: ${error.message}\n`); process.exitCode = 1; });
