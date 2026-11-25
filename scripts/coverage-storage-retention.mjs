/** Retain original native evidence; remove only verified, reproducible LLVM indexes. */
import { execFile } from 'node:child_process';
import { createHash } from 'node:crypto';
import { constants } from 'node:fs';
import { copyFile, lstat, mkdir, mkdtemp, readFile, readdir, realpath, rename, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { basename, dirname, isAbsolute, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { safeSourcePath } from './export-cli-source-manifest.mjs';
import { validateArchiveSourceSeparation } from './coverage-storage-inputs.mjs';

const execute = promisify(execFile);
const repository = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const datasetPath = 'docs/testing/code-e2e-measurements.json';
const maximum = 64 * 1024 * 1024;
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const digest = value => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);
const uuid = value => typeof value === 'string' && /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/.test(value);
const requireValue = (condition, reason) => { if (!condition) throw new Error(`coverage-retention-${reason}`); };
const inside = (root, path) => path === root || path.startsWith(root + '/');
const canonical = value => JSON.stringify(value, (_key, item) => item && typeof item === 'object' && !Array.isArray(item)
  ? Object.fromEntries(Object.keys(item).sort().map(key => [key, item[key]])) : item);
const equal = (a, b) => canonical(a) === canonical(b);
const sameFile = (a, b) => a.dev === b.dev && a.ino === b.ino && a.size === b.size && a.ctimeMs === b.ctimeMs;
const environment = () => ({ ...Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith('GIT_'))), TRACER_NO_UPDATE: '1' });

async function directory(path) {
  requireValue(typeof path === 'string' && isAbsolute(path) && resolve(path) === path, 'canonical-directory-required');
  const info = await lstat(path);
  requireValue(info.isDirectory() && !info.isSymbolicLink() && await realpath(path) === path
    && info.uid === process.getuid?.() && !(info.mode & 0o022), 'unsafe-directory');
  return info;
}

async function file(path, { expected, limit = maximum, optional = false } = {}) {
  let info;
  try { info = await lstat(path); } catch (error) { if (optional && error.code === 'ENOENT') return null; throw error; }
  requireValue(info.isFile() && !info.isSymbolicLink() && await realpath(path) === path
    && info.uid === process.getuid?.() && !(info.mode & 0o022) && info.size <= limit, 'unsafe-file');
  const bytes = await readFile(path), sha256 = hash(bytes);
  requireValue(bytes.length === info.size && sameFile(info, await lstat(path)), 'file-changed');
  requireValue(expected === undefined || digest(expected) && sha256 === expected, 'digest-mismatch');
  return { path, bytes, sha256, info };
}

export async function storageVerifier(tracerCLI) {
  requireValue(typeof tracerCLI === 'string' && isAbsolute(tracerCLI)
    && basename(tracerCLI) === 'tracer.mjs' && basename(dirname(tracerCLI)) === 'bin', 'immutable-tracer-entrypoint-required');
  const packageRoot = dirname(dirname(tracerCLI));
  const snapshot = async () => {
    const pkg = await file(join(packageRoot, 'package.json'));
    requireValue(JSON.parse(pkg.bytes).name === '@pcopu/tracercli', 'wrong-tracer-package');
    const files = [{ path: 'package.json', sha256: pkg.sha256 }];
    const walk = async path => {
      for (const entry of await readdir(join(packageRoot, path), { withFileTypes: true })) {
        const name = `${path}/${entry.name}`;
        requireValue(!entry.isSymbolicLink(), 'unsafe-tracer-package');
        if (entry.isDirectory()) await walk(name);
        else files.push({ path: name, sha256: (await file(join(packageRoot, name))).sha256 });
      }
    };
    await walk('bin'); await walk('src');
    return hash(canonical(files.sort((a, b) => a.path.localeCompare(b.path))));
  };
  await file(tracerCLI);
  const packageSHA256 = await snapshot();
  const run = async (root, args) => {
    requireValue(await snapshot() === packageSHA256, 'tracer-changed');
    const { stdout } = await execute(process.execPath, [tracerCLI, '--root', root, ...args, '--json'],
      { cwd: root, env: environment(), timeout: 120000, maxBuffer: maximum });
    requireValue(await snapshot() === packageSHA256, 'tracer-changed');
    return JSON.parse(stdout);
  };
  return { run, packageSHA256, entrypoint: tracerCLI };
}

