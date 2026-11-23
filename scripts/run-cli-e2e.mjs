#!/usr/bin/env node
/** Actual-app evidence only. No mock fallback, raw logs, or migration promotion. */
import { verifySourceManifest } from './export-cli-source-manifest.mjs';
import { scenarioRestrictions } from '../cli/scenario-restrictions.mjs';
import { spawn, execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { lstat, readlink, readdir, realpath, mkdtemp, mkdir, writeFile, rename } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve, relative } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const now = () => new Date().toISOString();
const digest = value => createHash('sha256').update(value).digest('hex');
const git = (...args) => execFileSync('git', args, { cwd: repo, maxBuffer: 64 * 1024 * 1024, stdio: ['ignore', 'pipe', 'ignore'] });
async function hashFile(path) {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(path)) hash.update(chunk);
  return hash.digest('hex');
}
async function fingerprint(root, paths) {
  const hash = createHash('sha256');
  for (const path of [...new Set(paths)].sort()) {
    const full = join(root, path);
    const info = await lstat(full).catch(error => { if (error.code === 'ENOENT') return null; throw error; });
    const content = !info ? 'missing' : info.isSymbolicLink() ? `link:${await readlink(full)}` : info.isFile() ? await hashFile(full) : 'directory';
    hash.update(JSON.stringify([path, info ? info.mode & 0o777 : null, content]) + '\n');
  }
  return hash.digest('hex');
}
export async function sourceIdentity(options = {}) {
  if (options.manifest) return verifySourceManifest(repo, options.manifest, options.manifestSHA256);
  const paths = git('ls-files', '-z', '--cached', '--others', '--exclude-standard').toString().split('\0').filter(Boolean);
  // Nested repositories require their own provenance; do not silently hash directories as source.
  if (git('ls-files', '--stage').toString().split('\n').some(line => line.startsWith('160000 '))) throw new Error('submodule-provenance-unsupported');
  return {
    mode: 'git-working-tree',
    head: git('rev-parse', 'HEAD').toString().trim(),
    worktreeSHA256: await fingerprint(repo, paths),
    indexSHA256: digest(git('ls-files', '--stage', '-z')),
    fileCount: new Set(paths).size,
    algorithm: 'sha256 of sorted JSON [relative path, permission mode, content sha256 or symlink target or missing] lines; tracked and nonignored untracked files',
  };
}
async function bundleIdentity(app) {
  const root = await realpath(app);
  if (!root.endsWith('.app')) throw new Error('invalid-app-bundle');
  const executable = join(root, 'Contents/MacOS/Scriv');
  if (!(await lstat(executable)).isFile()) throw new Error('missing-app-executable');
  if (process.platform === 'darwin') {
    try {
      execFileSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', '--all-architectures', root],
        { stdio: 'ignore', timeout: 30000 });
    } catch { throw new Error('app-signature-verification-failed'); }
  }
  const paths = [];
  async function walk(dir) {
    for (const entry of await readdir(join(root, dir), { withFileTypes: true })) {
      const path = join(dir, entry.name);
      if (entry.isDirectory()) await walk(path); else paths.push(path);
    }
  }
  await walk('');
  return { executableSHA256: await hashFile(executable), bundleSHA256: await fingerprint(root, paths), fileCount: paths.length };
}
function groupExists(pid) {
  try { process.kill(-pid, 0); return true; } catch (error) { return error.code !== 'ESRCH'; }
}
function signalGroup(pid, signal) {
  try { process.kill(-pid, signal); } catch (error) { if (error.code !== 'ESRCH') return false; }
  return true;
}
const delay = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
export async function runScenario(script, { app, timeoutMs, cwd = repo, coverageContext, startupCoverage, group }) {
  const result = { scenario: relative(repo, script), ...(group && { group }), status: 'failed', startedAt: now(), endedAt: null, exitCode: null, signal: null, reason: null, cleanup: 'not-started' };
  // A dedicated group contains the Node scenario and its directly spawned Scriv app.
  // Never kill by executable name or bundle ID, which could target the user's app.
  const env = { ...process.env, SCRIV_E2E_APP: app };
  delete env.SCRIV_E2E_COVERAGE_CONTEXT;
  delete env.SCRIV_E2E_COVERAGE_STARTUP;
  if (coverageContext) env.SCRIV_E2E_COVERAGE_CONTEXT = coverageContext;
  if (coverageContext && startupCoverage) env.SCRIV_E2E_COVERAGE_STARTUP = '1';
  const scriptArgs = group ? [script, '--group', group] : [script];
  const child = spawn(process.execPath, scriptArgs, { cwd, detached: true, env, stdio: 'ignore' });
  let timer;
  let interrupted = null;
  const abort = signal => { interrupted = signal; if (child.pid) signalGroup(child.pid, 'SIGTERM'); };
  const onInt = () => abort('SIGINT');
  const onTerm = () => abort('SIGTERM');
  process.on('SIGINT', onInt); process.on('SIGTERM', onTerm);
  const ended = new Promise(resolve => {
    child.once('error', () => resolve({ reason: 'scenario-spawn-failed' }));
    child.once('exit', (exitCode, signal) => resolve({ exitCode, signal }));
  });
  const outcome = await Promise.race([ended, new Promise(resolve => { timer = setTimeout(() => resolve({ reason: 'scenario-timeout' }), timeoutMs); })]);
  clearTimeout(timer);
  Object.assign(result, outcome);
  if (interrupted) result.reason = 'runner-interrupted';
  if (child.pid && groupExists(child.pid)) {
    signalGroup(child.pid, 'SIGTERM');
    const deadline = Date.now() + 5000;
    while (groupExists(child.pid) && Date.now() < deadline) await delay(50);
    if (groupExists(child.pid)) {
      signalGroup(child.pid, 'SIGKILL');
      const forceDeadline = Date.now() + 2000;
      while (groupExists(child.pid) && Date.now() < forceDeadline) await delay(50);
    }
    result.cleanup = groupExists(child.pid) ? 'uncertain-owned-process-group-remains' : 'owned-process-group-terminated';
  } else result.cleanup = child.pid ? 'owned-process-group-exited' : 'not-started';
  process.removeListener('SIGINT', onInt); process.removeListener('SIGTERM', onTerm);
  result.endedAt = now();
  if (!result.reason && result.exitCode === 0 && !result.cleanup.startsWith('uncertain')) result.status = 'passed';
  else result.reason ??= result.cleanup.startsWith('uncertain') ? 'app-cleanup-uncertain' : 'scenario-nonzero-exit';
  return result;
}

