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
const PACKAGE_IDS = Object.freeze({ production: 'com.dryspotuppala', staging: 'com.dryspotuppala.staging' });
const LEGACY_DISABLED_MANIFEST = Object.freeze({ status: 'unavailable', updatesEnabled: false, message: 'No Android release has been published.', publishedAt: null });

function fail(message) { throw new Error(message); }
function isPositiveInt(value) { return Number.isInteger(value) && value > 0 && value <= MAX_INT_32; }
function requirePositiveInt(value, field) { if (!isPositiveInt(value)) fail(`${field} must be a positive signed 32-bit integer`); return value; }
function canonicalUtc(value) {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(value)) fail('time must be canonical UTC RFC3339 at whole-second precision');
  const date = new Date(value);
  if (Number.isNaN(date.valueOf()) || date.toISOString().replace('.000Z', 'Z') !== value) fail('time must be canonical UTC RFC3339 at whole-second precision');
  return value;
}
function normalizeOrigin(origin, environment) {
  if (!['production', 'staging'].includes(environment)) fail('environment must be production or staging');
  let parsed; try { parsed = new URL(origin); } catch { fail('release origin must be an HTTPS origin'); }
  if (parsed.protocol !== 'https:' || parsed.username || parsed.password || parsed.port || parsed.pathname !== '/' || parsed.search || parsed.hash) fail('release origin must be an HTTPS origin without path, port, credentials, query, or fragment');
  const normalized = parsed.origin;
  if (environment === 'production' && normalized !== PRODUCTION_ORIGIN) fail(`production origin must be ${PRODUCTION_ORIGIN}`);
  if (environment === 'staging' && normalized === PRODUCTION_ORIGIN) fail('staging origin must differ from the production origin');
  return normalized;
}

async function assertNoSymlinkPath(candidate, { allowMissingFinal = false } = {}) {
  const requested = path.resolve(candidate);
  const requestedStat = await fs.lstat(requested).catch((error) => {
    if (error.code === 'ENOENT' && allowMissingFinal) return false;
    throw error;
  });
  if (requestedStat && requestedStat.isSymbolicLink()) fail(`symlink path target is refused: ${requested}`);
  const exists = Boolean(requestedStat);
  const absolute = exists ? await fs.realpath(requested) : path.join(await fs.realpath(path.dirname(requested)), path.basename(requested));
  const parts = absolute.split(path.sep).filter(Boolean);
  let current = path.parse(absolute).root;
  for (let index = 0; index < parts.length; index += 1) {
    current = path.join(current, parts[index]);
    try {
      const stat = await fs.lstat(current);
      if (stat.isSymbolicLink()) fail(`symlink path component is refused: ${current}`);
    } catch (error) {
      if (error.code === 'ENOENT' && allowMissingFinal && index === parts.length - 1) continue;
      if (error.code === 'ENOENT') fail(`path component does not exist: ${current}`);
      throw error;
    }
  }
  return absolute;
}
async function secureLedgerAndRoot(ledgerPath, root) {
  const canonicalLedger = await assertNoSymlinkPath(ledgerPath, { allowMissingFinal: true });
  const canonicalRoot = await assertNoSymlinkPath(root, { allowMissingFinal: true });
  if (canonicalLedger === canonicalRoot || canonicalLedger.startsWith(`${canonicalRoot}${path.sep}`) || canonicalRoot.startsWith(`${canonicalLedger}${path.sep}`)) fail('ledger and release root must be separate paths');
  return { ledgerPath: canonicalLedger, root: canonicalRoot };
}

