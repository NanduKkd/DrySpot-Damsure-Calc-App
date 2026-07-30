'use strict';

const crypto = require('node:crypto');
const { constants: fsConstants } = require('node:fs');
const fs = require('node:fs/promises');
const path = require('node:path');
const { execFile } = require('node:child_process');
const { promisify } = require('node:util');

const execFileAsync = promisify(execFile);
const MAX_INT_32 = 2147483647;
const PRODUCTION_ORIGIN = 'https://damsure.nandakrishnan.in';
const LEGACY_DISABLED_MANIFEST = Object.freeze({
  status: 'unavailable',
  updatesEnabled: false,
  message: 'No Android release has been published.',
  publishedAt: null,
});

function fail(message) {
  throw new Error(message);
}

function isPositiveInt(value) {
  return Number.isInteger(value) && value > 0 && value <= MAX_INT_32;
}

function requirePositiveInt(value, field) {
  if (!isPositiveInt(value)) fail(`${field} must be a positive signed 32-bit integer`);
  return value;
}

function canonicalUtc(value) {
  const date = value instanceof Date ? value : new Date(value);
  if (Number.isNaN(date.valueOf()) || date.getMilliseconds() !== 0) {
    fail('publishedAt must be an exact UTC whole-second timestamp');
  }
  return date.toISOString().replace('.000Z', 'Z');
}

function normalizeOrigin(origin, environment) {
  if (typeof origin !== 'string' || origin.length === 0) fail('release origin is required');
  let parsed;
  try { parsed = new URL(origin); } catch { fail('release origin must be an HTTPS origin'); }
  if (parsed.protocol !== 'https:' || parsed.username || parsed.password || parsed.port ||
      parsed.pathname !== '/' || parsed.search || parsed.hash) {
    fail('release origin must be an HTTPS origin without path, port, credentials, query, or fragment');
  }
  const normalized = parsed.origin;
  if (environment === 'production' && normalized !== PRODUCTION_ORIGIN) {
    fail(`production origin must be ${PRODUCTION_ORIGIN}`);
  }
  if (environment === 'staging' && normalized === PRODUCTION_ORIGIN) {
    fail('staging origin must differ from the production origin');
  }
  return normalized;
}

function emptyLedger(environment) {
  return {
    schemaVersion: 1,
    environment,
    lastManifestRevision: 0,
    maxLatestVersionCode: 1,
    strictV1Started: false,
    reservedVersionCodes: [1],
    artifacts: {},
    manifests: {},
  };
}

function validateLedger(ledger, environment) {
  if (!ledger || ledger.schemaVersion !== 1 || ledger.environment !== environment ||
      !Number.isInteger(ledger.lastManifestRevision) || ledger.lastManifestRevision < 0 ||
      !isPositiveInt(ledger.maxLatestVersionCode) || !Array.isArray(ledger.reservedVersionCodes) ||
      !ledger.reservedVersionCodes.includes(1) || !ledger.artifacts || !ledger.manifests) {
    fail(`invalid ${environment} publication ledger`);
  }
  for (const code of ledger.reservedVersionCodes) requirePositiveInt(code, 'reserved version code');
  return ledger;
}

async function readLedger(ledgerPath, environment) {
  try {
    return validateLedger(JSON.parse(await fs.readFile(ledgerPath, 'utf8')), environment);
  } catch (error) {
    if (error && error.code === 'ENOENT') return emptyLedger(environment);
    throw error;
  }
}

async function atomicWriteJson(filePath, value, fsOps = fs) {
  await fsOps.mkdir(path.dirname(filePath), { recursive: true });
  const temporary = path.join(path.dirname(filePath), `.${path.basename(filePath)}.${process.pid}.${crypto.randomUUID()}.tmp`);
  try {
    await fsOps.writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600, flag: 'wx' });
    await fsOps.rename(temporary, filePath);
  } finally {
    await fsOps.rm(temporary, { force: true }).catch(() => {});
  }
}

function reserveVersionCode(ledger, code) {
  validateLedger(ledger, ledger.environment);
  requirePositiveInt(code, 'version code');
  if (code === 1) fail('version code 1 is permanently reserved');
  if (code <= ledger.maxLatestVersionCode || ledger.reservedVersionCodes.includes(code)) {
    fail(`version code ${code} has already been reserved or published`);
  }
  return { ...ledger, reservedVersionCodes: [...ledger.reservedVersionCodes, code].sort((a, b) => a - b) };
}

