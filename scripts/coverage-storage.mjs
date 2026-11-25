// Managed, evidence-preserving storage for the public Scriv CLI.
import { createHash, randomUUID } from 'node:crypto';
import { hostname } from 'node:os';
import { lstat, mkdir, open, readFile, readdir, realpath, rename, unlink, writeFile } from 'node:fs/promises';
import { dirname, isAbsolute, join, resolve } from 'node:path';
import { measureArchive, forecastGrowth, checkBudget } from './coverage-storage-measure.mjs';
import { shareSource, shareBuild, deduplicateLegacyInputs, validateArchiveSourceSeparation } from './coverage-storage-inputs.mjs';
import { cleanRun, verifyRun, storageVerifier } from './coverage-storage-retention.mjs';

const policyName = 'scriv-storage-policy.json';
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const contained = (root, path) => path === root || path.startsWith(root + '/');
const required = (condition, message) => { if (!condition) throw new Error(message); };
const integer = (value, minimum = 1) => Number.isSafeInteger(value) && value >= minimum;
const missing = error => { if (error.code !== 'ENOENT') throw error; return null; };

async function jsonInput(path, maximum = 64 * 1024 * 1024) {
  required(isAbsolute(path) && await realpath(path) === path, 'storage-input-must-be-canonical');
  const info = await lstat(path);
  required(info.isFile() && !info.isSymbolicLink() && info.size <= maximum, 'storage-input-invalid');
  const bytes = await readFile(path);
  return { value: JSON.parse(bytes), bytes, sha256: sha(bytes) };
}

async function checkedArchive(archive, repo) {
  required(isAbsolute(archive) && resolve(archive) === archive && await realpath(archive) === archive,
    'storage-archive-must-be-canonical');
  const info = await lstat(archive), source = await realpath(repo);
  required(info.isDirectory() && info.uid === process.getuid?.() && !(info.mode & 0o022)
    && archive !== '/', 'storage-archive-must-be-owned-private-and-outside-source');
  await validateArchiveSourceSeparation(archive, source);
  return archive;
}

async function ownedDirectory(path) {
  await mkdir(path, { mode: 0o700 }).catch(error => { if (error.code !== 'EEXIST') throw error; });
  const info = await lstat(path);
  required(info.isDirectory() && !info.isSymbolicLink() && await realpath(path) === path
    && info.uid === process.getuid?.() && !(info.mode & 0o022), 'storage-directory-invalid');
}

async function readPolicy(archive) {
  const { value } = await jsonInput(join(archive, policyName), 16384);
  required(value.version === 1 && value.kind === 'scriv-coverage-storage-policy'
    && integer(value.budgetBytes) && integer(value.runReserveBytes)
    && integer(value.minFreeBytes, 0) && integer(value.keepReports, 0)
    && value.keepReports <= 100 && value.runReserveBytes <= value.budgetBytes,
  'storage-policy-invalid');
  return value;
}

async function lockArchive(archive) {
  await ownedDirectory(join(archive, 'storage'));
  const path = join(archive, 'storage', 'archive.lock');
  const owner = JSON.stringify({ version: 1, id: randomUUID(), pid: process.pid, host: hostname(),
    startedAt: new Date().toISOString() }) + '\n';
  const handle = await open(path, 'wx', 0o600).catch(error => {
    if (error.code === 'EEXIST') throw new Error('storage-archive-busy; inspect the lease or use storage unlock after its process exits');
    throw error;
  });
  await handle.writeFile(owner); await handle.close();
  return async () => {
    if ((await readFile(path, 'utf8')) !== owner) throw new Error('storage-lease-changed');
    await unlink(path);
  };
}

async function withLock(archive, action) {
  const release = await lockArchive(archive);
  try { return await action(); } finally { await release(); }
}

async function tracer(tracerCLI, args, cwd) {
  return (await storageVerifier(tracerCLI)).run(cwd, args);
}

