#!/usr/bin/env node
'use strict';

const fs = require('node:fs/promises');
const path = require('node:path');
const {
  atomicWriteJson, buildManifest, LocalReleaseTarget, publishToLocalFixture,
  readLedger, reserveVersionCode,
} = require('./lib.cjs');

function usage() {
  return `Usage:\n  node tools/update-publishing/publish.cjs reserve --environment staging|production --ledger FILE --version-code N [--dry-run]\n  node tools/update-publishing/publish.cjs publish --environment staging|production --ledger FILE --fixture-root DIR --type available|disabled --revision N --published-at UTC --origin HTTPS_ORIGIN [manifest fields] [--artifact FILE] [--dry-run]\n\nProduction also requires --approval NAME --signing-backup-receipt FILE --pilot-receipt FILE --dependency-receipt FILE. This local tool never connects to a server.`;
}

function args(argv) {
  const [command, ...rest] = argv;
  const values = { command };
  for (let index = 0; index < rest.length; index += 1) {
    const token = rest[index];
    if (!token.startsWith('--')) throw new Error(`unexpected argument ${token}`);
    const key = token.slice(2).replace(/-([a-z])/g, (_, letter) => letter.toUpperCase());
    if (key === 'dryRun') { values[key] = true; continue; }
    const value = rest[++index];
    if (!value || value.startsWith('--')) throw new Error(`${token} requires a value`);
    values[key] = value;
  }
  return values;
}

function integer(value, field) {
  const parsed = Number(value);
  if (!Number.isInteger(parsed)) throw new Error(`${field} must be an integer`);
  return parsed;
}

async function requireReceipt(filePath, field) {
  if (!filePath) return undefined;
  const stat = await fs.stat(filePath).catch(() => null);
  if (!stat || !stat.isFile() || stat.size === 0) throw new Error(`${field} must name a non-empty local receipt file`);
  return path.resolve(filePath);
}

async function main() {
  const options = args(process.argv.slice(2));
  if (!['reserve', 'publish'].includes(options.command) || !['staging', 'production'].includes(options.environment) || !options.ledger) {
    throw new Error(usage());
  }
  const ledgerPath = path.resolve(options.ledger);
  const ledger = await readLedger(ledgerPath, options.environment);
  if (options.command === 'reserve') {
    const next = reserveVersionCode(ledger, integer(options.versionCode, 'version code'));
    if (!options.dryRun) await atomicWriteJson(ledgerPath, next);
    process.stdout.write(`${JSON.stringify({ action: 'reserve-version-code', environment: options.environment, dryRun: Boolean(options.dryRun), versionCode: integer(options.versionCode, 'version code') }, null, 2)}\n`);
    return;
  }
  if (!options.fixtureRoot || !options.type || !options.revision || !options.publishedAt || !options.origin) throw new Error(usage());
  const manifest = buildManifest({
    environment: options.environment, ledger, type: options.type, revision: integer(options.revision, 'revision'),
    publishedAt: options.publishedAt, origin: options.origin, version: options.version,
    versionCode: options.versionCode === undefined ? undefined : integer(options.versionCode, 'version code'),
    minimumSupportedVersionCode: options.minimumSupportedVersionCode === undefined ? undefined : integer(options.minimumSupportedVersionCode, 'minimum supported version code'),
    sha256: options.sha256, sizeBytes: options.sizeBytes === undefined ? undefined : integer(options.sizeBytes, 'size bytes'),
    releaseNotes: options.releaseNotes, requiredUpdateReason: options.requiredUpdateReason, reason: options.reason,
  });
  const result = await publishToLocalFixture({
    target: new LocalReleaseTarget(options.fixtureRoot), ledgerPath, ledger, manifest, artifactPath: options.artifact,
    dryRun: Boolean(options.dryRun), approval: options.approval,
    signingBackupReceipt: await requireReceipt(options.signingBackupReceipt, 'signing backup receipt'),
    pilotReceipt: await requireReceipt(options.pilotReceipt, 'pilot receipt'),
    dependencyReceipt: await requireReceipt(options.dependencyReceipt, 'dependency receipt'),
    receiptPath: options.receipt ? path.resolve(options.receipt) : undefined,
  });
  process.stdout.write(`${JSON.stringify(result.receipt, null, 2)}\n`);
}

main().catch((error) => {
  process.stderr.write(`update publishing refused: ${error.message}\n`);
  process.exitCode = 1;
});