function canonicalManifestIdentity(manifest) {
  const ordered = manifest.updatesEnabled
    ? {
        schemaVersion: manifest.schemaVersion,
        updatesEnabled: manifest.updatesEnabled,
        manifestRevision: manifest.manifestRevision,
        latestVersion: manifest.latestVersion,
        latestVersionCode: manifest.latestVersionCode,
        minimumSupportedVersionCode: manifest.minimumSupportedVersionCode,
        artifactUrl: manifest.artifactUrl,
        sha256: manifest.sha256,
        sizeBytes: manifest.sizeBytes,
        publishedAt: manifest.publishedAt,
        releaseNotes: manifest.releaseNotes,
        requiredUpdateReason: manifest.requiredUpdateReason,
      }
    : {
        schemaVersion: manifest.schemaVersion,
        updatesEnabled: manifest.updatesEnabled,
        manifestRevision: manifest.manifestRevision,
        publishedAt: manifest.publishedAt,
        reason: manifest.reason,
      };
  return JSON.stringify(ordered);
}

function buildManifest({ environment, ledger, type, revision, publishedAt, origin, version, versionCode,
  minimumSupportedVersionCode, sha256, sizeBytes, releaseNotes, requiredUpdateReason, reason }) {
  validateLedger(ledger, environment);
  if (!['available', 'disabled'].includes(type)) fail('manifest type must be available or disabled');
  const normalizedOrigin = normalizeOrigin(origin, environment);
  requirePositiveInt(revision, 'manifest revision');
  if (revision <= ledger.lastManifestRevision || ledger.manifests[String(revision)]) {
    fail(`manifest revision ${revision} is not newer than the environment ledger`);
  }
  const canonicalPublishedAt = canonicalUtc(publishedAt);
  let manifest;
  if (type === 'disabled') {
    if (typeof reason !== 'string' || reason.trim() !== reason || reason.length === 0 || reason.length > 500) {
      fail('disabled reason must be a non-empty trimmed string of at most 500 characters');
    }
    manifest = { schemaVersion: 1, updatesEnabled: false, manifestRevision: revision, publishedAt: canonicalPublishedAt, reason };
  } else {
    if (environment === 'production' && (!ledger.strictV1Started || revision < 2)) {
      fail('production available manifests require a previously published strict disabled v1 revision and revision >= 2');
    }
    requirePositiveInt(versionCode, 'latest version code');
    requirePositiveInt(minimumSupportedVersionCode, 'minimum supported version code');
    requirePositiveInt(sizeBytes, 'size bytes');
    if (versionCode === 1 || versionCode <= ledger.maxLatestVersionCode || !ledger.reservedVersionCodes.includes(versionCode)) {
      fail('available manifest version code must be a newly reserved code greater than the ledger maximum and never 1');
    }
    if (minimumSupportedVersionCode > versionCode) fail('minimum supported version code cannot exceed latest version code');
    if (typeof version !== 'string' || !/^\d+\.\d+\.\d+$/.test(version)) fail('latest version must be X.Y.Z');
    if (typeof sha256 !== 'string' || !/^[a-f0-9]{64}$/.test(sha256)) fail('sha256 must be 64 lowercase hexadecimal characters');
    for (const [field, value, maximum] of [['release notes', releaseNotes, 4000], ['required update reason', requiredUpdateReason, 500]]) {
      if (typeof value !== 'string' || value.trim() !== value || value.length === 0 || value.length > maximum) {
        fail(`${field} must be a non-empty trimmed string of at most ${maximum} characters`);
      }
    }
    manifest = {
      schemaVersion: 1, updatesEnabled: true, manifestRevision: revision,
      latestVersion: version, latestVersionCode: versionCode,
      minimumSupportedVersionCode, artifactUrl: `${normalizedOrigin}/releases/damsure-${versionCode}.apk`,
      sha256, sizeBytes, publishedAt: canonicalPublishedAt, releaseNotes, requiredUpdateReason,
    };
  }
  return Object.freeze(manifest);
}

