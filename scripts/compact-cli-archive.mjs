import { execFile } from 'node:child_process';
import { createHash } from 'node:crypto';
import { lstat, mkdtemp, readFile, readdir, realpath, rename, rm, unlink } from 'node:fs/promises';
import { basename, dirname, isAbsolute, join, relative } from 'node:path';
import { promisify } from 'node:util';

const execute = promisify(execFile);
const maximum = 64 * 1024 * 1024;
const largeMaps = ['assertion-journey-map-native.json', 'assertion-journey-map-services.json',
  'cli-migration-inventory.json', 'code-e2e-links.json', 'proposed-scenario-map.json'];
const measuredReportKinds = new Set(['lcov-intervals', 'lcov-reference-source-gaps',
  'lcov-reference-gap-series']);
const sameFile = (first, second) => first.dev === second.dev && first.ino === second.ino
  && first.ctimeMs === second.ctimeMs && first.size === second.size;
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const digest = value => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);
const runName = /^scriv-cli-e2e-[A-Za-z0-9]{6}$/;
const sessionID = /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/;
const worthCompressing = info => info && info.size <= maximum
  && info.blocks * 512 >= Math.max(128 * 1024, info.size / 2);

async function ownedFile(path) {
  const info = await lstat(path).catch(error => { if (!['ENOENT', 'ENOTDIR'].includes(error.code)) throw error; });
  if (info?.isFile() && info.nlink === 1 && info.uid === process.getuid?.() && await realpath(path) === path) return info;
}

export async function compactFile(path, expectedSHA256) {
  if (process.platform !== 'darwin') return 0;
  let staging;
  try {
    const original = await ownedFile(path);
    if (!original || original.size > maximum || original.blocks * 512 < original.size / 2) return 0;
    staging = await mkdtemp(join(dirname(path), '.scriv-compact-'));
    const candidate = join(staging, basename(path));
    // ditto preserves ACLs and extended attributes and creates a normally readable file.
    await execute('/usr/bin/ditto', ['--hfsCompression', path, candidate], { timeout: 30000, maxBuffer: 65536 });
    const compressed = await lstat(candidate);
    if (compressed.blocks >= original.blocks || compressed.size !== original.size
        || compressed.mode !== original.mode || compressed.uid !== original.uid || compressed.gid !== original.gid
        || Math.abs(compressed.mtimeMs - original.mtimeMs) >= 1) return 0;
    const bytes = await readFile(path);
    if (!(await readFile(candidate)).equals(bytes) || (expectedSHA256 && sha256(bytes) !== expectedSHA256)) return 0;
    const current = await ownedFile(path);
    if (!current || !sameFile(original, current)) return 0;
    await rename(candidate, path);
    return (original.blocks - compressed.blocks) * 512;
  } catch {
    // Preserve the original readable artifact if compression is unavailable.
    return 0;
  } finally {
    if (staging) await rm(staging, { recursive: true, force: true }).catch(() => {});
  }
}

async function readReceipt(path, limit = 1024 * 1024) {
  const info = await ownedFile(path);
  if (!info || info.size > limit) return;
  try { return JSON.parse(await readFile(path, 'utf8')); }
  catch (error) { if (!(error instanceof SyntaxError) && error.code !== 'ENOENT') throw error; }
}

async function findProfiles(directory, candidates) {
  const coverage = join(directory, 'coverage');
  const report = await readReceipt(join(coverage, 'capture.json'));
  if (report?.status !== 'imported' || !Array.isArray(report.intervals)) return;
  for (const interval of report.intervals) {
    const id = interval?.runID;
    if (interval?.status !== 'imported' || interval.imported !== true
        || typeof id !== 'string' || !/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/.test(id)) continue;
    const session = join(coverage, 'sessions', id);
    const imported = await readReceipt(join(session, 'import.json'));
    if (typeof imported?.id !== 'string' || !/^[a-f0-9]{64}$/.test(imported.id)) continue;
    const exports = await readReceipt(join(session, 'exports.json'));
    for (const phase of ['before', 'after']) {
      for (const [extension, field] of [['profraw', 'rawSHA256'], ['profdata', 'indexedSHA256'], ['lcov', 'lcovSHA256']]) {
        const digest = exports?.[phase]?.[field];
        if (typeof digest !== 'string' || !/^[a-f0-9]{64}$/.test(digest)) continue;
        const path = join(session, phase + '.' + extension);
        if (worthCompressing(await ownedFile(path)) && sha256(await readFile(path)) === digest) candidates.set(path, digest);
      }
    }
  }
}

