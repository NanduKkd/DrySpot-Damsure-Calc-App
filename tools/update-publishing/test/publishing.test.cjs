'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const {
  LEGACY_DISABLED_MANIFEST, LocalReleaseTarget, applyPublishedManifest, basicArtifactMetadata,
  buildManifest, canonicalManifestIdentity, emptyLedger, publishToLocalFixture, reserveVersionCode,
  verifyApkArtifact,
} = require('../lib.cjs');

const productionOrigin = 'https://damsure.nandakrishnan.in';
const time = '2026-07-30T12:00:00Z';

async function fixture() { return fs.mkdtemp(path.join(os.tmpdir(), 'damsure-publish-')); }
async function availableManifest(ledger, root, revision = 2, code = 2) {
  const artifact = path.join(root, 'candidate.apk');
  await fs.writeFile(artifact, 'APK fixture bytes');
  const metadata = await basicArtifactMetadata(artifact);
  return { artifact, manifest: buildManifest({ environment: ledger.environment, ledger, type: 'available', revision,
    publishedAt: time, origin: ledger.environment === 'production' ? productionOrigin : 'https://staging.example.test',
    version: '1.0.2', versionCode: code, minimumSupportedVersionCode: 1, sha256: metadata.sha256,
    sizeBytes: metadata.sizeBytes, releaseNotes: 'Release notes.', requiredUpdateReason: 'Update now.' }) };
}

test('legacy state is preserved outside the ledger and production starts at strict disabled revision 1', () => {
  assert.deepEqual(LEGACY_DISABLED_MANIFEST, { status: 'unavailable', updatesEnabled: false, message: 'No Android release has been published.', publishedAt: null });
  const manifest = buildManifest({ environment: 'production', ledger: emptyLedger('production'), type: 'disabled', revision: 1,
    publishedAt: time, origin: productionOrigin, reason: 'Updates are temporarily unavailable.' });
  assert.deepEqual(Object.keys(manifest), ['schemaVersion', 'updatesEnabled', 'manifestRevision', 'publishedAt', 'reason']);
  assert.throws(() => buildManifest({ environment: 'production', ledger: emptyLedger('production'), type: 'available', revision: 2,
    publishedAt: time, origin: productionOrigin, version: '1.0.2', versionCode: 2, minimumSupportedVersionCode: 1,
    sha256: 'a'.repeat(64), sizeBytes: 1, releaseNotes: 'x', requiredUpdateReason: 'y' }), /previously published strict disabled/);
});

test('reservations reject code 1, reuse, and lower codes', () => {
  const ledger = emptyLedger('staging');
  assert.throws(() => reserveVersionCode(ledger, 1), /permanently reserved/);
  const reserved = reserveVersionCode(ledger, 2);
  assert.throws(() => reserveVersionCode(reserved, 2), /already been reserved/);
  const published = applyPublishedManifest(reserved, buildManifest({ environment: 'staging', ledger: reserved, type: 'disabled', revision: 1, publishedAt: time, origin: 'https://staging.example.test', reason: 'Hold.' }));
  assert.throws(() => reserveVersionCode(published, 1), /permanently reserved/);
});

test('canonical identity is ordered JSON without delimiter collisions and revisions cannot mutate', () => {
  const ledger = emptyLedger('staging');
  const first = buildManifest({ environment: 'staging', ledger, type: 'disabled', revision: 1, publishedAt: time, origin: 'https://staging.example.test', reason: 'a|b' });
  const second = { ...first, reason: 'a', publishedAt: '2026-07-30T12:00:01Z' };
  assert.notEqual(canonicalManifestIdentity(first), canonicalManifestIdentity(second));
  const applied = applyPublishedManifest(ledger, first);
  assert.throws(() => applyPublishedManifest(applied, second), /same or lower manifest revision/);
});

test('dry-run makes zero ledger or fixture mutations', async () => {
  const root = await fixture();
  const ledgerPath = path.join(root, 'ledger.json');
  const initial = applyPublishedManifest(emptyLedger('staging'), buildManifest({ environment: 'staging', ledger: emptyLedger('staging'), type: 'disabled', revision: 1, publishedAt: time, origin: 'https://staging.example.test', reason: 'Hold.' }));
  const reserved = reserveVersionCode(initial, 2);
  const { artifact, manifest } = await availableManifest(reserved, root);
  await fs.writeFile(ledgerPath, JSON.stringify(reserved));
  const before = await fs.readFile(ledgerPath, 'utf8');
  const result = await publishToLocalFixture({ target: new LocalReleaseTarget(path.join(root, 'remote')), ledgerPath, ledger: reserved, manifest, artifactPath: artifact, dryRun: true });
  assert.equal(result.wrote, false);
  assert.equal(await fs.readFile(ledgerPath, 'utf8'), before);
  await assert.rejects(fs.stat(path.join(root, 'remote', 'manifest.json')), /ENOENT/);
});