async function publicProof({ runRoot, analysisRoot, originalDataset, sources, sessions, tool }) {
  const checked = await tool.run(analysisRoot, ['measure', 'check']);
  requireValue(checked.invalid?.length === 0 && checked.intervals === originalDataset.intervals.length, 'invalid-measurements');
  // A private independent baseline permits Tracer's real native-receipt validator
  // to inspect this run. It never writes to the retained analysis or source tree.
  const temporary = await mkdtemp(join(await realpath(tmpdir()), 'scriv-retention-verify-'));
  try {
    const baseline = join(temporary, 'baseline'); await mkdir(baseline, { mode: 0o700 });
    let copied = 0;
    for (const source of sources) {
      copied += source.info.size; requireValue(copied <= 512 * 1024 * 1024, 'source-budget-exceeded');
      const target = join(baseline, relative(analysisRoot, source.path));
      await mkdir(dirname(target), { recursive: true, mode: 0o700 });
      await copyFile(source.path, target, constants.COPYFILE_EXCL | constants.COPYFILE_FICLONE);
      await file(target, { expected: source.sha256 });
    }
    await mkdir(join(baseline, 'docs/testing'), { recursive: true, mode: 0o700 });
    await copyFile(join(analysisRoot, datasetPath), join(baseline, datasetPath), constants.COPYFILE_EXCL | constants.COPYFILE_FICLONE);
    await execute('git', ['-c', 'core.sharedRepository=0', 'init', '--template=', '-q', baseline],
      { cwd: temporary, env: environment(), timeout: 30000, maxBuffer: 65536 });
    const baselineHash = (await file(join(baseline, datasetPath))).sha256;
    for (const session of sessions) {
      const imported = await tool.run(baseline, ['measure', 'import',
        '--before', join(session.directory, 'before.lcov'), '--after', join(session.directory, 'after.lcov'),
        '--manifest', join(session.directory, 'interval.json'), '--sources', join(runRoot, 'coverage/build-sources.json'),
        ...(session.stripPrefix ? ['--strip-prefix', session.stripPrefix] : [])]);
      requireValue(imported.changed === false && imported.id === session.id, 'reimport-identity-mismatch');
    }
    requireValue((await file(join(baseline, datasetPath))).sha256 === baselineHash, 'reimport-mutated-measurements');
    const captures = join(temporary, 'baseline.json'), output = join(temporary, 'batch');
    await writeFile(captures, JSON.stringify({ version: 1, inputRoots: [baseline], scope: 'source-lines' }) + '\n', { flag: 'wx', mode: 0o600 });
    await tool.run(analysisRoot, ['measure', 'batch', '--baseline-capture-set', captures,
      '--receipt', join(runRoot, 'evidence.json'), '--reference-root', analysisRoot, '--output', output]);
    const report = JSON.parse((await file(join(output, 'report.json'))).bytes);
    requireValue(report.intervals.unique === sessions.length && report.outOfReferenceFiles.length === 0
      && report.origins.every(row => !row.invalidSnapshotFiles?.length), 'batch-proof-mismatch');
    return {
      scopeId: report.reference.scopeId,
      allObserved: report.allObserved, passedOnlyKnown: report.passedOnlyKnown,
      outcomeCounts: report.intervals.outcomes,
      outcomes: report.outcomes.declarations.map(({ id, canonicalId, journey, status, evidence }) =>
        ({ id, canonicalId, journey, status, evidence })).sort((a, b) => a.id.localeCompare(b.id)),
    };
  } finally { await rm(temporary, { recursive: true, force: true }); }
}