async function findArtifacts(directory, candidates) {
  const entries = await readdir(directory, { withFileTypes: true });
  if (basename(directory).startsWith('scriv-cli-e2e-')) await findProfiles(directory, candidates);
  if (entries.some(entry => entry.name === 'tracer.json' && entry.isFile())) {
    const packagePath = join(directory, 'package.json');
    const manifest = await ownedFile(packagePath);
    let packageName;
    if (manifest && manifest.size <= 65536) {
      const json = await readFile(packagePath, 'utf8');
      try { packageName = JSON.parse(json)?.name; } catch { /* Unrelated or incomplete snapshot. */ }
    }
    if (packageName === 'scriv') {
      for (const name of largeMaps) {
        const path = join(directory, 'docs', 'testing', name);
        const info = await ownedFile(path);
        if (worthCompressing(info)) candidates.set(path, undefined);
      }
    }
  }
  for (const entry of entries) {
    const path = join(directory, entry.name);
    if (entry.isDirectory() && !entry.name.startsWith('.') && !entry.name.endsWith('.app')
        && !['docs', 'design', 'node_modules'].includes(entry.name)) {
      await findArtifacts(path, candidates);
    }
    if (entry.isFile() && entry.name.includes('report') && entry.name.endsWith('.json')
        && worthCompressing(await ownedFile(path))) {
      const bytes = await readFile(path);
      let report;
      try { report = JSON.parse(bytes); }
      catch { continue; }
      if (measuredReportKinds.has(report?.kind)) candidates.set(path, sha256(bytes));
    }
  }
}

async function matchesDigest(path, expected) {
  const info = await ownedFile(path);
  return digest(expected) && info && info.size <= maximum && sha256(await readFile(path)) === expected ? info : undefined;
}

// The raw captures and exact LCOV inputs remain the evidence. LLVM indexes
// are reproducible working files and are never needed to read Tracer's dataset.
export async function pruneRunIndexes(directory, { apply = false, tracer } = {}) {
  const result = { candidates: [], filesRemoved: 0, allocatedBytesRemoved: 0 };
  const coverage = join(directory, 'coverage');
  const receiptPath = join(directory, 'evidence.json');
  const capturePath = join(coverage, 'capture.json');
  const receiptInfo = await ownedFile(receiptPath), captureInfo = await ownedFile(capturePath);
  const receipt = await readReceipt(receiptPath), capture = await readReceipt(capturePath);
  const analysis = join(coverage, 'analysis', 'source');
  const datasetPath = join(analysis, 'docs/testing/code-e2e-measurements.json');
  if (!runName.test(basename(directory)) || !receiptInfo || !captureInfo
      || receipt?.schemaVersion !== 1 || receipt.kind !== 'actual-app-cli-scenarios'
      || !['passed', 'failed'].includes(receipt.status) || !Number.isFinite(Date.parse(receipt.endedAt))
      || receipt.sourceUnchanged !== true || receipt.appUnchanged !== true || receipt.keepIndexedProfiles === true
      || !Array.isArray(receipt.scenarios)
      || !receipt.scenarios.some(row => ['owned-process-group-exited', 'owned-process-group-terminated'].includes(row?.cleanup))
      || receipt.scenarios.some(row => row?.cleanup?.startsWith('uncertain'))
      || capture?.status !== 'imported' || !Array.isArray(capture.intervals) || !capture.intervals.length
      || capture.imported !== capture.intervals.length || capture.analysis?.root !== analysis
      || capture.analysis.dataset !== datasetPath || JSON.stringify(receipt.coverage) !== JSON.stringify(capture)) return result;
  const datasetInfo = await ownedFile(datasetPath);
  const dataset = await readReceipt(datasetPath, maximum);
  if (!datasetInfo || dataset?.version !== 1 || dataset.kind !== 'lcov-intervals'
      || !Array.isArray(dataset.intervals) || dataset.intervals.length !== capture.imported) return result;
  const imported = new Map(dataset.intervals.map(row => [row?.id, row]));
  const indexes = [];
  for (const interval of capture.intervals) {
    if (interval?.status !== 'imported' || interval.imported !== true || !sessionID.test(interval.runID)) return result;
    const session = join(coverage, 'sessions', interval.runID);
    const receipt = await readReceipt(join(session, 'import.json'));
    const stored = imported.get(receipt?.id);
    if (!digest(receipt?.id) || stored?.manifest?.runId !== interval.runID
        || !await matchesDigest(join(session, 'interval.json'), stored.manifestSha256)) return result;
    imported.delete(receipt.id);
    const exports = await readReceipt(join(session, 'exports.json'));
    const candidates = [];
    for (const phase of ['before', 'after']) {
      const path = join(session, phase + '.profdata');
      const info = await matchesDigest(path, exports?.[phase]?.indexedSHA256);
      if (info) candidates.push({ path, info });
    }
    if (!candidates.length) continue;
    for (const phase of ['before', 'after']) {
      const raw = exports?.[phase]?.rawSHA256, lcov = exports?.[phase]?.lcovSHA256;
      if (lcov !== stored.manifest[phase]?.sha256
          || !await matchesDigest(join(session, phase + '.profraw'), raw)
          || !await matchesDigest(join(session, phase + '.lcov'), lcov)) return result;
    }
    indexes.push(...candidates);
  }
  if (!indexes.length) return result;
  const configured = process.env.SCRIV_TRACER_CLI;
  const executable = tracer?.executable ?? (configured?.endsWith('.mjs') ? process.execPath : configured || 'tracer');
  const prefix = tracer?.prefix ?? (configured?.endsWith('.mjs') ? [configured] : []);
  const checked = await execute(executable, [...prefix, '--root', analysis, 'measure', 'check', '--json'],
    { cwd: analysis, timeout: 30000, maxBuffer: 1024 * 1024, env: { ...process.env, TRACER_NO_UPDATE: '1' } })
    .then(({ stdout }) => JSON.parse(stdout)).catch(() => null);
  if (checked?.kind !== 'lcov-intervals' || checked.intervals !== capture.imported || checked.invalid?.length !== 0) return result;
  for (const [path, info] of [[receiptPath, receiptInfo], [capturePath, captureInfo], [datasetPath, datasetInfo]]) {
    const current = await ownedFile(path);
    if (!current || !sameFile(info, current)) return result;
  }
  result.candidates = indexes.map(({ path }) => path);
  for (const { path, info } of apply ? indexes : []) {
    const current = await ownedFile(path);
    if (!current || !sameFile(info, current)) continue;
    try { await unlink(path); }
    catch (error) { if (error.code === 'ENOENT') continue; throw error; }
    result.filesRemoved++;
    result.allocatedBytesRemoved += info.blocks * 512;
  }
  return result;
}