async function findRuns(archive, selected) {
  if (selected) {
    required(isAbsolute(selected) && contained(archive, selected) && selected !== archive
      && await realpath(selected) === selected, 'storage-run-must-be-inside-archive');
    return [selected];
  }
  const runs = [];
  let visited = 0;
  async function visit(directory, depth) {
    required(depth <= 24 && ++visited <= 100000, 'storage-inventory-limit');
    const entries = await readdir(directory, { withFileTypes: true });
    if (entries.some(entry => entry.name === 'evidence.json' && entry.isFile())
        && entries.some(entry => entry.name === 'coverage' && entry.isDirectory())) {
      runs.push(directory);
      return;
    }
    for (const entry of entries) if (entry.isDirectory() && !entry.isSymbolicLink()
        && !entry.name.startsWith('.') && !entry.name.endsWith('.app')
        && !['shared', 'storage', 'node_modules', 'design', 'docs'].includes(entry.name)) {
      await visit(join(directory, entry.name), depth + 1);
    }
  }
  await visit(archive, 0);
  return runs.sort();
}

async function coverageView({ tracerCLI, captureSet, referenceRoot, repo }) {
  if (!captureSet && !referenceRoot) return null;
  required(captureSet && referenceRoot, 'storage-capture-set-and-reference-required-together');
  const union = await tracer(tracerCLI, ['measure', 'union', '--capture-set', captureSet], repo);
  const gaps = await tracer(tracerCLI, ['measure', 'gaps', '--capture-set', captureSet,
    '--reference-root', referenceRoot], repo);
  return { captureSetSHA256: (await jsonInput(captureSet)).sha256, union, gaps };
}

// Only reports produced by this command are caches. Arbitrary old reports and
// outcome-referenced files remain evidence until explicitly proven otherwise.
async function trimReportCache(archive, policy, apply, { tracerCLI, repo } = {}) {
  const root = join(archive, 'storage', 'reports');
  const exists = await lstat(root).catch(missing);
  if (!exists) return { removed: [], retained: [] };
  required(exists.isDirectory() && !exists.isSymbolicLink() && await realpath(root) === root,
    'storage-report-cache-invalid');
  const rows = [];
  for (const name of (await readdir(root)).sort()) {
    if (!name.endsWith('.recipe.json')) continue;
    const recipePath = join(root, name), { value: recipe } = await jsonInput(recipePath, 65536);
    required(recipe.version === 1 && recipe.kind === 'scriv-regenerable-coverage-report'
      && recipe.file === name.slice(0, -12) + '.json' && /^[a-f0-9]{64}$/.test(recipe.sha256),
    'storage-report-recipe-invalid');
    const path = join(root, recipe.file), bytes = await readFile(path);
    required(await realpath(path) === path && (await lstat(path)).isFile()
      && sha(bytes) === recipe.sha256, 'storage-report-changed');
    rows.push({ path, recipePath, recipe });
  }
  rows.sort((a, b) => b.recipe.createdAt.localeCompare(a.recipe.createdAt) || b.path.localeCompare(a.path));
  const removed = [], blocked = [];
  let tool;
  for (const row of rows.slice(policy.keepReports)) {
    // Retain the small recipe and its source hashes, so every deleted report
    // still has an exact command and identities for regeneration.
    if (apply) {
      try {
        required(row.recipe.tracerCLI === tracerCLI, 'storage-report-tracer-changed');
        tool ??= await storageVerifier(tracerCLI);
        required(row.recipe.tracerPackageSHA256 === tool.packageSHA256
          && (await jsonInput(row.recipe.captureSet)).sha256 === row.recipe.captureSetSHA256,
        'storage-report-input-changed');
        required(typeof row.recipe.queryRoot === 'string' && await realpath(row.recipe.queryRoot) === row.recipe.queryRoot,
          'storage-report-query-root-changed');
        const replay = await tool.run(row.recipe.queryRoot, ['measure', 'gaps', '--capture-set', row.recipe.captureSet,
          '--reference-root', row.recipe.referenceRoot]);
        required(sha(JSON.stringify(replay, null, 2) + '\n') === row.recipe.sha256
          && (await jsonInput(row.recipe.captureSet)).sha256 === row.recipe.captureSetSHA256,
        'storage-report-replay-mismatch');
      } catch (error) {
        blocked.push({ path: row.path, reason: error.message });
        continue;
      }
      await unlink(row.path);
      await rename(row.recipePath, row.recipePath + '.retired');
    }
    removed.push({ path: row.path, sha256: row.recipe.sha256, recipe: row.recipePath + (apply ? '.retired' : '') });
  }
  return { removed, retained: [...rows.slice(0, policy.keepReports).map(row => row.path), ...blocked.map(row => row.path)], blocked };
}