async function discoverScenarios() {
  // Transitional slices and consolidated journeys use the same real-app gate.
  // Only regular entrypoint files qualify, never support modules or symlinks.
  const entrypoints = async directory => (await readdir(join(repo, 'tests/e2e', directory), { withFileTypes: true }))
    .filter(entry => entry.isFile() && /^[A-Za-z0-9_-]+\.mjs$/.test(entry.name))
    .map(entry => directory ? `${directory}/${entry.name}` : entry.name);
  return [...await entrypoints(''), ...await entrypoints('journeys')].sort();
}

// These entrypoints implement the shared, launch-free group catalog.
const groupedScenarios = new Set([
  'journeys/script-authoring-source.mjs', 'journeys/script-authoring-boundaries.mjs',
  'journeys/script-authoring-search.mjs', 'journeys/script-structure.mjs', 'journeys/text-identity-review.mjs',
  'journeys/import-export.mjs', 'journeys/native-cloud-project-sync.mjs',
  'journeys/picture-coverage.mjs', 'journeys/codex-loopback-generation.mjs',
]);
const validGroup = value => typeof value === 'string' && /^[a-z0-9][a-z0-9-]{0,79}$/.test(value);
function discoverGroups(name) {
  const env = { ...process.env };
  delete env.SCRIV_E2E_APP;
  delete env.SCRIV_E2E_COVERAGE_CONTEXT;
  const output = execFileSync(process.execPath, [join(repo, 'tests/e2e', name), '--list-cases'],
    { cwd: repo, env, encoding: 'utf8', timeout: 5000, maxBuffer: 1024 * 1024, stdio: ['ignore', 'pipe', 'ignore'] });
  const { groups } = JSON.parse(output);
  if (!Array.isArray(groups) || !groups.length || !groups.every(validGroup)
      || new Set(groups).size !== groups.length) throw new Error('invalid-scenario-group-catalog');
  return groups;
}