async function* archivedRuns(directory) {
  if (runName.test(basename(directory))) { yield directory; return; }
  const entries = await readdir(directory, { withFileTypes: true });
  if (entries.some(entry => entry.isFile() && entry.name === 'tracer.json')) return;
  for (const entry of entries) {
    if (entry.isDirectory() && !entry.name.startsWith('.') && !entry.name.endsWith('.app')
        && !['docs', 'design', 'node_modules'].includes(entry.name)) yield* archivedRuns(join(directory, entry.name));
  }
}

export async function compactArchive(args, repo) {
  const [flag, archive, ...options] = args;
  if (flag !== '--archive' || !archive || !isAbsolute(archive)
      || new Set(options).size !== options.length || !options.every(option => ['--apply', '--prune'].includes(option))) {
    throw new Error('Use tracer app -- test compact --archive /absolute/archived-runs [--prune] [--apply]');
  }
  const apply = options.includes('--apply');
  const root = await realpath(archive);
  const stat = await lstat(root);
  if (archive !== root || !stat.isDirectory() || stat.uid !== process.getuid?.() || (stat.mode & 0o022) !== 0
      || root === '/' || root === repo || root.startsWith(repo + '/') || repo.startsWith(root + '/')) {
    throw new Error('Archive must be an owned, canonical directory outside the live source tree');
  }
  if (options.includes('--prune')) {
    const result = { mode: apply ? 'apply' : 'preview', candidates: [], filesRemoved: 0, allocatedBytesRemoved: 0 };
    for await (const directory of archivedRuns(root)) {
      const run = await pruneRunIndexes(directory, { apply });
      result.candidates.push(...run.candidates.map(path => relative(root, path)));
      result.filesRemoved += run.filesRemoved;
      result.allocatedBytesRemoved += run.allocatedBytesRemoved;
    }
    return result;
  }
  if (apply && process.platform !== 'darwin') throw new Error('Applying archive compression requires macOS');
  const candidates = new Map();
  await findArtifacts(root, candidates);
  const paths = [...candidates.keys()].sort();
  let filesCompacted = 0;
  let allocatedBytesSaved = 0;
  for (const path of apply ? paths : []) {
    const saved = await compactFile(path, candidates.get(path));
    filesCompacted += Number(saved > 0);
    allocatedBytesSaved += saved;
  }
  return { mode: apply ? 'apply' : 'preview', candidates: paths.map(path => relative(root, path)), filesCompacted, allocatedBytesSaved };
}
