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
  const expectedCertificateSha256 = arg('certificate-sha256');
  if (!artifactPath || !expectedPackageId || !Number.isInteger(expectedVersionCode) || !expectedCertificateSha256) {
    throw new Error('usage: verify-apk.cjs --artifact APK --package-id ID --version-code N --certificate-sha256 SHA256 [--sha256 SHA256] [--size-bytes N]');
  }
  const result = await verifyApkArtifact({ artifactPath, expectedPackageId, expectedVersionCode, expectedCertificateSha256,
    expectedSha256: arg('sha256'), expectedSizeBytes: arg('size-bytes') ? Number(arg('size-bytes')) : undefined,
    aapt: process.env.AAPT || 'aapt', apksigner: process.env.APKSIGNER || 'apksigner' });
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
}

main().catch((error) => { process.stderr.write(`APK verification failed: ${error.message}\n`); process.exitCode = 1; });