async function cleanArchive({ archive, policy, tracerCLI, runRoot, captureSet, referenceRoot, inputsFile, apply, repo }) {
  const before = await measureArchive(archive);
  const coverageBefore = await coverageView({ tracerCLI, captureSet, referenceRoot, repo });
  const runs = [], sourceRoots = [], apps = [];
  const registered = inputsFile ? await jsonInput(inputsFile) : null;
  if (registered) {
    required(registered.value.version === 1 && registered.value.kind === 'scriv-coverage-storage-inputs'
      && Array.isArray(registered.value.sourceRoots) && Array.isArray(registered.value.apps), 'storage-input-plan-invalid');
    sourceRoots.push(...registered.value.sourceRoots); apps.push(...registered.value.apps);
  }
  for (const path of await findRuns(archive, runRoot)) {
    try {
      const result = await cleanRun({ runRoot: path, tracerCLI, archive, apply });
      runs.push({ runRoot: path, ...result, status: 'verified' });
      sourceRoots.push(...(result.sourceRoots ?? [])); apps.push(...(result.apps ?? []));
    } catch (error) {
      runs.push({ runRoot: path, status: 'retained-unverified', reason: error.message });
    }
  }
  const inputs = await deduplicateLegacyInputs({ archive, sourceRoots, apps, apply });
  // Legacy inputs keep their original paths. Recheck the complete evidence
  // contract after in-place cloning as well as after removing derived indexes.
  if (apply) for (const row of runs) if (row.status === 'verified') {
    const afterRun = await verifyRun({ runRoot: row.runRoot, tracerCLI, archive });
    required(afterRun.proofSHA256 === row.proofSHA256, 'storage-post-input-proof-changed');
  }
  if (registered) required((await jsonInput(inputsFile)).sha256 === registered.sha256, 'storage-input-plan-changed');
  const reports = await trimReportCache(archive, policy, apply, { tracerCLI, repo });
  const coverageAfter = await coverageView({ tracerCLI, captureSet, referenceRoot, repo });
  required(JSON.stringify(coverageBefore) === JSON.stringify(coverageAfter), 'storage-coverage-preservation-failed');
  const skippedRuns = runs.filter(row => row.status === 'retained-unverified' || row.status === 'skipped').length;
  const inputFailures = inputs.postVerificationFailures ?? [];
  const cleanup = { status: apply && !skippedRuns && !inputFailures.length && !(reports.blocked?.length)
    ? 'verified' : apply ? 'partial' : 'preview',
    verifiedRuns: runs.length - skippedRuns, skippedRuns, applied: apply,
    postVerificationFailures: inputFailures,
    policySHA256: sha(JSON.stringify(policy)),
    captureSetUnchanged: coverageBefore ? true : null, inputsPlanSHA256: registered?.sha256 ?? null,
    coverageSHA256: coverageBefore ? sha(JSON.stringify(coverageBefore)) : null };
  const after = { ...await measureArchive(archive), cleanup };
  return { version: 1, kind: 'scriv-coverage-storage-cleanup', archive, before, after, cleanup, runs, inputs, reports,
    budget: checkBudget(after, policy),
    notice: 'Original evidence paths, raw profiles, LCOV, datasets, outcomes and identities are retained. File allocation and APFS physical usage are separate measurements.' };
}

async function policyAncestor(parent, repo) {
  let path = await realpath(parent);
  for (let depth = 0; depth < 12 && path !== '/'; depth++, path = dirname(path)) {
    if (await lstat(join(path, policyName)).catch(missing)) {
      await checkedArchive(path, repo);
      return { archive: path, policy: await readPolicy(path) };
    }
  }
  return null;
}

// Hold the same archive lease during a native capture and its retention check.
// The reservation is explicit admission control, not an APFS volume quota.
export async function enterStorageRun(outputParent, repo) {
  const managed = await policyAncestor(outputParent, repo);
  if (!managed) return null;
  const release = await lockArchive(managed.archive);
  try {
    const before = await measureArchive(managed.archive);
    const budget = checkBudget(before, managed.policy);
    required(budget.allowed, 'storage-budget-exhausted; verified evidence is preserved');
    return { ...managed, before, release };
  } catch (error) { await release(); throw error; }
}