function applyPublishedManifest(ledger, manifest) {
  validateLedger(ledger, ledger.environment);
  const revision = manifest.manifestRevision;
  const identity = canonicalManifestIdentity(manifest);
  if (revision <= ledger.lastManifestRevision || ledger.manifests[String(revision)]) {
    fail(`same or lower manifest revision ${revision} cannot be published`);
  }
  if (manifest.updatesEnabled && manifest.latestVersionCode <= ledger.maxLatestVersionCode) {
    fail('available manifest cannot lower or reuse a published latest version code');
  }
  const artifactName = manifest.updatesEnabled ? `damsure-${manifest.latestVersionCode}.apk` : null;
  if (artifactName && ledger.artifacts[artifactName]) fail(`immutable artifact name ${artifactName} is already recorded`);
  return {
    ...ledger,
    lastManifestRevision: revision,
    maxLatestVersionCode: manifest.updatesEnabled ? manifest.latestVersionCode : ledger.maxLatestVersionCode,
    strictV1Started: true,
    artifacts: artifactName ? { ...ledger.artifacts, [artifactName]: { sha256: manifest.sha256, sizeBytes: manifest.sizeBytes } } : ledger.artifacts,
    manifests: { ...ledger.manifests, [String(revision)]: { canonicalIdentity: identity, identitySha256: crypto.createHash('sha256').update(identity).digest('hex') } },
  };
}

async function sha256File(filePath) {
  const body = await fs.readFile(filePath);
  return crypto.createHash('sha256').update(body).digest('hex');
}

async function basicArtifactMetadata(filePath) {
  const stat = await fs.stat(filePath);
  if (!stat.isFile() || stat.size <= 0) fail('artifact must be a non-empty regular file');
  return { sizeBytes: stat.size, sha256: await sha256File(filePath) };
}

function normalizedCertificate(value) {
  return value.replace(/[^A-Fa-f0-9]/g, '').toUpperCase();
}

async function verifyApkArtifact({ artifactPath, expectedSha256, expectedSizeBytes, expectedPackageId,
  expectedVersionCode, expectedCertificateSha256, aapt = 'aapt', apksigner = 'apksigner' }) {
  const basic = await basicArtifactMetadata(artifactPath);
  if (expectedSha256 && basic.sha256 !== expectedSha256) fail('artifact SHA-256 does not match expected value');
  if (expectedSizeBytes && basic.sizeBytes !== expectedSizeBytes) fail('artifact size does not match expected value');
  const { stdout: badging } = await execFileAsync(aapt, ['dump', 'badging', artifactPath], { maxBuffer: 1024 * 1024 });
  const packageMatch = /^package: name='([^']+)' versionCode='([^']+)' versionName='([^']+)'/m.exec(badging);
  if (!packageMatch) fail('could not read APK package metadata');
  const [, packageId, versionCode, versionName] = packageMatch;
  if (expectedPackageId && packageId !== expectedPackageId) fail('APK package ID does not match expected value');
  if (expectedVersionCode && Number(versionCode) !== Number(expectedVersionCode)) fail('APK version code does not match expected value');
  const { stdout: signerOutput } = await execFileAsync(apksigner, ['verify', '--verbose', '--print-certs', artifactPath], { maxBuffer: 1024 * 1024 });
  const certificateMatch = /certificate SHA-256 digest:\s*([A-Fa-f0-9:]+)/.exec(signerOutput);
  if (!certificateMatch) fail('could not read APK signing certificate digest');
  if (expectedCertificateSha256 && normalizedCertificate(certificateMatch[1]) !== normalizedCertificate(expectedCertificateSha256)) {
    fail('APK signing certificate does not match expected value');
  }
  return { ...basic, packageId, versionCode: Number(versionCode), versionName, certificateSha256: normalizedCertificate(certificateMatch[1]) };
}

class LocalReleaseTarget {
  constructor(root, fsOps = fs) {
    this.root = path.resolve(root);
    this.fs = fsOps;
  }

  artifactPath(name) { return path.join(this.root, name); }
  manifestPath() { return path.join(this.root, 'manifest.json'); }

  async uploadArtifactNoClobber(sourcePath, name) {
    if (!/^damsure-[1-9]\d*\.apk$/.test(name)) fail('artifact name must be immutable damsure-<versionCode>.apk');
    await this.fs.mkdir(this.root, { recursive: true });
    const destination = this.artifactPath(name);
    const source = await this.fs.readFile(sourcePath);
    try { await this.fs.writeFile(destination, source, { flag: 'wx', mode: 0o644 }); }
    catch (error) { if (error.code === 'EEXIST') fail(`refusing to overwrite immutable artifact ${name}`); throw error; }
    return destination;
  }

  async downloadArtifact(name, destination) {
    await this.fs.copyFile(this.artifactPath(name), destination, fsConstants.COPYFILE_EXCL);
    return destination;
  }