function emptyLedger(environment, root, origin) {
  return { schemaVersion: 2, environment, releaseRoot: root, releaseOrigin: origin, lastManifestRevision: 0, maxLatestVersionCode: 1, strictV1Started: false, reservedVersionCodes: [1], artifacts: {}, manifests: {}, pendingPublication: null, receiptState: null };
}
function validateLedger(ledger, environment, root, origin) {
  if (!ledger || ledger.schemaVersion !== 2 || ledger.environment !== environment || ledger.releaseRoot !== root || ledger.releaseOrigin !== origin || !Number.isInteger(ledger.lastManifestRevision) || ledger.lastManifestRevision < 0 || !isPositiveInt(ledger.maxLatestVersionCode) || !Array.isArray(ledger.reservedVersionCodes) || !ledger.reservedVersionCodes.includes(1) || typeof ledger.artifacts !== 'object' || typeof ledger.manifests !== 'object') fail(`invalid or environment-confused ${environment} publication ledger`);
  for (const code of ledger.reservedVersionCodes) requirePositiveInt(code, 'reserved version code');
  if (ledger.pendingPublication && (!isPositiveInt(ledger.pendingPublication.manifestRevision) || typeof ledger.pendingPublication.canonicalIdentity !== 'string')) fail('invalid pending publication journal');
  return ledger;
}
async function readLedger(ledgerPath, environment, root, origin) {
  try { return validateLedger(JSON.parse(await fs.readFile(ledgerPath, 'utf8')), environment, root, origin); }
  catch (error) { if (error.code === 'ENOENT') return emptyLedger(environment, root, origin); throw error; }
}
async function atomicWriteJson(filePath, value, fsOps = fs) {
  await fsOps.mkdir(path.dirname(filePath), { recursive: true, mode: 0o700 });
  const temporary = path.join(path.dirname(filePath), `.${path.basename(filePath)}.${process.pid}.${crypto.randomUUID()}.tmp`);
  try {
    await fsOps.writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600, flag: 'wx' });
    await fsOps.rename(temporary, filePath);
  } finally { await fsOps.rm(temporary, { force: true }).catch(() => {}); }
}
async function withLedgerLock(ledgerPath, callback, { staleLockMs = 5 * 60 * 1000, breakStaleLock = false, waitLockMs = 5000 } = {}, deadline = Date.now() + waitLockMs) {
  const lock = `${ledgerPath}.lock`;
  try { await fs.mkdir(lock, { mode: 0o700 }); }
  catch (error) {
    if (error.code !== 'EEXIST') throw error;
    const stat = await fs.stat(lock).catch(() => null);
    if (!stat) return withLedgerLock(ledgerPath, callback, { staleLockMs, breakStaleLock, waitLockMs }, deadline);
    if (Date.now() - stat.mtimeMs <= staleLockMs) {
      if (Date.now() >= deadline) fail(`ledger lock is held: ${lock}`);
      await new Promise((resolve) => setTimeout(resolve, 25));
      return withLedgerLock(ledgerPath, callback, { staleLockMs, breakStaleLock, waitLockMs }, deadline);
    }
    if (!breakStaleLock) fail(`stale ledger lock requires explicit break: ${lock}`);
    await fs.rename(lock, `${lock}.stale.${Date.now()}.${crypto.randomUUID()}`);
    return withLedgerLock(ledgerPath, callback, { staleLockMs, breakStaleLock: false, waitLockMs }, deadline);
  }
  const owner = { pid: process.pid, acquiredAt: new Date().toISOString(), nonce: crypto.randomUUID() };
  try { await fs.writeFile(path.join(lock, 'owner.json'), `${JSON.stringify(owner)}\n`, { mode: 0o600, flag: 'wx' }); return await callback(owner); }
  finally { await fs.rm(lock, { recursive: true, force: true }); }
}

function reserveVersionCode(ledger, code) {
  requirePositiveInt(code, 'version code');
  if (code === 1) fail('version code 1 is permanently reserved');
  if (code <= ledger.maxLatestVersionCode || ledger.reservedVersionCodes.includes(code)) fail(`version code ${code} has already been reserved or published`);
  return { ...ledger, reservedVersionCodes: [...ledger.reservedVersionCodes, code].sort((a, b) => a - b) };
}
async function reserveVersionCodeAtPath({ ledgerPath, environment, root, origin, code, dryRun = false, lockOptions }) {
  const secure = await secureLedgerAndRoot(ledgerPath, root); const normalizedOrigin = normalizeOrigin(origin, environment);
  return withLedgerLock(secure.ledgerPath, async () => {
    const ledger = await readLedger(secure.ledgerPath, environment, secure.root, normalizedOrigin);
    const next = reserveVersionCode(ledger, code);
    if (!dryRun) await atomicWriteJson(secure.ledgerPath, next);
    return next;
  }, lockOptions);
}