export async function finishStorageRun(lease, { runRoot, tracerCLI, repo }) {
  if (!lease) return null;
  const report = await cleanArchive({ ...lease, tracerCLI, runRoot, apply: true, repo });
  const path = join(runRoot, 'storage.json');
  await writeFile(path, JSON.stringify(report, null, 2) + '\n', { flag: 'wx', mode: 0o600 });
  return { path, status: report.cleanup.status, budget: report.budget };
}

const usage = 'tracer app -- test storage init|audit|source|build|clean|report|forecast|unlock --archive /absolute/archive [OPTIONS]';
export async function storageCommand(args, repo) {
  if (args.length === 1 && args[0] === '--help') return {
    kind: 'scriv-coverage-storage-help', usage,
    commands: {
      init: '--archive DIR --budget-bytes N [--run-reserve-bytes N --min-free-bytes N --keep-reports N]',
      audit: '--archive DIR',
      source: '--archive DIR --source ROOT --manifest FILE --manifest-sha256 SHA256',
      build: '--archive DIR --app BUNDLE --build-record FILE',
      clean: '--archive DIR [--run DIR --tracer /package/bin/tracer.mjs --inputs FILE --capture-set FILE --reference-root ROOT --apply]',
      report: '--archive DIR --tracer /package/bin/tracer.mjs --capture-set FILE --reference-root ROOT',
      forecast: '--before FILE --after FILE [--runs 100 --new-builds N --build-bytes N]',
      unlock: '--archive DIR',
    },
    notice: 'Preview is the default for clean. Evidence is preserved; actual APFS measurements are required for a physical growth projection.',
  };
  const mode = args[0], options = {};
  const allowed = {
    init: ['--archive', '--budget-bytes', '--run-reserve-bytes', '--min-free-bytes', '--keep-reports'],
    audit: ['--archive'],
    source: ['--archive', '--source', '--manifest', '--manifest-sha256'],
    build: ['--archive', '--app', '--build-record'],
    clean: ['--archive', '--run', '--tracer', '--capture-set', '--reference-root', '--inputs', '--apply'],
    report: ['--archive', '--tracer', '--capture-set', '--reference-root'],
    forecast: ['--before', '--after', '--runs', '--new-builds', '--build-bytes'],
    unlock: ['--archive'],
  };
  required(Object.hasOwn(allowed, mode), usage);
  for (let i = 1; i < args.length; i++) {
    const flag = args[i];
    required(allowed[mode].includes(flag) && !Object.hasOwn(options, flag), usage);
    options[flag] = flag === '--apply' ? true : args[++i];
    required(options[flag] !== undefined, usage);
  }
  const number = (name, fallback, minimum = 1) => {
    const value = options[name] === undefined ? fallback : Number(options[name]);
    required(integer(value, minimum), 'storage-invalid-number-' + name);
    return value;
  };
  if (mode === 'forecast') {
    const initial = (await jsonInput(options['--before'])).value;
    const before = initial.kind === 'scriv-coverage-storage-cleanup' ? initial.after : initial;
    const selected = (await jsonInput(options['--after'])).value;
    const after = selected.kind === 'scriv-coverage-storage-cleanup' ? selected.after : selected;
    return forecastGrowth({ before, after, runs: number('--runs', 100),
      newBuilds: number('--new-builds', 0, 0), buildBytes: options['--build-bytes'] === undefined ? undefined : number('--build-bytes') });
  }
  const archive = await checkedArchive(options['--archive'], repo);
  if (mode === 'init') {
    const policy = { version: 1, kind: 'scriv-coverage-storage-policy',
      budgetBytes: number('--budget-bytes'), runReserveBytes: number('--run-reserve-bytes', 256 * 1024 * 1024),
      minFreeBytes: number('--min-free-bytes', 512 * 1024 * 1024, 0), keepReports: number('--keep-reports', 2, 0),
      retention: 'coverage-replay-with-raw-profiles', createdAt: new Date().toISOString() };
    required(policy.keepReports <= 100 && policy.runReserveBytes <= policy.budgetBytes, 'storage-policy-invalid');
    await ownedDirectory(join(archive, 'storage'));
    await writeFile(join(archive, policyName), JSON.stringify(policy, null, 2) + '\n', { flag: 'wx', mode: 0o600 });
    return { policy, measurement: await measureArchive(archive) };
  }
  const policy = await readPolicy(archive);
  if (mode === 'audit') return withLock(archive, async () => {
    const snapshot = await measureArchive(archive);
    return { ...snapshot, policy, budget: checkBudget(snapshot, policy),
      leaseNotice: 'Managed writers were excluded during this sample. The small temporary archive lease is included in disk accounting.' };
  });
  if (mode === 'unlock') {
    const path = join(archive, 'storage', 'archive.lock'), lock = await jsonInput(path, 16384);
    required(lock.value.host === hostname() && integer(lock.value.pid), 'storage-lease-host-mismatch');
    let exited = false;
    try { process.kill(lock.value.pid, 0); } catch (error) { exited = error.code === 'ESRCH'; }
    required(exited && sha(await readFile(path)) === lock.sha256, 'storage-lease-still-active');
    await unlink(path);
    return { kind: 'scriv-storage-lease-recovery', recovered: true };
  }
  return withLock(archive, async () => {
    const beforeCreate = async bytes => {
      required(integer(bytes, 0) && integer(bytes + policy.runReserveBytes), 'storage-input-size-invalid');
      const budget = checkBudget(await measureArchive(archive), { ...policy, runReserveBytes: bytes + policy.runReserveBytes });
      required(budget.allowed, 'storage-budget-exhausted; shared input was not created');
    };
    if (mode === 'source') return shareSource({ archive, source: options['--source'],
      manifest: options['--manifest'], manifestSHA256: options['--manifest-sha256'], beforeCreate });
    if (mode === 'build') return shareBuild({ archive, app: options['--app'], buildRecord: options['--build-record'], beforeCreate });
    const tracerCLI = options['--tracer'] || process.env.SCRIV_TRACER_CLI;
    if (mode === 'clean') return cleanArchive({ archive, policy, tracerCLI, runRoot: options['--run'],
      captureSet: options['--capture-set'], referenceRoot: options['--reference-root'], inputsFile: options['--inputs'],
      apply: options['--apply'] === true, repo });
    required(options['--capture-set'] && options['--reference-root'], usage);
    const captureSet = options['--capture-set'], referenceRoot = options['--reference-root'];
    const tool = await storageVerifier(tracerCLI);
    const captureSetSHA256 = (await jsonInput(captureSet)).sha256;
    const report = await tool.run(repo, ['measure', 'gaps', '--capture-set', captureSet, '--reference-root', referenceRoot]);
    required((await jsonInput(captureSet)).sha256 === captureSetSHA256, 'storage-report-input-changed');
    const root = join(archive, 'storage', 'reports'); await ownedDirectory(root);
    const id = Date.now().toString() + '-' + randomUUID(), file = id + '.json';
    const bytes = JSON.stringify(report, null, 2) + '\n';
    await beforeCreate(Buffer.byteLength(bytes) + 65536);
    await writeFile(join(root, file), bytes, { flag: 'wx', mode: 0o600 });
    const recipe = { version: 1, kind: 'scriv-regenerable-coverage-report', createdAt: new Date().toISOString(),
      file, sha256: sha(bytes), captureSet, captureSetSHA256,
      referenceRoot, queryRoot: repo, tracerCLI, tracerPackageSHA256: tool.packageSHA256,
      argv: ['measure', 'gaps', '--capture-set', captureSet, '--reference-root', referenceRoot, '--json'],
      notice: 'Disposable view; original capture sets, outcomes, datasets and evidence remain outside this cache.' };
    await writeFile(join(root, id + '.recipe.json'), JSON.stringify(recipe, null, 2) + '\n', { flag: 'wx', mode: 0o600 });
    const cache = await trimReportCache(archive, policy, true, { tracerCLI, repo });
    const retained = cache.retained.includes(join(root, file));
    return { file: retained ? join(root, file) : null, retained,
      recipe: join(root, id + '.recipe.json' + (retained ? '' : '.retired')), cache };
  });
}
