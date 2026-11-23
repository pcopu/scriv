import { execFile } from 'node:child_process';
import { createHash } from 'node:crypto';
import { lstat, mkdtemp, readFile, readdir, realpath, rename, rm } from 'node:fs/promises';
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

async function readReceipt(path) {
  const info = await ownedFile(path);
  if (!info || info.size > 1024 * 1024) return;
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

export async function compactArchive(args, repo) {
  const [flag, archive, option] = args;
  if (flag !== '--archive' || !archive || !isAbsolute(archive) || (args.length !== 2 && !(args.length === 3 && option === '--apply'))) {
    throw new Error('Use tracer app -- test compact --archive /absolute/archived-runs [--apply]');
  }
  const apply = option === '--apply';
  const root = await realpath(archive);
  const stat = await lstat(root);
  if (archive !== root || !stat.isDirectory() || stat.uid !== process.getuid?.() || (stat.mode & 0o022) !== 0
      || root === '/' || root === repo || root.startsWith(repo + '/') || repo.startsWith(root + '/')) {
    throw new Error('Archive must be an owned, canonical directory outside the live source tree');
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