function canonicalManifestIdentity(manifest) {
  const ordered = manifest.updatesEnabled ? { schemaVersion: manifest.schemaVersion, updatesEnabled: true, manifestRevision: manifest.manifestRevision, latestVersion: manifest.latestVersion, latestVersionCode: manifest.latestVersionCode, minimumSupportedVersionCode: manifest.minimumSupportedVersionCode, artifactUrl: manifest.artifactUrl, sha256: manifest.sha256, sizeBytes: manifest.sizeBytes, publishedAt: manifest.publishedAt, releaseNotes: manifest.releaseNotes, requiredUpdateReason: manifest.requiredUpdateReason } : { schemaVersion: manifest.schemaVersion, updatesEnabled: false, manifestRevision: manifest.manifestRevision, publishedAt: manifest.publishedAt, reason: manifest.reason };
  return JSON.stringify(ordered);
}
function buildManifest({ environment, ledger, type, revision, publishedAt, origin, version, versionCode, minimumSupportedVersionCode, sha256, sizeBytes, releaseNotes, requiredUpdateReason, reason }) {
  validateLedger(ledger, environment, ledger.releaseRoot, normalizeOrigin(origin, environment));
  if (!['available', 'disabled'].includes(type)) fail('manifest type must be available or disabled');
  requirePositiveInt(revision, 'manifest revision');
  if (revision <= ledger.lastManifestRevision || ledger.manifests[String(revision)] || ledger.pendingPublication?.manifestRevision === revision) fail(`manifest revision ${revision} is already committed or reserved`);
  const time = canonicalUtc(publishedAt);
  if (type === 'disabled') {
    if (typeof reason !== 'string' || reason.trim() !== reason || reason.length === 0 || reason.length > 500) fail('disabled reason must be a non-empty trimmed string of at most 500 characters');
    return Object.freeze({ schemaVersion: 1, updatesEnabled: false, manifestRevision: revision, publishedAt: time, reason });
  }
  if (environment === 'production' && (!ledger.strictV1Started || revision < 2)) fail('production available manifests require a previously published strict disabled v1 revision and revision >= 2');
  requirePositiveInt(versionCode, 'latest version code'); requirePositiveInt(minimumSupportedVersionCode, 'minimum supported version code'); requirePositiveInt(sizeBytes, 'size bytes');
  if (typeof version !== 'string' || !/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(version)) fail('latest version must be canonical X.Y.Z without leading zero components');
  if (versionCode === 1 || versionCode <= ledger.maxLatestVersionCode || !ledger.reservedVersionCodes.includes(versionCode)) fail('available manifest version code must be a newly reserved code greater than the ledger maximum and never 1');
  if (minimumSupportedVersionCode > versionCode) fail('minimum supported version code cannot exceed latest version code');
  if (typeof sha256 !== 'string' || !/^[a-f0-9]{64}$/.test(sha256)) fail('sha256 must be 64 lowercase hexadecimal characters');
  for (const [field, value, maximum] of [['release notes', releaseNotes, 4000], ['required update reason', requiredUpdateReason, 500]]) if (typeof value !== 'string' || value.trim() !== value || value.length === 0 || value.length > maximum) fail(`${field} must be a non-empty trimmed string of at most ${maximum} characters`);
  return Object.freeze({ schemaVersion: 1, updatesEnabled: true, manifestRevision: revision, latestVersion: version, latestVersionCode: versionCode, minimumSupportedVersionCode, artifactUrl: `${ledger.releaseOrigin}/releases/damsure-${versionCode}.apk`, sha256, sizeBytes, publishedAt: time, releaseNotes, requiredUpdateReason });
}
function applyPublishedManifest(ledger, manifest) {
  const revision = manifest.manifestRevision; const identity = canonicalManifestIdentity(manifest);
  if (revision <= ledger.lastManifestRevision || ledger.manifests[String(revision)]) fail(`same or lower manifest revision ${revision} cannot be published`);
  if (ledger.pendingPublication && ledger.pendingPublication.manifestRevision !== revision) fail('another publication journal is pending recovery');
  if (manifest.updatesEnabled && manifest.latestVersionCode <= ledger.maxLatestVersionCode) fail('available manifest cannot lower or reuse a published latest version code');
  const artifactName = manifest.updatesEnabled ? `damsure-${manifest.latestVersionCode}.apk` : null;
  if (artifactName && ledger.artifacts[artifactName]) fail(`immutable artifact name ${artifactName} is already recorded`);
  return { ...ledger, lastManifestRevision: revision, maxLatestVersionCode: manifest.updatesEnabled ? manifest.latestVersionCode : ledger.maxLatestVersionCode, strictV1Started: true, artifacts: artifactName ? { ...ledger.artifacts, [artifactName]: { sha256: manifest.sha256, sizeBytes: manifest.sizeBytes } } : ledger.artifacts, manifests: { ...ledger.manifests, [String(revision)]: { canonicalIdentity: identity, identitySha256: crypto.createHash('sha256').update(identity).digest('hex') } }, pendingPublication: null };
}