  async replaceManifestAtomically(manifest) {
    await atomicWriteJson(this.manifestPath(), manifest, this.fs);
  }
}

class SshReleaseTarget {
  constructor({ host, root }) { this.host = host; this.root = root; }
  uploadCommand(localArtifact, immutableName) {
    return `scp -- ${shellQuote(localArtifact)} ${shellQuote(`${this.host}:${this.root}/.${immutableName}.upload`)} && ssh -- ${shellQuote(this.host)} ${shellQuote(`set -eu; test ! -e ${shellQuote(`${this.root}/${immutableName}`)}; mv -n -- ${shellQuote(`${this.root}/.${immutableName}.upload`)} ${shellQuote(`${this.root}/${immutableName}`)}; test -f ${shellQuote(`${this.root}/${immutableName}`)}`)}`;
  }
  replaceManifestCommand(localManifest) {
    return `scp -- ${shellQuote(localManifest)} ${shellQuote(`${this.host}:${this.root}/.manifest.json.upload`)} && ssh -- ${shellQuote(this.host)} ${shellQuote(`set -eu; mv -f -- ${shellQuote(`${this.root}/.manifest.json.upload`)} ${shellQuote(`${this.root}/manifest.json`)}`)}`;
  }
}

function shellQuote(value) { return `'${String(value).replace(/'/g, "'\\\"'\\\"'")}'`; }

function gateProduction(options) {
  if (options.environment !== 'production') return;
  for (const field of ['approval', 'signingBackupReceipt', 'pilotReceipt', 'dependencyReceipt']) {
    if (!options[field]) fail(`production publication is hard-disabled without ${field}`);
  }
}

async function publishToLocalFixture({ target, ledgerPath, ledger, manifest, artifactPath, dryRun = false,
  approval, signingBackupReceipt, pilotReceipt, dependencyReceipt, receiptPath, now = new Date() }) {
  gateProduction({ environment: ledger.environment, approval, signingBackupReceipt, pilotReceipt, dependencyReceipt });
  const nextLedger = applyPublishedManifest(ledger, manifest);
  const artifactName = manifest.updatesEnabled ? `damsure-${manifest.latestVersionCode}.apk` : null;
  const receipt = {
    schemaVersion: 1, environment: ledger.environment, action: manifest.updatesEnabled ? 'publish-available' : 'publish-disabled',
    manifestRevision: manifest.manifestRevision, manifestCanonicalIdentity: canonicalManifestIdentity(manifest),
    artifactName, artifactSha256: manifest.updatesEnabled ? manifest.sha256 : null,
    createdAt: canonicalUtc(new Date(Math.floor(now.valueOf() / 1000) * 1000)), dryRun,
  };
  if (dryRun) return { receipt, nextLedger, wrote: false };
  if (manifest.updatesEnabled) {
    if (!artifactPath) fail('available publication requires an artifact path');
    const local = await basicArtifactMetadata(artifactPath);
    if (local.sha256 !== manifest.sha256 || local.sizeBytes !== manifest.sizeBytes) fail('artifact does not match manifest metadata');
    await target.uploadArtifactNoClobber(artifactPath, artifactName);
    const downloaded = path.join(path.dirname(artifactPath), `.${artifactName}.${crypto.randomUUID()}.download`);
    try {
      await target.downloadArtifact(artifactName, downloaded);
      const verifiedDownload = await basicArtifactMetadata(downloaded);
      if (verifiedDownload.sha256 !== manifest.sha256 || verifiedDownload.sizeBytes !== manifest.sizeBytes) {
        fail('independently downloaded artifact does not match manifest metadata');
      }
    } finally { await fs.rm(downloaded, { force: true }); }
  }
  await target.replaceManifestAtomically(manifest);
  await atomicWriteJson(ledgerPath, nextLedger);
  if (receiptPath) await atomicWriteJson(receiptPath, receipt);
  return { receipt, nextLedger, wrote: true };
}

module.exports = {
  LEGACY_DISABLED_MANIFEST, PRODUCTION_ORIGIN, emptyLedger, readLedger, atomicWriteJson, reserveVersionCode,
  buildManifest, canonicalManifestIdentity, applyPublishedManifest, basicArtifactMetadata, verifyApkArtifact,
  LocalReleaseTarget, SshReleaseTarget, publishToLocalFixture, canonicalUtc,
};