export async function main(args = process.argv.slice(2)) {
  const sourceOptions = {}; const requested = []; const seen = new Set();
  const coverageOptions = {};
  let outputParent = tmpdir(); let timeoutMs = 120000; let app = process.env.SCRIV_E2E_APP;
  let list = false; let help = false; let coverage = false; let group;
  const valued = new Set(['--app', '--source-manifest', '--source-manifest-sha256', '--output-dir', '--timeout-ms', '--scenario', '--group', '--coverage-build-record', '--coverage-build-source-root', '--coverage-build-source-manifest', '--coverage-build-source-manifest-sha256', '--llvm-profdata', '--llvm-cov', '--tracer', '--coverage-max-sessions']);
  for (let i = 0; i < args.length; i++) {
    const flag = args[i];
    if (seen.has(flag) && flag !== '--scenario') throw new Error('duplicate-option');
    seen.add(flag);
    let value;
    if (valued.has(flag)) {
      value = args[++i];
      if (!value || value.startsWith('--') || /[\x00-\x1f\x7f]/.test(value)) throw new Error('option-value-required');
    }
    if (flag === '--app') app = resolve(value);
    else if (flag === '--source-manifest') sourceOptions.manifest = resolve(value);
    else if (flag === '--source-manifest-sha256') sourceOptions.manifestSHA256 = value;
    else if (flag === '--output-dir') outputParent = resolve(value);
    else if (flag === '--coverage') coverage = true;
    else if (flag === '--coverage-startup') coverageOptions.startup = true;
    else if (flag === '--coverage-build-source-root') coverageOptions.buildSourceRoot = resolve(value);
    else if (flag === '--coverage-build-source-manifest') (coverageOptions.buildSourceOptions ??= {}).manifest = resolve(value);
    else if (flag === '--coverage-build-source-manifest-sha256') (coverageOptions.buildSourceOptions ??= {}).manifestSHA256 = value;
    else if (flag === '--coverage-build-record') coverageOptions.buildRecordPath = resolve(value);
    else if (['--llvm-profdata', '--llvm-cov', '--tracer'].includes(flag)) {
      if (!value.startsWith('/')) throw new Error('coverage-tool-path-must-be-absolute');
      coverageOptions[{ '--llvm-profdata': 'llvmProfdata', '--llvm-cov': 'llvmCov', '--tracer': 'tracer' }[flag]] = value;
    }
    else if (flag === '--coverage-max-sessions') {
      if (!/^[1-9]\d*$/.test(value) || Number(value) > 64) throw new Error('invalid-coverage-session-limit');
      coverageOptions.maximumSessions = Number(value);
    }
    else if (flag === '--timeout-ms') { if (!/^\d+$/.test(value)) throw new Error('invalid-timeout'); timeoutMs = Number(value); }
    else if (flag === '--scenario') {
      if (!/^(?:journeys\/)?[A-Za-z0-9_-]+$/.test(value)) throw new Error('invalid-scenario-id');
      if (requested.includes(value)) throw new Error('duplicate-scenario');
      requested.push(value);
    }
    else if (flag === '--group') {
      if (!validGroup(value)) throw new Error('invalid-scenario-group');
      group = value;
    }
    else if (flag === '--list') list = true;
    else if (flag === '--help') help = true;
    else throw new Error('invalid-arguments');
  }
  if (!sourceOptions.manifest && sourceOptions.manifestSHA256) throw new Error('manifest-required-for-digest');
  if (sourceOptions.manifest && !/^[a-f0-9]{64}$/.test(sourceOptions.manifestSHA256 ?? '')) throw new Error('manifest-digest-required');
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 100 || timeoutMs > 3600000) throw new Error('invalid-timeout');
  if (coverageOptions.buildSourceRoot || coverageOptions.buildSourceOptions) {
    if (!coverageOptions.buildSourceRoot || !coverageOptions.buildSourceOptions?.manifest
        || !/^[a-f0-9]{64}$/.test(coverageOptions.buildSourceOptions?.manifestSHA256 ?? '')) throw new Error('coverage-build-source-requires-root-manifest-and-digest');
  }
  if (!coverage && Object.keys(coverageOptions).length) throw new Error('coverage-options-require-coverage');
  if (coverage && (!sourceOptions.manifest || !coverageOptions.buildRecordPath || !requested.length)) throw new Error('coverage-requires-pinned-build-source-and-scenarios');
  if (help) {
    if (args.length !== 1) throw new Error('help-must-be-used-alone');
    console.log('Run through Tracer: tracer app -- test [OPTIONS]\n  --list                         Discover native scenario IDs and known restrictions as JSON; no app is launched.\n  --scenario ID                  Select an exact listed ID; repeat for a subset.\n  --group NAME                  Run one listed group of one explicit scenario.\n  --app /path/ScrivAutomation.app Override SCRIV_E2E_APP. Requires macOS.\n  --output-dir /existing/path     Evidence parent outside the source tree (default: OS temp).\n  --timeout-ms 120000             Per-scenario limit, 100 through 3600000.\n  --source-manifest /external/source.json --source-manifest-sha256 SHA256\n                                 Pin exported source bytes; both options are required.\n  --coverage                     Capture each real session, export separate LCOV pairs, import through Tracer.\n                                 Requires explicit --scenario, pinned source and --coverage-build-record.\n  --coverage-startup             Measure entry through the real CLI handshake. Requires --coverage.\n                                 Run the selected scenarios normally and keep their outcomes.\n  --coverage-build-record /external/build.json  Record produced by the coverage builder.\n  --coverage-build-source-root /immutable/source --coverage-build-source-manifest /external/build-source.json\n  --coverage-build-source-manifest-sha256 SHA256\n                                 Optional original build tree; all three required. Only host test/docs/probe changes are allowed.\n  --coverage-max-sessions 64      Maximum total capture attempts, 1 through 64.\n  --llvm-profdata /absolute/tool --llvm-cov /absolute/tool\n                                 Optional compatible LLVM tools; defaults to xcrun discovery.\n  --tracer /absolute/tracer       Optional Tracer 0.1.2+ entrypoint; defaults to SCRIV_TRACER_CLI or PATH.\n  --help                         Show this help.\n\nNo selection runs all native scenarios in sorted order; subsets are labeled in evidence.\nNo app, no macOS or failed provenance means not-run, never a simulated pass.\nKnown blocked scenarios are not launched and cannot count as passing; no bypass option exists.\nExit: 0 selected scenarios passed; 1 failed; 2 not-run or invalid input.\nTooling only: tracer app -- test tooling\nDirect compatibility: node scripts/run-cli-e2e.mjs [OPTIONS]');
    return 0;
  }
  const available = await discoverScenarios();
  if (requested.some(id => !available.includes(`${id}.mjs`))) throw new Error('unknown-scenario');
  const names = requested.length ? available.filter(name => requested.includes(name.slice(0, -4))) : available;
  if (group) {
    if (list || requested.length !== 1 || !groupedScenarios.has(names[0])) throw new Error('group-requires-one-supported-scenario');
    if (!discoverGroups(names[0]).includes(group)) throw new Error('unknown-scenario-group');
  }
  const selection = { mode: requested.length ? 'subset' : 'all', availableScenarioCount: available.length, selectedScenarioCount: names.length, ...(group && { group }) };
  if (list) {
    if ([...seen].some(flag => !['--list', '--scenario'].includes(flag))) throw new Error('list-does-not-accept-execution-options');
    const scenarios = names.map(name => {
      const id = name.slice(0, -4);
      const restriction = scenarioRestrictions[id];
      return { id, path: `tests/e2e/${name}`, ...(restriction && { restriction }),
        ...(groupedScenarios.has(name) && !restriction && { groups: discoverGroups(name) }) };
    });
    console.log(JSON.stringify({ schemaVersion: 1, kind: 'native-cli-scenario-catalog', selection, scenarios }, null, 2));
    return 0;
  }
  // Keep generated evidence out of the fingerprinted source tree.
  const outputReal = await realpath(outputParent).catch(() => null);
  if (!outputReal) throw new Error('output-parent-must-exist');
  const sourceReal = await realpath(repo);
  if (outputReal === sourceReal || outputReal.startsWith(sourceReal + '/')) throw new Error('output-must-be-outside-source');
  if (coverageOptions.buildSourceRoot) {
    const buildSourceReal = await realpath(coverageOptions.buildSourceRoot);
    if (outputReal === buildSourceReal || outputReal.startsWith(buildSourceReal + '/')) throw new Error('output-must-be-outside-build-source');
  }
  await mkdir(outputReal, { recursive: true });
  const output = await mkdtemp(join(outputReal, 'scriv-cli-e2e-'));
  const path = join(output, 'evidence.json');
  const report = { schemaVersion: 1, kind: 'actual-app-cli-scenarios', selection, fullSuitePassed: false, launcherMode: 'direct-spawn-inherited-process-group', cleanupScope: 'Only the runner-owned process group is verified; detached or LaunchServices-launched descendants are unsupported.', baselineMigrated: false, startedAt: now(), endedAt: null, status: 'not-run', platform: process.platform, nodeVersion: process.version, buildAttestation: null, sourceToAppMatch: 'not-established', source: null, app: null, blocker: null, scenarios: names.map(name => ({ scenario: `tests/e2e/${name}`, ...(group && { group }), status: 'not-run', reason: scenarioRestrictions[name.slice(0, -4)]?.reason ?? 'not-started' })) };
  if (coverage) report.coverage = { status: 'not-run', imported: 0, intervals: [] };
  let capture; let collector;
  async function save() { await writeFile(path + '.tmp', JSON.stringify(report, null, 2) + '\n', { mode: 0o600 }); await rename(path + '.tmp', path); }
  try {
    report.source = await sourceIdentity(sourceOptions);
    if (!names.length) throw new Error('no-scenarios');
    if (names.every(name => scenarioRestrictions[name.slice(0, -4)])) throw new Error('selected-scenarios-blocked');
    if (app) {
      try { report.app = await bundleIdentity(app); }
      catch (error) {
        if (error.message === 'app-signature-verification-failed') throw error;
        throw new Error('app-identity-unavailable');
      }
    }
    if (process.platform !== 'darwin') throw new Error('macos-required');
    if (!app) throw new Error('SCRIV_E2E_APP-required');
    if (coverage) {
      try {
        collector = await import('./collect-cli-coverage.mjs');
        capture = await collector.prepareCoverage({ app, output, sourceOptions, ...coverageOptions });
        report.coverage = capture.report;
        report.buildAttestation = { kind: 'producer-declared-coverage-build-record', sha256: capture.buildRecordSHA256, cryptographicallyAttested: false };
        report.sourceToAppMatch = capture.sourceProvenance.differences.length
          ? 'producer-declared-build-record-with-host-only-journey-delta' : 'producer-declared-build-record';
      } catch { throw new Error('coverage-preflight-failed'); }
    }
    await save();
    for (let i = 0; i < names.length; i++) {
      if (scenarioRestrictions[names[i].slice(0, -4)]) continue; // Never spawn or allocate capture for a denied route.
      const context = capture ? await collector.coverageContext(capture, `tests/e2e/${names[i]}`, i, group) : undefined;
      report.scenarios[i] = await runScenario(join(repo, 'tests/e2e', names[i]),
        { app, timeoutMs, coverageContext: context, startupCoverage: capture?.startup, group });
      await save();
      if (report.scenarios[i].status !== 'passed') {
        for (const remaining of report.scenarios.slice(i + 1)) if (remaining.reason === 'not-started') remaining.reason = 'stopped-after-failure';
        break;
      }
    }
    const after = await sourceIdentity(sourceOptions);
    report.sourceUnchanged = JSON.stringify(after) === JSON.stringify(report.source);
    report.appUnchanged = null;
    report.appUnchanged = JSON.stringify(await bundleIdentity(app)) === JSON.stringify(report.app);
    if (!report.sourceUnchanged || !report.appUnchanged) report.blocker = 'inputs-changed-during-run';
    if (names.some(name => scenarioRestrictions[name.slice(0, -4)])) report.blocker ??= 'selected-scenarios-blocked';
    report.status = !report.blocker && report.scenarios.every(s => s.status === 'passed') ? 'passed' : 'failed';
    if (capture && report.blocker) {
      capture.report.status = 'not-exported';
      capture.report.blocker = report.blocker;
    }
    if (capture && !report.blocker) {
      try {
        await collector.exportCoverage(capture, report.scenarios);
        report.sourceUnchanged = JSON.stringify(await sourceIdentity(sourceOptions)) === JSON.stringify(report.source);
        report.appUnchanged = null;
        report.appUnchanged = JSON.stringify(await bundleIdentity(app)) === JSON.stringify(report.app);
        if (!report.sourceUnchanged || !report.appUnchanged) throw new Error('inputs-changed-during-export');
        report.sourceCheckScope = 'through capture and LLVM export, before explicit measurement import';
      } catch (error) {
        if (error.message === 'app-signature-verification-failed') throw error;
        throw new Error('coverage-capture-or-export-failed');
      }
      await save();
      try { await collector.importCoverage(capture); }
      catch { throw new Error('coverage-import-failed'); }
      report.measurementWritesAfterSourceCheck = capture.report.imported;
    }
  } catch (error) {
    const safe = ['selected-scenarios-blocked', 'macos-required', 'SCRIV_E2E_APP-required', 'no-scenarios', 'app-identity-unavailable', 'app-signature-verification-failed', 'submodule-provenance-unsupported', 'coverage-preflight-failed', 'coverage-capture-or-export-failed', 'coverage-import-failed'];
    report.blocker = safe.includes(error.message) || /^source-manifest-(?:symlink|special-file|unsafe-path|missing-file|must-be-outside-source|digest-required|digest-mismatch|invalid|content-mismatch|file-set-mismatch)$/.test(error.message) ? error.message : 'evidence-or-preflight-failed';
    report.status = report.scenarios.some(s => s.startedAt) ? 'failed' : 'not-run';
    for (const item of report.scenarios) if (item.status === 'not-run' && item.reason === 'not-started') item.reason = report.blocker;
    if (capture) { report.coverage.failureStage = report.coverage.status; report.coverage.status = 'failed'; }
  }
  if (capture) {
    try { await collector.saveCoverageStatus(capture); }
    catch { report.blocker ??= 'coverage-evidence-save-failed'; report.status = 'failed'; }
  }
  report.fullSuitePassed = report.status === 'passed' && selection.mode === 'all';
  report.endedAt = now(); await save();
  console.log(`CLI E2E ${report.status} (${selection.mode} ${names.length}/${available.length}); evidence: ${path}`);
  return report.status === 'passed' ? 0 : report.status === 'not-run' ? 2 : 1;
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main().then(code => { process.exitCode = code; }).catch(() => { console.error('CLI E2E runner could not write evidence or accept its arguments.'); process.exitCode = 2; });
}