export async function verifyRun({ runRoot, tracerCLI, archive = dirname(runRoot) }) {
  const owner = await directory(runRoot); await directory(archive);
  await validateArchiveSourceSeparation(archive, repository);
  requireValue(inside(archive, runRoot) && runRoot !== archive && !inside(repository, runRoot)
    && !inside(runRoot, repository) && basename(runRoot).startsWith('scriv-cli-e2e-'), 'run-outside-owned-archive');
  const retained = new Map();
  const retain = async (path, options) => {
    const item = await file(path, options);
    retained.set(path, { path: relative(runRoot, path), sha256: item.sha256, bytes: item.info.size });
    return item;
  };
  const json = async (path, options) => JSON.parse((await retain(path, options)).bytes);
  const evidenceFile = join(runRoot, 'evidence.json'), evidence = await json(evidenceFile);
  requireValue(evidence.schemaVersion === 1 && evidence.kind === 'actual-app-cli-scenarios'
    && ['passed', 'failed'].includes(evidence.status) && evidence.sourceUnchanged === true && evidence.appUnchanged === true
    && (evidence.keepIndexedProfiles === undefined || typeof evidence.keepIndexedProfiles === 'boolean')
    && Number.isFinite(Date.parse(evidence.endedAt)) && !evidence.blocker
    && Array.isArray(evidence.scenarios) && evidence.scenarios.length > 0, 'unfinished-receipt');
  for (const scenario of evidence.scenarios.filter(row => row.status !== 'not-run')) {
    requireValue(['passed', 'failed'].includes(scenario.status)
      && ['owned-process-group-exited', 'owned-process-group-terminated'].includes(scenario.cleanup), 'uncertain-process-cleanup');
  }
  const coverageRoot = join(runRoot, 'coverage'); await directory(coverageRoot);
  for (const pending of ['evidence.json.tmp', 'coverage/capture.next.json']) {
    requireValue(await file(join(runRoot, pending), { optional: true }) === null, 'active-write');
  }
  const capture = await json(join(coverageRoot, 'capture.json'));
  requireValue(equal(capture, evidence.coverage) && capture.status === 'imported' && uuid(capture.invocationID)
    && Number.isSafeInteger(capture.maximumSessions) && capture.maximumSessions > 0 && capture.maximumSessions <= 64
    && Array.isArray(capture.intervals) && capture.intervals.length > 0 && capture.intervals.length <= capture.maximumSessions
    && capture.imported === capture.intervals.length, 'incomplete-capture');
  const build = await json(join(coverageRoot, 'build-record.json'), { expected: capture.buildRecordSHA256 });
  requireValue(build.kind === 'scriv-coverage-build' && build.version === 1 && build.sourceUnchanged === true
    && build.sourceManifestSha256 === capture.sourceManifestSHA256 && build.executableSha256 === evidence.app?.executableSHA256
    && build.coveragePrefix === '/scriv-source/', 'build-identity-mismatch');
  const buildManifest = join(coverageRoot, 'build-sources.json'), journeyManifest = join(coverageRoot, 'journey-sources.json');
  await json(buildManifest, { expected: capture.sourceManifestSHA256 });
  await json(journeyManifest, { expected: capture.journeySourceManifestSHA256 });
  const sourceComparison = await json(join(coverageRoot, 'source-comparison.json'));
  requireValue(equal(sourceComparison, capture.sourceProvenance) && sourceComparison.nativeInputsUnchanged === true
    && sourceComparison.sourceManifestSHA256 === capture.sourceManifestSHA256
    && sourceComparison.journeySourceManifestSHA256 === capture.journeySourceManifestSHA256, 'source-identity-mismatch');
  const probe = await json(join(coverageRoot, 'probe-sources.json'));
  requireValue(Array.isArray(probe.files) && hash(JSON.stringify(probe.files)) === probe.sha256
    && probe.sha256 === capture.probeSHA256, 'probe-identity-mismatch');
  const tracer = await json(join(coverageRoot, 'tracer-sources.json'));
  requireValue(Array.isArray(tracer.files) && hash(JSON.stringify(tracer.files)) === tracer.sha256
    && tracer.sha256 === capture.tracerPackageSHA256, 'tracer-identity-mismatch');
  const analysisRoot = join(coverageRoot, 'analysis/source'); await directory(analysisRoot);
  const analysis = await json(join(coverageRoot, 'analysis/analysis.json'));
  requireValue(equal(analysis, capture.analysis) && analysis.root === analysisRoot
    && analysis.dataset === join(analysisRoot, datasetPath), 'analysis-identity-mismatch');
  if (analysis.analysisManifestSHA256) await json(join(coverageRoot, 'analysis/analysis-sources.json'), { expected: analysis.analysisManifestSHA256 });
  const dataset = await json(join(analysisRoot, datasetPath));
  requireValue(dataset.version === 1 && dataset.kind === 'lcov-intervals' && Array.isArray(dataset.intervals)
    && dataset.intervals.length === capture.intervals.length, 'dataset-identity-mismatch');
  const byRun = new Map(dataset.intervals.map(item => [item.manifest?.runId, item]));
  requireValue(byRun.size === capture.intervals.length, 'duplicate-run-identity');
  const sourcesByPath = new Map();
  for (const interval of dataset.intervals) for (const source of interval.files) {
    requireValue(safeSourcePath(source.path) && digest(source.sha256)
      && (!sourcesByPath.has(source.path) || sourcesByPath.get(source.path) === source.sha256), 'source-identity-mismatch');
    sourcesByPath.set(source.path, source.sha256);
  }
  const sources = [];
  for (const [path, expected] of [...sourcesByPath].sort(([a], [b]) => a.localeCompare(b))) {
    sources.push(await retain(join(analysisRoot, path), { expected }));
  }
  const contexts = new Map();
  for (const entry of await readdir(coverageRoot)) if (/^context-\d+\.json$/.test(entry)) {
    const context = await json(join(coverageRoot, entry));
    requireValue(context.version === 1 && context.invocationID === capture.invocationID
      && context.sourceManifestSHA256 === capture.sourceManifestSHA256 && context.journeySourceManifestSHA256 === capture.journeySourceManifestSHA256
      && context.probeSHA256 === capture.probeSHA256 && context.buildRecordSHA256 === capture.buildRecordSHA256
      && context.executableSHA256 === build.executableSha256 && equal(context.sourceProvenance, sourceComparison)
      && context.maximumSessions === capture.maximumSessions, 'context-identity-mismatch');
    const key = `${context.scenario}#${context.group ?? ''}`;
    requireValue(!contexts.has(key), 'duplicate-context'); contexts.set(key, context);
  }
  const sessionRoot = join(coverageRoot, 'sessions'), slots = join(coverageRoot, 'slots');
  await directory(sessionRoot); await directory(slots);
  const names = await readdir(sessionRoot), slotNames = await readdir(slots);
  requireValue(names.length === capture.intervals.length && names.every(uuid)
    && slotNames.length === names.length, 'unrecorded-session');
  const derivedCandidates = [], absentDerived = [], sessions = [], intervalProof = [];
  for (const row of capture.intervals) {
    requireValue(uuid(row.runID) && names.includes(row.runID) && row.status === 'imported' && row.imported === true, 'incomplete-session');
    const stored = byRun.get(row.runID), directoryPath = join(sessionRoot, row.runID); await directory(directoryPath);
    requireValue(stored && digest(stored.id) && digest(stored.payloadSha256), 'missing-imported-interval');
    const session = await json(join(directoryPath, 'session.json'));
    requireValue(session.version === 1 && session.kind === 'scriv-session-coverage' && session.status === 'captured'
      && session.phase === 'complete' && session.runID === row.runID && session.invocationID === capture.invocationID
      && session.scenario === row.scenario && session.group === row.group && session.executableUnchanged === true
      && session.executableSHA256 === build.executableSha256 && session.sourceManifestSHA256 === capture.sourceManifestSHA256
      && session.journeySourceManifestSHA256 === capture.journeySourceManifestSHA256 && session.probeSHA256 === capture.probeSHA256
      && session.buildRecordSHA256 === capture.buildRecordSHA256 && equal(session.sourceProvenance, sourceComparison)
      && uuid(session.workspaceID) && session.counterMode === 'cumulative' && session.counterReset === false
      && session.scope === capture.scope && session.activationTargetSHA256 === capture.activationTargetSHA256
      && Number.isSafeInteger(session.slot) && session.slot >= 0 && session.slot < capture.maximumSessions
      && contexts.has(`${session.scenario}#${session.group ?? ''}`), 'session-identity-mismatch');
    requireValue(await file(join(directoryPath, 'session.json.tmp'), { optional: true }) === null, 'active-session');
    requireValue((await retain(join(slots, String(session.slot)))).bytes.toString() === row.runID, 'slot-identity-mismatch');
    const imported = await json(join(directoryPath, 'import.json'));
    requireValue(imported.id === stored.id, 'import-identity-mismatch');
    const interval = await json(join(directoryPath, 'interval.json'), { expected: stored.manifestSha256 });
    requireValue(equal(interval, stored.manifest) && equal(interval.tools, capture.tools)
      && interval.tools.some(tool => tool.name === 'llvm-profdata' && tool.hashTiming === 'capture' && digest(tool.sha256)), 'interval-manifest-mismatch');
    const exported = await json(join(directoryPath, 'exports.json'));
    const provenance = await json(join(directoryPath, 'source-provenance.json'));
    requireValue(equal(provenance, { sourceManifestSHA256: capture.sourceManifestSHA256,
      journeySourceManifestSHA256: capture.journeySourceManifestSHA256, sourceProvenance: sourceComparison }), 'session-source-mismatch');
    for (const phase of ['before', 'after']) {
      requireValue(session.profiles?.[phase]?.file === `${phase}.profraw`
        && digest(exported[phase]?.indexedSHA256) && exported[phase].rawSHA256 === session.profiles[phase].sha256
        && exported[phase].lcovSHA256 === interval[phase].sha256, 'profile-identity-mismatch');
      const raw = await retain(join(directoryPath, `${phase}.profraw`), { expected: exported[phase].rawSHA256, limit: 16 * 1024 * 1024 });
      requireValue(raw.info.size > 0 && raw.info.size === session.profiles[phase].byteCount, 'raw-profile-size-mismatch');
      await retain(join(directoryPath, `${phase}.lcov`), { expected: exported[phase].lcovSHA256 });
      const indexedPath = join(directoryPath, `${phase}.profdata`);
      const indexed = await file(indexedPath, { expected: exported[phase].indexedSHA256, optional: true });
      const identity = { path: indexedPath, sha256: exported[phase].indexedSHA256, runID: row.runID, phase };
      if (!indexed) absentDerived.push(identity);
      else if (indexed.info.nlink === 1) derivedCandidates.push({ ...identity, bytes: indexed.info.size,
        allocatedBytes: indexed.info.blocks * 512, identity: { dev: indexed.info.dev, ino: indexed.info.ino, size: indexed.info.size, ctimeMs: indexed.info.ctimeMs } });
    }
    sessions.push({ directory: directoryPath, id: stored.id, stripPrefix: stored.stripPrefix });
    intervalProof.push({ id: stored.id, payloadSHA256: stored.payloadSha256, manifestSHA256: stored.manifestSha256,
      runID: row.runID, scenario: row.scenario, ...(row.group && { group: row.group }), status: row.scenarioStatus,
      buildSHA256: interval.before.buildSha256, sourceManifestSHA256: interval.sourceManifestSha256,
      probeSHA256: interval.probeSha256, toolchainSHA256: interval.before.toolchainSha256 });
  }
  const tool = await storageVerifier(tracerCLI);
  const measured = await publicProof({ runRoot, analysisRoot, originalDataset: dataset, sources, sessions, tool });
  // Verify all retained bytes again after subprocess reads, before declaring a plan.
  for (const item of retained.values()) await file(join(runRoot, item.path), { expected: item.sha256 });
  const currentOwner = await directory(runRoot);
  requireValue(owner.dev === currentOwner.dev && owner.ino === currentOwner.ino, 'run-directory-changed');
  const sourceRoots = [
    { role: 'build', root: sourceComparison.buildSourceRoot, manifest: buildManifest, manifestSHA256: capture.sourceManifestSHA256 },
    { role: 'journey', root: sourceComparison.journeySourceRoot, manifest: journeyManifest, manifestSHA256: capture.journeySourceManifestSHA256 },
  ];
  const proof = { version: 1, runRoot, status: evidence.status, evidenceSHA256: retained.get(evidenceFile).sha256,
    captureSHA256: retained.get(join(coverageRoot, 'capture.json')).sha256,
    datasetSHA256: retained.get(join(analysisRoot, datasetPath)).sha256,
    intervals: intervalProof.sort((a, b) => a.id.localeCompare(b.id)), measured,
    retained: [...retained.values()].sort((a, b) => a.path.localeCompare(b.path)) };
  return { version: 1, kind: 'scriv-coverage-retention-verification', eligible: true, runRoot, archive,
    proof, proofSHA256: hash(canonical(proof)), sourceRoots, appIdentity: evidence.app, apps: [],
    verifier: { entrypoint: tool.entrypoint, packageSHA256: tool.packageSHA256 },
    indexPolicy: evidence.keepIndexedProfiles === true ? 'keep-indexed-profiles' : 'prune-derived-indexes',
    derivedCandidates: evidence.keepIndexedProfiles === true ? [] : derivedCandidates,
    retainedDerived: evidence.keepIndexedProfiles === true ? derivedCandidates : [], absentDerived };
}