async function sha256File(filePath) { return crypto.createHash('sha256').update(await fs.readFile(filePath)).digest('hex'); }
async function basicArtifactMetadata(filePath, { requireApkZip = false } = {}) {
  const stat = await fs.lstat(filePath); if (!stat.isFile() || stat.isSymbolicLink() || stat.size <= 0) fail('artifact must be a non-empty regular non-symlink file');
  if (requireApkZip) { const handle = await fs.open(filePath, 'r'); try { const header = Buffer.alloc(4); await handle.read(header, 0, 4, 0); if (!header.equals(Buffer.from([0x50, 0x4b, 0x03, 0x04]))) fail('artifact is not an APK ZIP file'); } finally { await handle.close(); } }
  return { sizeBytes: stat.size, sha256: await sha256File(filePath) };
}
function normalizedCertificate(value) { return value.replace(/[^A-Fa-f0-9]/g, '').toUpperCase(); }
async function validateTrustedExecutable(candidate, label) {
  if (!candidate || !path.isAbsolute(candidate)) fail(`${label} must be an explicit absolute trusted tool path`);
  const stat = await fs.lstat(candidate); if (stat.isSymbolicLink() || !stat.isFile() || (stat.mode & 0o111) === 0) fail(`${label} must be a non-symlink regular executable`);
  return candidate;
}
async function verifyApkArtifact({ artifactPath, expectedSha256, expectedSizeBytes, expectedPackageId, expectedVersionCode, expectedVersionName, expectedCertificateSha256, trustedTools }) {
  if (!expectedSha256 || !expectedSizeBytes || !expectedPackageId || !expectedVersionCode || !expectedVersionName || !expectedCertificateSha256) fail('APK verification requires size, SHA-256, package, version code/name, and pinned certificate expectations');
  const aapt = await validateTrustedExecutable(trustedTools?.aapt, 'aapt'); const apksigner = await validateTrustedExecutable(trustedTools?.apksigner, 'apksigner');
  const basic = await basicArtifactMetadata(artifactPath, { requireApkZip: true });
  if (basic.sha256 !== expectedSha256) fail('artifact SHA-256 does not match expected value'); if (basic.sizeBytes !== expectedSizeBytes) fail('artifact size does not match expected value');
  const { stdout: badging } = await execFileAsync(aapt, ['dump', 'badging', artifactPath], { maxBuffer: 1024 * 1024 });
  const packageMatch = /^package: name='([^']+)' versionCode='([^']+)' versionName='([^']+)'/m.exec(badging); if (!packageMatch) fail('could not read APK package metadata');
  const [, packageId, versionCode, versionName] = packageMatch;
  if (packageId !== expectedPackageId) fail('APK package ID does not match expected value'); if (Number(versionCode) !== Number(expectedVersionCode)) fail('APK version code does not match expected value'); if (versionName !== expectedVersionName) fail('APK version name does not match expected value');
  const { stdout: signerOutput } = await execFileAsync(apksigner, ['verify', '--verbose', '--print-certs', artifactPath], { maxBuffer: 1024 * 1024 });
  const certificateMatch = /certificate SHA-256 digest:\s*([A-Fa-f0-9:]+)/.exec(signerOutput); if (!certificateMatch) fail('could not read APK signing certificate digest');
  if (normalizedCertificate(certificateMatch[1]) !== normalizedCertificate(expectedCertificateSha256)) fail('APK signing certificate does not match expected value');
  return { ...basic, packageId, versionCode: Number(versionCode), versionName, certificateSha256: normalizedCertificate(certificateMatch[1]) };
}