test('no-clobber uploads before an atomic manifest replacement and emits a receipt', async () => {
  const root = await fixture();
  const ledgerPath = path.join(root, 'ledger.json');
  const base = applyPublishedManifest(emptyLedger('staging'), buildManifest({ environment: 'staging', ledger: emptyLedger('staging'), type: 'disabled', revision: 1, publishedAt: time, origin: 'https://staging.example.test', reason: 'Hold.' }));
  const ledger = reserveVersionCode(base, 2);
  const { artifact, manifest } = await availableManifest(ledger, root);
  const remote = path.join(root, 'remote');
  const receiptPath = path.join(root, 'receipt.json');
  const outcome = await publishToLocalFixture({ target: new LocalReleaseTarget(remote), ledgerPath, ledger, manifest, artifactPath: artifact, receiptPath });
  assert.equal(outcome.receipt.artifactName, 'damsure-2.apk');
  assert.deepEqual(JSON.parse(await fs.readFile(path.join(remote, 'manifest.json'), 'utf8')), manifest);
  await assert.rejects(new LocalReleaseTarget(remote).uploadArtifactNoClobber(artifact, 'damsure-2.apk'), /refusing to overwrite/);
  assert.equal(JSON.parse(await fs.readFile(receiptPath, 'utf8')).dryRun, false);
});

test('failed atomic replacement preserves the existing manifest and leaves ledger untouched', async () => {
  const root = await fixture();
  const ledgerPath = path.join(root, 'ledger.json');
  const oldManifest = { old: true };
  const remote = path.join(root, 'remote');
  await fs.mkdir(remote);
  await fs.writeFile(path.join(remote, 'manifest.json'), JSON.stringify(oldManifest));
  const base = applyPublishedManifest(emptyLedger('staging'), buildManifest({ environment: 'staging', ledger: emptyLedger('staging'), type: 'disabled', revision: 1, publishedAt: time, origin: 'https://staging.example.test', reason: 'Hold.' }));
  const ledger = reserveVersionCode(base, 2);
  await fs.writeFile(ledgerPath, JSON.stringify(ledger));
  const beforeLedger = await fs.readFile(ledgerPath, 'utf8');
  const { artifact, manifest } = await availableManifest(ledger, root);
  const target = new LocalReleaseTarget(remote, { ...fs, rename: async () => { throw new Error('injected rename failure'); } });
  await assert.rejects(publishToLocalFixture({ target, ledgerPath, ledger, manifest, artifactPath: artifact }), /injected rename failure/);
  assert.deepEqual(JSON.parse(await fs.readFile(path.join(remote, 'manifest.json'), 'utf8')), oldManifest);
  assert.equal(await fs.readFile(ledgerPath, 'utf8'), beforeLedger);
});

test('production is hard-disabled without named approval and all gate receipts', async () => {
  const root = await fixture();
  const ledger = emptyLedger('production');
  const manifest = buildManifest({ environment: 'production', ledger, type: 'disabled', revision: 1, publishedAt: time, origin: productionOrigin, reason: 'Hold.' });
  await assert.rejects(publishToLocalFixture({ target: new LocalReleaseTarget(path.join(root, 'remote')), ledgerPath: path.join(root, 'ledger.json'), ledger, manifest }), /hard-disabled without approval/);
});

test('APK verification checks size, hash, package, version, and certificate without exposing secrets', async () => {
  const root = await fixture();
  const artifact = path.join(root, 'candidate.apk');
  const aapt = path.join(root, 'fake-aapt');
  const apksigner = path.join(root, 'fake-apksigner');
  await fs.writeFile(artifact, 'APK fixture bytes');
  await fs.writeFile(aapt, "#!/usr/bin/env node\nconsole.log(\"package: name='com.dryspotuppala' versionCode='2' versionName='1.0.2'\")\n");
  await fs.writeFile(apksigner, "#!/usr/bin/env node\nconsole.log('Signer #1 certificate SHA-256 digest: AA:BB:CC')\n");
  await fs.chmod(aapt, 0o755);
  await fs.chmod(apksigner, 0o755);
  const metadata = await basicArtifactMetadata(artifact);
  const verified = await verifyApkArtifact({ artifactPath: artifact, expectedSha256: metadata.sha256,
    expectedSizeBytes: metadata.sizeBytes, expectedPackageId: 'com.dryspotuppala', expectedVersionCode: 2,
    expectedCertificateSha256: 'aa:bb:cc', aapt, apksigner });
  assert.deepEqual(verified, { ...metadata, packageId: 'com.dryspotuppala', versionCode: 2,
    versionName: '1.0.2', certificateSha256: 'AABBCC' });
  await assert.rejects(verifyApkArtifact({ artifactPath: artifact, expectedPackageId: 'wrong.package',
    expectedVersionCode: 2, expectedCertificateSha256: 'aa:bb:cc', aapt, apksigner }), /package ID/);
});