export async function cleanRun({ runRoot, tracerCLI, archive = dirname(runRoot), apply = false }) {
  const before = await verifyRun({ runRoot, tracerCLI, archive });
  if (!apply) return { mode: 'preview', ...before, removed: [], allocatedBytesRemoved: 0 };
  const lock = join(runRoot, '.coverage-storage-lock'); await mkdir(lock, { mode: 0o700 });
  let staging, committed = false;
  const moved = [];
  try {
    const receiptPath = join(runRoot, 'retention.json');
    const priorFile = await file(receiptPath, { optional: true });
    const prior = priorFile && JSON.parse(priorFile.bytes);
    requireValue(!prior || prior.version === 1 && prior.kind === 'scriv-coverage-retention' && prior.status === 'verified'
      && prior.runRoot === runRoot && prior.evidenceSHA256 === before.proof.evidenceSHA256
      && prior.proofSHA256 === before.proofSHA256 && equal(prior.proof, before.proof)
      && Array.isArray(prior.removed), 'retention-receipt-mismatch');
    if (prior && before.derivedCandidates.length === 0) return { mode: 'apply', ...before, removed: [], allocatedBytesRemoved: 0, retention: receiptPath, unchanged: true };
    staging = await mkdtemp(join(runRoot, '.coverage-retention-'));
    for (const candidate of before.derivedCandidates) {
      const current = await file(candidate.path, { expected: candidate.sha256 });
      requireValue(current.info.nlink === 1 && sameFile(candidate.identity, current.info), 'derived-file-changed');
      const target = join(staging, String(moved.length));
      await rename(candidate.path, target); moved.push({ candidate, target });
    }
    const after = await verifyRun({ runRoot, tracerCLI, archive });
    requireValue(after.proofSHA256 === before.proofSHA256, 'proof-changed-during-cleanup');
    for (const { candidate, target } of moved) await file(target, { expected: candidate.sha256 });
    const removed = [...prior?.removed ?? [], ...moved.map(({ candidate }) => ({
      path: relative(runRoot, candidate.path), sha256: candidate.sha256, bytes: candidate.bytes,
      allocatedBytes: candidate.allocatedBytes, runID: candidate.runID, phase: candidate.phase,
    }))];
    const receipt = { version: 1, kind: 'scriv-coverage-retention', status: 'verified', runRoot,
      indexPolicy: before.indexPolicy,
      proofSHA256: before.proofSHA256, evidenceSHA256: before.proof.evidenceSHA256,
      verifiedAt: new Date().toISOString(), removed, proof: before.proof,
      notice: 'Original evidence, raw profiles, LCOV, interval identities, outcomes and source bytes are unchanged. Regenerating an index requires the recorded LLVM tool and an exact resulting digest; further compiler re-export also requires the matching signed app. Allocated candidate bytes are not a measurement of newly available APFS space.' };
    const temporaryReceipt = join(staging, 'retention.json');
    await writeFile(temporaryReceipt, JSON.stringify(receipt, null, 2) + '\n', { flag: 'wx', mode: 0o600 });
    const currentReceipt = await file(receiptPath, { optional: true });
    requireValue(priorFile ? currentReceipt?.sha256 === priorFile.sha256 : currentReceipt === null, 'retention-receipt-changed');
    await rename(temporaryReceipt, receiptPath);
    committed = true;
    await rm(staging, { recursive: true }); staging = undefined;
    return { mode: 'apply', ...after, removed: moved.map(({ candidate }) => candidate),
      allocatedBytesRemoved: moved.reduce((sum, { candidate }) => sum + candidate.allocatedBytes, 0), retention: receiptPath, unchanged: moved.length === 0 };
  } finally {
    if (!committed) for (const { candidate, target } of moved.reverse()) {
      requireValue(await file(candidate.path, { optional: true }) === null, 'restore-target-changed');
      await file(target, { expected: candidate.sha256 }); await rename(target, candidate.path);
    }
    if (staging && !committed) await rm(staging, { recursive: true, force: true });
    await rm(lock, { recursive: true });
  }
}