class LocalReleaseTarget {
  constructor(root, fsOps = fs) { this.root = path.resolve(root); this.fs = fsOps; }
  artifactPath(name) { return path.join(this.root, name); } manifestPath() { return path.join(this.root, 'manifest.json'); }
  async uploadArtifactNoClobber(sourcePath, name) { if (!/^damsure-[1-9]\d*\.apk$/.test(name)) fail('artifact name must be immutable damsure-<versionCode>.apk'); await this.fs.mkdir(this.root, { recursive: true, mode: 0o700 }); try { await this.fs.copyFile(sourcePath, this.artifactPath(name), fsConstants.COPYFILE_EXCL); } catch (error) { if (error.code === 'EEXIST') fail(`refusing to overwrite immutable artifact ${name}`); throw error; } }
  async downloadArtifact(name, destination) { await this.fs.copyFile(this.artifactPath(name), destination, fsConstants.COPYFILE_EXCL); return destination; }
  async replaceManifestAtomically(manifest) { await atomicWriteJson(this.manifestPath(), manifest, this.fs); }
  async readManifest() { return JSON.parse(await this.fs.readFile(this.manifestPath(), 'utf8')); }
}
function gateProduction(options) { if (options.environment === 'production') for (const field of ['approval', 'signingBackupReceipt', 'pilotReceipt', 'dependencyReceipt']) if (!options[field]) fail(`production publication is hard-disabled without ${field}`); }
function receiptFor({ ledger, manifest, status, phase, trustedReceiptAt, dryRun, failure }) { return { schemaVersion: 2, environment: ledger.environment, action: manifest.updatesEnabled ? 'publish-available' : 'publish-disabled', manifestRevision: manifest.manifestRevision, manifestCanonicalIdentity: canonicalManifestIdentity(manifest), artifactName: manifest.updatesEnabled ? `damsure-${manifest.latestVersionCode}.apk` : null, artifactSha256: manifest.updatesEnabled ? manifest.sha256 : null, trustedReceiptAt, dryRun, activation: dryRun ? 'not-attempted' : status, phase, failure: failure ? String(failure.message || failure).replace(/[\r\n]/g, ' ') : null }; }
async function publishToLocalFixture({ target, ledgerPath, environment, root, origin, manifest, artifactPath, trustedTools, certificateSha256, receiptPath, trustedReceiptAt, dryRun = false, lockOptions, hooks = {}, ...gates }) {
  gateProduction({ environment, ...gates }); const secure = await secureLedgerAndRoot(ledgerPath, root); const normalizedOrigin = normalizeOrigin(origin, environment); const receiptTime = canonicalUtc(trustedReceiptAt || manifest.publishedAt);
  if (dryRun) { const ledger = await readLedger(secure.ledgerPath, environment, secure.root, normalizedOrigin); buildManifest({ environment, ledger, type: manifest.updatesEnabled ? 'available' : 'disabled', revision: manifest.manifestRevision, publishedAt: manifest.publishedAt, origin: normalizedOrigin, version: manifest.latestVersion, versionCode: manifest.latestVersionCode, minimumSupportedVersionCode: manifest.minimumSupportedVersionCode, sha256: manifest.sha256, sizeBytes: manifest.sizeBytes, releaseNotes: manifest.releaseNotes, requiredUpdateReason: manifest.requiredUpdateReason, reason: manifest.reason }); return { wrote: false, receipt: receiptFor({ ledger, manifest, status: 'not-attempted', phase: 'dry-run', trustedReceiptAt: receiptTime, dryRun: true }) }; }
  return withLedgerLock(secure.ledgerPath, async () => {
    let ledger = await readLedger(secure.ledgerPath, environment, secure.root, normalizedOrigin); const identity = canonicalManifestIdentity(manifest);
    if (ledger.pendingPublication) fail(`pending publication revision ${ledger.pendingPublication.manifestRevision} requires recover before retry`);
    buildManifest({ environment, ledger, type: manifest.updatesEnabled ? 'available' : 'disabled', revision: manifest.manifestRevision, publishedAt: manifest.publishedAt, origin: normalizedOrigin, version: manifest.latestVersion, versionCode: manifest.latestVersionCode, minimumSupportedVersionCode: manifest.minimumSupportedVersionCode, sha256: manifest.sha256, sizeBytes: manifest.sizeBytes, releaseNotes: manifest.releaseNotes, requiredUpdateReason: manifest.requiredUpdateReason, reason: manifest.reason });
    ledger = { ...ledger, pendingPublication: { manifestRevision: manifest.manifestRevision, canonicalIdentity: identity, phase: 'prepared', trustedReceiptAt: receiptTime } }; await atomicWriteJson(secure.ledgerPath, ledger); await hooks.afterPrepared?.();
    try {
      if (manifest.updatesEnabled) {
        if (!artifactPath) fail('available publication requires an artifact path');
        const expected = { expectedSha256: manifest.sha256, expectedSizeBytes: manifest.sizeBytes, expectedPackageId: PACKAGE_IDS[environment], expectedVersionCode: manifest.latestVersionCode, expectedVersionName: manifest.latestVersion, expectedCertificateSha256: certificateSha256, trustedTools };
        await verifyApkArtifact({ artifactPath, ...expected }); await target.uploadArtifactNoClobber(artifactPath, `damsure-${manifest.latestVersionCode}.apk`);
        ledger = { ...ledger, pendingPublication: { ...ledger.pendingPublication, phase: 'artifact-uploaded' } }; await atomicWriteJson(secure.ledgerPath, ledger); await hooks.afterArtifactUploaded?.();
        const downloaded = path.join(path.dirname(artifactPath), `.verify-${crypto.randomUUID()}.apk`); try { await target.downloadArtifact(`damsure-${manifest.latestVersionCode}.apk`, downloaded); await verifyApkArtifact({ artifactPath: downloaded, ...expected }); } finally { await fs.rm(downloaded, { force: true }); }
      }
      await target.replaceManifestAtomically(manifest); await hooks.afterManifestReplaced?.();
      ledger = { ...ledger, pendingPublication: { ...ledger.pendingPublication, phase: 'manifest-replaced' } }; await atomicWriteJson(secure.ledgerPath, ledger); await hooks.afterJournaledActivation?.();
      ledger = applyPublishedManifest(ledger, manifest); ledger = { ...ledger, receiptState: { status: 'pending', manifestRevision: manifest.manifestRevision, trustedReceiptAt: receiptTime } }; await atomicWriteJson(secure.ledgerPath, ledger); await hooks.afterCommitted?.();
      const receipt = receiptFor({ ledger, manifest, status: 'active', phase: 'committed', trustedReceiptAt: receiptTime, dryRun: false });
      if (receiptPath) { try { await atomicWriteJson(receiptPath, receipt); ledger = { ...ledger, receiptState: { ...ledger.receiptState, status: 'written' } }; await atomicWriteJson(secure.ledgerPath, ledger); } catch (error) { return { wrote: true, receipt: receiptFor({ ledger, manifest, status: 'active', phase: 'receipt-pending-recovery', trustedReceiptAt: receiptTime, dryRun: false, failure: error }), receiptPending: true }; } }
      return { wrote: true, receipt, nextLedger: ledger };
    } catch (error) { throw error; }
  }, lockOptions);
}
async function recoverPublication({ target, ledgerPath, environment, root, origin, receiptPath, lockOptions }) {
  const secure = await secureLedgerAndRoot(ledgerPath, root); const normalizedOrigin = normalizeOrigin(origin, environment);
  return withLedgerLock(secure.ledgerPath, async () => {
    let ledger = await readLedger(secure.ledgerPath, environment, secure.root, normalizedOrigin); const pending = ledger.pendingPublication; if (!pending) fail('no pending publication recovery exists');
    let remote; try { remote = await target.readManifest(); } catch { fail('cannot reconcile pending publication: manifest is unavailable'); }
    if (canonicalManifestIdentity(remote) !== pending.canonicalIdentity) fail('cannot reconcile pending publication: remote manifest identity differs');
    ledger = applyPublishedManifest(ledger, remote); ledger = { ...ledger, receiptState: { status: 'pending', manifestRevision: remote.manifestRevision, trustedReceiptAt: pending.trustedReceiptAt } }; await atomicWriteJson(secure.ledgerPath, ledger);
    const receipt = receiptFor({ ledger, manifest: remote, status: 'active', phase: 'recovered', trustedReceiptAt: pending.trustedReceiptAt, dryRun: false });
    if (receiptPath) { await atomicWriteJson(receiptPath, receipt); ledger = { ...ledger, receiptState: { ...ledger.receiptState, status: 'written' } }; await atomicWriteJson(secure.ledgerPath, ledger); }
    return { recovered: true, receipt, nextLedger: ledger };
  }, lockOptions);
}

module.exports = { LEGACY_DISABLED_MANIFEST, PRODUCTION_ORIGIN, PACKAGE_IDS, emptyLedger, readLedger, atomicWriteJson, withLedgerLock, reserveVersionCode, reserveVersionCodeAtPath, buildManifest, canonicalManifestIdentity, applyPublishedManifest, basicArtifactMetadata, validateTrustedExecutable, verifyApkArtifact, LocalReleaseTarget, publishToLocalFixture, recoverPublication, canonicalUtc, normalizeOrigin, secureLedgerAndRoot };
