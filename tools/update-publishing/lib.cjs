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
  const requestedParts = requested.split(path.sep).filter(Boolean);
  let requestedCurrent = path.parse(requested).root;
  for (const part of requestedParts) {
    requestedCurrent = path.join(requestedCurrent, part);
    const component = await fs.lstat(requestedCurrent).catch((error) => error.code === 'ENOENT' ? null : Promise.reject(error));
    if (!component) break;
    if (component.isSymbolicLink()) fail(`symlink path component is refused: ${requestedCurrent}`);
  }
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
async function claimReleaseRoot({ root, ledgerPath, environment, origin }) {
  await fs.mkdir(root, { recursive: true, mode: 0o700 });
  const markerPath = path.join(root, '.damsure-release-root-owner.json');
  const owner = { schemaVersion: 1, environment, ledgerPath, origin, root };
  try { await fs.writeFile(markerPath, `${JSON.stringify(owner, null, 2)}\n`, { mode: 0o600, flag: 'wx' }); }
  catch (error) {
    if (error.code !== 'EEXIST') throw error;
    const existing = JSON.parse(await fs.readFile(markerPath, 'utf8'));
    if (JSON.stringify(existing) !== JSON.stringify(owner)) fail('release root is already owned by a different environment, ledger, or origin');
  }
  return markerPath;
}

function emptyLedger(environment, root, origin) {
  return { schemaVersion: 2, environment, releaseRoot: root, releaseOrigin: origin, lastManifestRevision: 0, maxLatestVersionCode: 1, strictV1Started: false, reservedVersionCodes: [1], artifacts: {}, manifests: {}, pendingPublication: null, receiptState: null };
}
function validateLedger(ledger, environment, root, origin) {
  if (!ledger || ledger.schemaVersion !== 2 || ledger.environment !== environment || ledger.releaseRoot !== root || ledger.releaseOrigin !== origin || !Number.isInteger(ledger.lastManifestRevision) || ledger.lastManifestRevision < 0 || !isPositiveInt(ledger.maxLatestVersionCode) || !Array.isArray(ledger.reservedVersionCodes) || !ledger.reservedVersionCodes.includes(1) || typeof ledger.artifacts !== 'object' || typeof ledger.manifests !== 'object') fail(`invalid or environment-confused ${environment} publication ledger`);
  for (const code of ledger.reservedVersionCodes) requirePositiveInt(code, 'reserved version code');
  if (ledger.pendingPublication && (!isPositiveInt(ledger.pendingPublication.manifestRevision) || typeof ledger.pendingPublication.canonicalIdentity !== 'string' || typeof ledger.pendingPublication.manifestBytes !== 'string' || !/^[a-f0-9]{64}$/.test(ledger.pendingPublication.manifestSha256 || ''))) fail('invalid pending publication journal');
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
async function lockRecord(lockPath) {
  const stat = await fs.lstat(lockPath).catch(() => null);
  const body = await fs.readFile(path.join(lockPath, 'owner.json'), 'utf8').catch(() => null);
  if (!stat || !stat.isDirectory() || !body) return null;
  try { return { stat, owner: JSON.parse(body) }; } catch { return null; }
}
async function claimExistingLock(lock, purpose, expected) {
  const before = await lockRecord(lock);
  if (!before || before.stat.ino !== expected.inode || before.owner.nonce !== expected.nonce) return null;
  const claim = `${lock}.${purpose}.${crypto.randomUUID()}`;
  try { await fs.rename(lock, claim); } catch (error) { if (error.code === 'ENOENT') return null; throw error; }
  const actual = await lockRecord(claim);
  if (!actual || actual.stat.ino !== expected.inode || actual.owner.nonce !== expected.nonce) {
    return null;
  }
  return claim;
}
async function removeVerifiedClaim(claim, expected, hooks = {}) {
  await hooks.beforeClaimCleanup?.(claim);
  const actual = await lockRecord(claim);
  if (!actual || actual.stat.ino !== expected.inode || actual.owner.nonce !== expected.nonce) fail(`claimed lock changed; manual recovery required: ${claim}`);
  // The pathname is a freshly generated result of our atomic rename, never the
  // shared active lock. Recheck immediately before removing only that claim.
  await fs.rm(claim, { recursive: true, force: false });
}
function recoveryGuardPath(ledgerPath) { return `${ledgerPath}.recovery-guard.json`; }
async function assertNoRecoveryGuard(ledgerPath) {
  if (await fs.lstat(recoveryGuardPath(ledgerPath)).catch(() => null)) fail(`ledger recovery guard is present; manual recovery required: ${recoveryGuardPath(ledgerPath)}`);
}
async function createRecoveryGuard(ledgerPath) {
  const guard = recoveryGuardPath(ledgerPath); const value = { schemaVersion: 1, nonce: crypto.randomUUID(), createdAt: new Date().toISOString() };
  try { await fs.writeFile(guard, `${JSON.stringify(value)}\n`, { mode: 0o600, flag: 'wx' }); } catch (error) { if (error.code === 'EEXIST') fail(`ledger recovery guard is already present; manual recovery required: ${guard}`); throw error; }
  return guard;
}
async function assertLockOwnership(lock, owner, inode) {
  const current = await lockRecord(lock);
  if (!current || current.stat.ino !== inode || current.owner.nonce !== owner.nonce) fail('ledger lock ownership changed; refusing critical transition');
}
async function releaseLedgerLock(lock, owner, inode, hooks = {}) {
  await hooks.beforeReleaseClaim?.();
  const claim = await claimExistingLock(lock, 'released', { inode, nonce: owner.nonce });
  if (!claim) return false;
  await hooks.afterReleaseClaim?.(claim);
  await removeVerifiedClaim(claim, { inode, nonce: owner.nonce }, hooks);
  return true;
}
async function recoverLedgerLock(ledgerPath, recoveryReceiptPath, { hooks = {} } = {}) {
  if (!recoveryReceiptPath) fail('lock recovery requires an explicit operator recovery receipt');
  await assertNoSymlinkPath(recoveryReceiptPath);
  const receipt = await fs.lstat(recoveryReceiptPath);
  if (!receipt.isFile() || receipt.isSymbolicLink() || receipt.size === 0) fail('lock recovery receipt is invalid');
  const guard = await createRecoveryGuard(ledgerPath);
  const lock = `${ledgerPath}.lock`;
  const recorded = await lockRecord(lock); if (!recorded) fail(`lock recovery cannot read owner record; manual recovery required: ${guard}`);
  const owner = recorded.owner;
  if (!Number.isInteger(owner.pid) || typeof owner.nonce !== 'string' || typeof owner.acquiredAt !== 'string') fail('lock recovery owner record is incomplete');
  await hooks.beforeRecoveryClaim?.();
  const claimed = await claimExistingLock(lock, 'recovery-claim', { inode: recorded.stat.ino, nonce: owner.nonce });
  if (!claimed) fail(`lock changed during recovery; manual recovery required: ${guard}`);
  // PID liveness is checked only after the atomic claim. A live (including
  // reused) PID leaves the claim and guard for an operator; it is never put
  // back over the active pathname.
  try { process.kill(owner.pid, 0); fail(`lock recovery refused: recorded PID is currently live; manual recovery required: ${guard}`); } catch (error) { if (error.code !== 'ESRCH') throw error; }
  await hooks.afterRecoveryClaim?.(claimed);
  await removeVerifiedClaim(claimed, { inode: recorded.stat.ino, nonce: owner.nonce }, hooks);
  await fs.rm(guard, { force: false });
  return claimed;
}
async function withLedgerLock(ledgerPath, callback, { waitLockMs = 5000, lockHooks = {} } = {}, deadline = Date.now() + waitLockMs) {
  const lock = `${ledgerPath}.lock`;
  await assertNoRecoveryGuard(ledgerPath);
  try { await fs.mkdir(lock, { mode: 0o700 }); }
  catch (error) {
    if (error.code !== 'EEXIST') throw error;
    if (Date.now() >= deadline) fail(`ledger lock is held; use explicit recover-lock after owner-liveness review: ${lock}`);
    await new Promise((resolve) => setTimeout(resolve, 25));
    return withLedgerLock(ledgerPath, callback, { waitLockMs, lockHooks }, deadline);
  }
  const owner = { pid: process.pid, acquiredAt: new Date().toISOString(), nonce: crypto.randomUUID() };
  const inode = (await fs.stat(lock)).ino;
  try { await lockHooks.beforeOwnerWrite?.(); await assertNoRecoveryGuard(ledgerPath); const active = await fs.lstat(lock); if (active.ino !== inode) fail('ledger lock changed before owner record; manual recovery required'); await fs.writeFile(path.join(lock, 'owner.json'), `${JSON.stringify(owner)}\n`, { mode: 0o600, flag: 'wx' }); const assertOwnership = async () => { await assertNoRecoveryGuard(ledgerPath); return assertLockOwnership(lock, owner, inode); }; await assertOwnership(); return await callback({ owner, assertOwnership }); }
  finally { await releaseLedgerLock(lock, owner, inode, lockHooks); }
}

function reserveVersionCode(ledger, code) {
  requirePositiveInt(code, 'version code');
  if (code === 1) fail('version code 1 is permanently reserved');
  if (code <= ledger.maxLatestVersionCode || ledger.reservedVersionCodes.includes(code)) fail(`version code ${code} has already been reserved or published`);
  return { ...ledger, reservedVersionCodes: [...ledger.reservedVersionCodes, code].sort((a, b) => a - b) };
}
async function reserveVersionCodeAtPath({ ledgerPath, environment, root, origin, code, dryRun = false, lockOptions }) {
  const secure = await secureLedgerAndRoot(ledgerPath, root); const normalizedOrigin = normalizeOrigin(origin, environment);
  // A dry-run is a pure calculation: it deliberately does not create a lock,
  // parent directory, marker, or any other observable filesystem entry.
  if (dryRun) return reserveVersionCode(await readLedger(secure.ledgerPath, environment, secure.root, normalizedOrigin), code);
  return withLedgerLock(secure.ledgerPath, async ({ assertOwnership }) => {
    await assertOwnership();
    await claimReleaseRoot({ root: secure.root, ledgerPath: secure.ledgerPath, environment, origin: normalizedOrigin });
    const ledger = await readLedger(secure.ledgerPath, environment, secure.root, normalizedOrigin);
    const next = reserveVersionCode(ledger, code);
    await assertOwnership(); await atomicWriteJson(secure.ledgerPath, next);
    return next;
  }, lockOptions);
}

function strictManifestBytes(manifest) {
  if (!manifest || Object.getPrototypeOf(manifest) !== Object.prototype || manifest.schemaVersion !== 1 || typeof manifest.updatesEnabled !== 'boolean') fail('manifest must be a strict APP-104 v1 object');
  const availableKeys = ['schemaVersion', 'updatesEnabled', 'manifestRevision', 'latestVersion', 'latestVersionCode', 'minimumSupportedVersionCode', 'artifactUrl', 'sha256', 'sizeBytes', 'publishedAt', 'releaseNotes', 'requiredUpdateReason'];
  const disabledKeys = ['schemaVersion', 'updatesEnabled', 'manifestRevision', 'publishedAt', 'reason'];
  const keys = manifest.updatesEnabled ? availableKeys : disabledKeys;
  if (Object.keys(manifest).length !== keys.length || keys.some((key) => !Object.prototype.hasOwnProperty.call(manifest, key))) fail('manifest contains unknown or missing APP-104 fields');
  requirePositiveInt(manifest.manifestRevision, 'manifest revision'); canonicalUtc(manifest.publishedAt);
  if (!manifest.updatesEnabled) { if (typeof manifest.reason !== 'string' || !manifest.reason) fail('invalid disabled manifest'); return `${JSON.stringify({ schemaVersion: 1, updatesEnabled: false, manifestRevision: manifest.manifestRevision, publishedAt: manifest.publishedAt, reason: manifest.reason }, null, 2)}\n`; }
  if (typeof manifest.latestVersion !== 'string' || !/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(manifest.latestVersion) || !isPositiveInt(manifest.latestVersionCode) || !isPositiveInt(manifest.minimumSupportedVersionCode) || manifest.minimumSupportedVersionCode > manifest.latestVersionCode || typeof manifest.artifactUrl !== 'string' || !/^[a-f0-9]{64}$/.test(manifest.sha256) || !isPositiveInt(manifest.sizeBytes) || typeof manifest.releaseNotes !== 'string' || typeof manifest.requiredUpdateReason !== 'string') fail('invalid available APP-104 manifest');
  return `${JSON.stringify({ schemaVersion: 1, updatesEnabled: true, manifestRevision: manifest.manifestRevision, latestVersion: manifest.latestVersion, latestVersionCode: manifest.latestVersionCode, minimumSupportedVersionCode: manifest.minimumSupportedVersionCode, artifactUrl: manifest.artifactUrl, sha256: manifest.sha256, sizeBytes: manifest.sizeBytes, publishedAt: manifest.publishedAt, releaseNotes: manifest.releaseNotes, requiredUpdateReason: manifest.requiredUpdateReason }, null, 2)}\n`;
}
function canonicalManifestIdentity(manifest) { return strictManifestBytes(manifest); }
function manifestSha256(manifest) { return crypto.createHash('sha256').update(strictManifestBytes(manifest)).digest('hex'); }
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
  const canonical = await assertNoSymlinkPath(filePath);
  const stat = await fs.lstat(canonical); if (!stat.isFile() || stat.isSymbolicLink() || stat.size <= 0) fail('artifact must be a non-empty regular non-symlink file');
  if (requireApkZip) { const handle = await fs.open(canonical, 'r'); try { const header = Buffer.alloc(4); await handle.read(header, 0, 4, 0); if (!header.equals(Buffer.from([0x50, 0x4b, 0x03, 0x04]))) fail('artifact is not an APK ZIP file'); } finally { await handle.close(); } }
  return { sizeBytes: stat.size, sha256: await sha256File(canonical), canonicalPath: canonical };
}
function normalizedCertificate(value) { if (typeof value !== 'string' || !/^[A-Fa-f0-9:]+$/.test(value)) fail('certificate fingerprint must be hexadecimal SHA-256'); const normalized = value.replace(/:/g, '').toUpperCase(); if (!/^[A-F0-9]{64}$/.test(normalized)) fail('certificate fingerprint must be exactly 64 hexadecimal characters'); return normalized; }
async function validateTrustedExecutable(candidate, label) {
  if (!candidate || !path.isAbsolute(candidate)) fail(`${label} must be an explicit absolute trusted tool path`);
  const canonical = await assertNoSymlinkPath(candidate);
  const stat = await fs.lstat(canonical); if (stat.isSymbolicLink() || !stat.isFile() || (stat.mode & 0o111) === 0) fail(`${label} must be a non-symlink regular executable`);
  return canonical;
}
async function validateToolManifest(toolManifestPath, environment) {
  const canonicalManifest = await assertNoSymlinkPath(toolManifestPath);
  const stat = await fs.lstat(canonicalManifest);
  if (!stat.isFile() || stat.isSymbolicLink() || (stat.mode & 0o022) !== 0) fail('tool manifest must be a protected non-symlink regular file');
  const manifest = JSON.parse(await fs.readFile(canonicalManifest, 'utf8'));
  if (manifest.schemaVersion !== 1 || !manifest.tools || !manifest.certificates) fail('tool manifest schema is invalid');
  const certificate = manifest.certificates[environment]; const other = manifest.certificates[environment === 'production' ? 'staging' : 'production'];
  if (normalizedCertificate(certificate) === normalizedCertificate(other)) fail('tool manifest must bind distinct production and staging certificate fingerprints');
  const tools = {};
  for (const label of ['aapt', 'apksigner']) {
    const entry = manifest.tools[label]; if (!entry || typeof entry.path !== 'string' || !/^[a-f0-9]{64}$/.test(entry.sha256)) fail(`tool manifest ${label} entry is invalid`);
    const executable = await validateTrustedExecutable(entry.path, label);
    if (await sha256File(executable) !== entry.sha256) fail(`tool manifest ${label} hash mismatch`);
    tools[label] = executable;
  }
  return { tools, certificateSha256: normalizedCertificate(certificate), path: canonicalManifest };
}
async function verifyApkArtifact({ artifactPath, expectedSha256, expectedSizeBytes, expectedPackageId, expectedVersionCode, expectedVersionName, expectedCertificateSha256, toolManifestPath, environment }) {
  if (!expectedSha256 || !expectedSizeBytes || !expectedPackageId || !expectedVersionCode || !expectedVersionName || !expectedCertificateSha256) fail('APK verification requires size, SHA-256, package, version code/name, and pinned certificate expectations');
  const provenance = await validateToolManifest(toolManifestPath, environment); const aapt = provenance.tools.aapt; const apksigner = provenance.tools.apksigner;
  if (normalizedCertificate(expectedCertificateSha256) !== provenance.certificateSha256) fail('APK certificate expectation is not bound to the flavor tool manifest');
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
  async uploadArtifactNoClobber(sourcePath, name) { if (!/^damsure-[1-9]\d*\.apk$/.test(name)) fail('artifact name must be immutable damsure-<versionCode>.apk'); await assertNoSymlinkPath(sourcePath); await this.fs.mkdir(this.root, { recursive: true, mode: 0o700 }); try { await this.fs.copyFile(sourcePath, this.artifactPath(name), fsConstants.COPYFILE_EXCL); } catch (error) { if (error.code === 'EEXIST') fail(`refusing to overwrite immutable artifact ${name}`); throw error; } }
  async downloadArtifact(name, destination) { await assertNoSymlinkPath(this.artifactPath(name)); await assertNoSymlinkPath(destination, { allowMissingFinal: true }); await this.fs.copyFile(this.artifactPath(name), destination, fsConstants.COPYFILE_EXCL); return destination; }
  async replaceManifestAtomically(manifest) { await atomicWriteJson(this.manifestPath(), manifest, this.fs); }
  async readManifestBytes() { await assertNoSymlinkPath(this.manifestPath()); return this.fs.readFile(this.manifestPath(), 'utf8'); }
  async readManifest() { return JSON.parse(await this.fs.readFile(this.manifestPath(), 'utf8')); }
}
function gateProduction(options) { if (options.environment === 'production') for (const field of ['approval', 'signingBackupReceipt', 'pilotReceipt', 'dependencyReceipt']) if (!options[field]) fail(`production publication is hard-disabled without ${field}`); }
function receiptFor({ ledger, manifest, status, phase, trustedReceiptAt, dryRun, failure }) { return { schemaVersion: 2, environment: ledger.environment, action: manifest.updatesEnabled ? 'publish-available' : 'publish-disabled', manifestRevision: manifest.manifestRevision, manifestCanonicalIdentity: canonicalManifestIdentity(manifest), artifactName: manifest.updatesEnabled ? `damsure-${manifest.latestVersionCode}.apk` : null, artifactSha256: manifest.updatesEnabled ? manifest.sha256 : null, trustedReceiptAt, dryRun, activation: dryRun ? 'not-attempted' : status, phase, failure: failure ? String(failure.message || failure).replace(/[\r\n]/g, ' ') : null }; }
async function publishToLocalFixture({ target, ledgerPath, environment, root, origin, manifest, artifactPath, toolManifestPath, receiptPath, trustedReceiptAt, dryRun = false, lockOptions, hooks = {}, ...gates }) {
  gateProduction({ environment, ...gates }); const secure = await secureLedgerAndRoot(ledgerPath, root); const normalizedOrigin = normalizeOrigin(origin, environment); const receiptTime = canonicalUtc(trustedReceiptAt || manifest.publishedAt);
  if (dryRun) { const ledger = await readLedger(secure.ledgerPath, environment, secure.root, normalizedOrigin); buildManifest({ environment, ledger, type: manifest.updatesEnabled ? 'available' : 'disabled', revision: manifest.manifestRevision, publishedAt: manifest.publishedAt, origin: normalizedOrigin, version: manifest.latestVersion, versionCode: manifest.latestVersionCode, minimumSupportedVersionCode: manifest.minimumSupportedVersionCode, sha256: manifest.sha256, sizeBytes: manifest.sizeBytes, releaseNotes: manifest.releaseNotes, requiredUpdateReason: manifest.requiredUpdateReason, reason: manifest.reason }); return { wrote: false, receipt: receiptFor({ ledger, manifest, status: 'not-attempted', phase: 'dry-run', trustedReceiptAt: receiptTime, dryRun: true }) }; }
  return withLedgerLock(secure.ledgerPath, async ({ assertOwnership }) => {
    await assertOwnership();
    await claimReleaseRoot({ root: secure.root, ledgerPath: secure.ledgerPath, environment, origin: normalizedOrigin });
    let ledger = await readLedger(secure.ledgerPath, environment, secure.root, normalizedOrigin); const identity = canonicalManifestIdentity(manifest); const exactManifestSha256 = manifestSha256(manifest);
    if (ledger.pendingPublication) fail(`pending publication revision ${ledger.pendingPublication.manifestRevision} requires recover before retry`);
    buildManifest({ environment, ledger, type: manifest.updatesEnabled ? 'available' : 'disabled', revision: manifest.manifestRevision, publishedAt: manifest.publishedAt, origin: normalizedOrigin, version: manifest.latestVersion, versionCode: manifest.latestVersionCode, minimumSupportedVersionCode: manifest.minimumSupportedVersionCode, sha256: manifest.sha256, sizeBytes: manifest.sizeBytes, releaseNotes: manifest.releaseNotes, requiredUpdateReason: manifest.requiredUpdateReason, reason: manifest.reason });
    ledger = { ...ledger, pendingPublication: { manifestRevision: manifest.manifestRevision, canonicalIdentity: identity, manifestBytes: identity, manifestSha256: exactManifestSha256, manifest, phase: 'prepared', trustedReceiptAt: receiptTime } }; await assertOwnership(); await atomicWriteJson(secure.ledgerPath, ledger); await hooks.afterPrepared?.();
    try {
      if (manifest.updatesEnabled) {
        if (!artifactPath) fail('available publication requires an artifact path');
        const provenance = await validateToolManifest(toolManifestPath, environment);
        const expected = { expectedSha256: manifest.sha256, expectedSizeBytes: manifest.sizeBytes, expectedPackageId: PACKAGE_IDS[environment], expectedVersionCode: manifest.latestVersionCode, expectedVersionName: manifest.latestVersion, expectedCertificateSha256: provenance.certificateSha256, toolManifestPath, environment };
        await verifyApkArtifact({ artifactPath, ...expected }); await hooks.afterLocalVerification?.();
        // Freeze a verified copy before upload. The source path is never used
        // after this point, so a replacement between verification and upload
        // cannot alter the bytes that reach the target.
        const frozen = path.join(path.dirname(artifactPath), `.publish-${crypto.randomUUID()}.apk`);
        try {
          await assertNoSymlinkPath(artifactPath); await fs.copyFile(artifactPath, frozen, fsConstants.COPYFILE_EXCL);
          await verifyApkArtifact({ artifactPath: frozen, ...expected }); await hooks.beforeUpload?.();
          await target.uploadArtifactNoClobber(frozen, `damsure-${manifest.latestVersionCode}.apk`);
        } finally { await fs.rm(frozen, { force: true }); }
        ledger = { ...ledger, pendingPublication: { ...ledger.pendingPublication, phase: 'artifact-uploaded' } }; await assertOwnership(); await atomicWriteJson(secure.ledgerPath, ledger); await hooks.afterArtifactUploaded?.();
        const downloaded = path.join(path.dirname(artifactPath), `.verify-${crypto.randomUUID()}.apk`); try { await target.downloadArtifact(`damsure-${manifest.latestVersionCode}.apk`, downloaded); await verifyApkArtifact({ artifactPath: downloaded, ...expected }); await hooks.afterDownloadVerification?.(); } finally { await fs.rm(downloaded, { force: true }); }
      }
      await hooks.beforeManifestReplace?.(); await target.replaceManifestAtomically(manifest); await hooks.afterManifestReplaced?.();
      ledger = { ...ledger, pendingPublication: { ...ledger.pendingPublication, phase: 'manifest-replaced' } }; await assertOwnership(); await atomicWriteJson(secure.ledgerPath, ledger); await hooks.afterJournaledActivation?.();
      ledger = applyPublishedManifest(ledger, manifest); const pendingReceipt = receiptFor({ ledger, manifest, status: 'active', phase: 'committed', trustedReceiptAt: receiptTime, dryRun: false }); ledger = { ...ledger, receiptState: { status: 'pending', manifestRevision: manifest.manifestRevision, receipt: pendingReceipt } }; await assertOwnership(); await atomicWriteJson(secure.ledgerPath, ledger); await hooks.afterCommitted?.();
      const receipt = receiptFor({ ledger, manifest, status: 'active', phase: 'committed', trustedReceiptAt: receiptTime, dryRun: false });
      if (receiptPath) { try { await atomicWriteJson(receiptPath, receipt); ledger = { ...ledger, receiptState: { ...ledger.receiptState, status: 'written' } }; await assertOwnership(); await atomicWriteJson(secure.ledgerPath, ledger); } catch (error) { return { wrote: true, receipt: receiptFor({ ledger, manifest, status: 'active', phase: 'receipt-pending-recovery', trustedReceiptAt: receiptTime, dryRun: false, failure: error }), receiptPending: true }; } }
      return { wrote: true, receipt, nextLedger: ledger };
    } catch (error) { throw error; }
  }, lockOptions);
}
async function recoverPublication({ target, ledgerPath, environment, root, origin, receiptPath, lockOptions }) {
  const secure = await secureLedgerAndRoot(ledgerPath, root); const normalizedOrigin = normalizeOrigin(origin, environment);
  return withLedgerLock(secure.ledgerPath, async ({ assertOwnership }) => {
    await assertOwnership();
    let ledger = await readLedger(secure.ledgerPath, environment, secure.root, normalizedOrigin); const pending = ledger.pendingPublication;
    if (!pending) {
      if (ledger.receiptState?.status !== 'pending' || !ledger.receiptState.receipt || !receiptPath) fail('no pending publication or recoverable receipt exists');
      await atomicWriteJson(receiptPath, ledger.receiptState.receipt); ledger = { ...ledger, receiptState: { ...ledger.receiptState, status: 'written' } }; await assertOwnership(); await atomicWriteJson(secure.ledgerPath, ledger); return { recovered: true, receipt: ledger.receiptState.receipt, nextLedger: ledger };
    }
    const remoteBytes = await target.readManifestBytes().catch(() => null);
    let remote = null;
    if (remoteBytes !== null) { try { remote = JSON.parse(remoteBytes); } catch { fail('cannot reconcile pending publication: remote manifest is invalid JSON'); } }
    if (remote && (strictManifestBytes(remote) !== pending.manifestBytes || manifestSha256(remote) !== pending.manifestSha256)) fail('cannot reconcile pending publication: remote manifest full identity differs');
    if (remote) {
      ledger = applyPublishedManifest(ledger, remote); const receipt = receiptFor({ ledger, manifest: remote, status: 'active', phase: 'recovered', trustedReceiptAt: pending.trustedReceiptAt, dryRun: false }); ledger = { ...ledger, receiptState: { status: 'pending', manifestRevision: remote.manifestRevision, receipt } }; await assertOwnership(); await atomicWriteJson(secure.ledgerPath, ledger); if (receiptPath) { await atomicWriteJson(receiptPath, receipt); ledger = { ...ledger, receiptState: { ...ledger.receiptState, status: 'written' } }; await assertOwnership(); await atomicWriteJson(secure.ledgerPath, ledger); } return { recovered: true, receipt, nextLedger: ledger };
    }
    const burned = pending.manifest; ledger = applyPublishedManifest(ledger, burned); ledger = { ...ledger, manifests: { ...ledger.manifests, [String(burned.manifestRevision)]: { canonicalIdentity: pending.canonicalIdentity, burned: true } }, receiptState: { status: 'burned', manifestRevision: burned.manifestRevision, receipt: receiptFor({ ledger, manifest: burned, status: 'not-active', phase: `burned-${pending.phase}`, trustedReceiptAt: pending.trustedReceiptAt, dryRun: false }) } }; await assertOwnership(); await atomicWriteJson(secure.ledgerPath, ledger); return { recovered: true, burned: true, receipt: ledger.receiptState.receipt, nextLedger: ledger };
  }, lockOptions);
}

module.exports = { LEGACY_DISABLED_MANIFEST, PRODUCTION_ORIGIN, PACKAGE_IDS, emptyLedger, readLedger, atomicWriteJson, withLedgerLock, recoverLedgerLock, reserveVersionCode, reserveVersionCodeAtPath, buildManifest, canonicalManifestIdentity, strictManifestBytes, manifestSha256, applyPublishedManifest, basicArtifactMetadata, validateTrustedExecutable, validateToolManifest, verifyApkArtifact, LocalReleaseTarget, publishToLocalFixture, recoverPublication, canonicalUtc, normalizeOrigin, secureLedgerAndRoot };
