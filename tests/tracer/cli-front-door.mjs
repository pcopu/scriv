#!/usr/bin/env node
/** Public Tracer subprocess journeys. No imported production implementation,
 * fake app, model substitute, native acceptance or baseline retirement. */
import assert from 'node:assert/strict';
import { assertServiceDiscovery } from './service-discovery.mjs';
import { spawnSync } from 'node:child_process';
import { mkdtemp, realpath, readFile, readdir, mkdir, writeFile, symlink, link, chmod } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { tmpdir } from 'node:os';
import { dirname, isAbsolute, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');

export async function main() {
  const configured = process.env.SCRIV_TRACER_CLI;
  if (configured && (!isAbsolute(configured) || /[\x00-\x1f\x7f]/.test(configured))) throw new Error('SCRIV_TRACER_CLI must be an absolute Tracer executable or .mjs entrypoint.');
  const executable = configured?.endsWith('.mjs') ? process.execPath : configured || 'tracer';
  const prefix = configured?.endsWith('.mjs') ? [configured] : [];
  const env = { ...process.env, TRACER_NO_UPDATE: '1', SCRIV_CLI_TOOLING_ACTIVE: '1' };
  delete env.SCRIV_E2E_APP; // This journey must never launch a supplied real app.
  delete env.SCRIV_E2E_COVERAGE_CONTEXT;
  const output = await realpath(await mkdtemp(join(tmpdir(), 'scriv-tracer-tooling-')));
  let passed = 0;
  const run = (args, expected = 0, environment = {}) => {
    const child = spawnSync(executable, [...prefix, ...args], { cwd: root, env: { ...env, ...environment }, encoding: 'utf8', timeout: 30000, maxBuffer: 1024 * 1024, shell: false });
    if (child.error) throw new Error(`Tracer could not run (${child.error.code ?? 'spawn-error'}). Install Tracer or set SCRIV_TRACER_CLI to its absolute entrypoint.`);
    assert.equal(child.signal, null);
    assert.equal(child.status, expected, child.stderr);
    return child;
  };
  const journey = async (name, work) => { await work(); passed++; console.log(`PASS Tracer CLI journey: ${name}`); };
  let catalog;
  await journey('discover the advertised native and tooling routes', () => {
    const actions = run(['actions']);
    assert.match(actions.stdout, /tracer app -- test --list/);
    assert.match(actions.stdout, /tracer app -- test tooling/);
    assert.equal(run(['app', '--', '--help']).stdout, actions.stdout);
    const help = run(['app', '--', 'test', '--help']).stdout;
    assert.ok(/No app, no macOS or failed provenance means not-run/.test(help) && /--coverage-build-record/.test(help));
  });
  await journey('list genuine native entrypoints without launching an app', async () => {
    catalog = JSON.parse(run(['app', '--', 'test', '--list']).stdout);
    assert.equal(catalog.kind, 'native-cli-scenario-catalog');
    const entrypoints = async directory => (await readdir(join(root, 'tests/e2e', directory), { withFileTypes: true }))
      .filter(entry => entry.isFile() && /^[A-Za-z0-9_-]+\.mjs$/.test(entry.name))
      .map(entry => `tests/e2e/${directory ? directory + '/' : ''}${entry.name}`);
    const expected = [...await entrypoints(''), ...await entrypoints('journeys')].sort();
    assert.deepEqual(catalog.scenarios.map(row => row.path), expected);
    assert.ok(expected.length > 0);
    assert.equal(catalog.selection.availableScenarioCount, expected.length);
    assert.equal(catalog.selection.selectedScenarioCount, expected.length);
    assert.equal(catalog.selection.mode, 'all');
    for (const row of catalog.scenarios) {
      assert.equal(row.path, `tests/e2e/${row.id}.mjs`);
      assert.ok(!row.path.includes('/support/') && !row.path.includes('/live-e2e/'));
    }
    const direct = spawnSync(process.execPath, ['scripts/run-cli-e2e.mjs', '--list'], { cwd: root, env, encoding: 'utf8', timeout: 30000 });
    assert.equal(direct.status, 0);
    assert.deepEqual(JSON.parse(direct.stdout), catalog);
  });
  await journey('select exact IDs in stable native-runner order', () => {
    const ids = [catalog.scenarios.at(-1).id, catalog.scenarios[0].id];
    const selected = JSON.parse(run(['app', '--', 'test', '--list', ...ids.flatMap(id => ['--scenario', id])]).stdout);
    assert.deepEqual(selected.scenarios.map(row => row.id), [...ids].sort());
    assert.equal(selected.selection.mode, 'subset');
    assert.equal(selected.selection.selectedScenarioCount, 2);
    assert.equal(selected.selection.availableScenarioCount, catalog.scenarios.length);
  });
  await journey('reject unsafe, unknown and ambiguous arguments before evidence creation', async () => {
    const id = catalog.scenarios[0].id;
    const traversal = run(['app', '--', 'test', '--scenario', '../outside'], 2);
    assert.equal(traversal.stdout, '');
    assert.match(traversal.stderr, /invalid-scenario-id/);
    for (const args of [
      ['--scenario', '../outside'], ['--scenario', '/tmp/outside'], ['--scenario', `${id}.mjs`],
      ['--scenario', 'unknown_scenario'], ['--scenario', '; touch NEVER'], ['--scenario', '$(touch NEVER)'],
      ['--scenario', 'line\nbreak'], ['--scenario', id, '--scenario', id], ['--scenario'],
      ['--timeout-ms', '99'], ['--timeout-ms', '3600001'], ['--timeout-ms', '1e3'],
      ['--timeout-ms', '120000', '--timeout-ms', '1000'], ['--timeout-ms', '--list'],
      ['--app'], ['--source-manifest', '/tmp/missing-source.json'], ['--source-manifest-sha256', 'a'.repeat(64)],
      ['--unknown'], ['--help', '--unknown'], ['--help', '--list'], ['--list'],
    ]) {
      run(['app', '--', 'test', '--output-dir', output, ...args], 2);
      assert.deepEqual(await readdir(output), []);
    }
    run(['app', '--', 'test', 'tooling', '--unknown'], 2);
  });
  await journey('report all native scenarios as not-run without a usable native environment', async () => {
    const result = run(['app', '--', 'test', '--output-dir', output], 2);
    assert.match(result.stdout, /CLI E2E not-run \(all /);
    const dirs = await readdir(output);
    assert.equal(dirs.length, 1);
    const evidence = JSON.parse(await readFile(join(output, dirs[0], 'evidence.json'), 'utf8'));
    assert.equal(evidence.kind, 'actual-app-cli-scenarios');
    assert.equal(evidence.status, 'not-run');
    assert.equal(evidence.blocker, process.platform === 'darwin' ? 'SCRIV_E2E_APP-required' : 'macos-required');
    assert.equal(evidence.fullSuitePassed, false);
    assert.equal(evidence.baselineMigrated, false);
    assert.equal(evidence.sourceToAppMatch, 'not-established');
    assert.equal(evidence.app, null);
    assert.equal(evidence.buildAttestation, null);
    assert.equal(evidence.source.mode, 'git-working-tree');
    assert.deepEqual(evidence.selection, catalog.selection);
    assert.deepEqual(evidence.scenarios.map(row => row.scenario), catalog.scenarios.map(row => row.path));
    assert.ok(evidence.scenarios.every(row => row.status === 'not-run' && !row.startedAt
      && row.reason === (catalog.scenarios.find(item => item.path === row.scenario).restriction?.reason ?? evidence.blocker)));
  });
  await journey('block the denied alias route before app or helper launch', async () => {
    const selected = JSON.parse(run(['app', '--', 'test', '--list', '--scenario', 'character-aliases']).stdout);
    const restriction = { status: 'blocked', reason: 'native-alert-route-library-validation-blocked',
      detail: 'Alias Add/Cancel has no verified UIKit action route. The AppKit fallback was denied by Library Validation and must not be retried.' };
    assert.deepEqual(selected.scenarios, [{ id: 'character-aliases', path: 'tests/e2e/character-aliases.mjs', restriction }]);
    const before = new Set(await readdir(output));
    const result = run(['app', '--', 'test', '--scenario', 'character-aliases', '--app', join(output, 'Absent.app'), '--output-dir', output], 2);
    assert.match(result.stdout, /CLI E2E not-run \(subset 1\//);
    const dirs = (await readdir(output)).filter(name => !before.has(name)); assert.equal(dirs.length, 1);
    const evidence = JSON.parse(await readFile(join(output, dirs[0], 'evidence.json'), 'utf8'));
    assert.equal(evidence.blocker, 'selected-scenarios-blocked'); assert.equal(evidence.status, 'not-run');
    assert.equal(evidence.fullSuitePassed, false); assert.equal(evidence.baselineMigrated, false);
    assert.equal(evidence.app, null); assert.equal(evidence.buildAttestation, null);
    assert.deepEqual(evidence.scenarios, [{ scenario: 'tests/e2e/character-aliases.mjs', status: 'not-run', reason: restriction.reason }]);
    const direct = spawnSync(process.execPath, ['tests/e2e/character-aliases.mjs'], { cwd: root,
      env: { ...env, SCRIV_E2E_APP: join(output, 'Absent.app') }, encoding: 'utf8', timeout: 30000 });
    assert.equal(direct.status, 2); assert.equal(direct.signal, null); assert.equal(direct.stdout, '');
    assert.deepEqual(JSON.parse(direct.stderr), { scenario: 'character-aliases', ...restriction, nativeLaunched: false });
    const mixed = run(['app', '--', 'test', '--list', '--scenario', 'character-aliases', '--scenario', 'journeys/short-film']);
    const rows = JSON.parse(mixed.stdout).scenarios;
    assert.equal(rows.length, 2); assert.deepEqual(rows[0].restriction, restriction); assert.equal(rows[1].restriction, undefined);
    const beforeMixed = new Set(await readdir(output));
    run(['app', '--', 'test', '--scenario', 'character-aliases', '--scenario', 'journeys/short-film',
      '--app', join(output, 'Absent.app'), '--output-dir', output], 2);
    const mixedDirs = (await readdir(output)).filter(name => !beforeMixed.has(name)); assert.equal(mixedDirs.length, 1);
    const mixedEvidence = JSON.parse(await readFile(join(output, mixedDirs[0], 'evidence.json'), 'utf8'));
    assert.equal(mixedEvidence.fullSuitePassed, false); assert.equal(mixedEvidence.app, null);
    assert.deepEqual(mixedEvidence.scenarios, [
      { scenario: 'tests/e2e/character-aliases.mjs', status: 'not-run', reason: restriction.reason },
      { scenario: 'tests/e2e/journeys/short-film.mjs', status: 'not-run', reason: 'app-identity-unavailable' },
    ]);
  });
  await journey('keep a subset distinct from a complete native-suite pass', async () => {
    const id = catalog.scenarios.find(row => !row.restriction).id;
    const before = new Set(await readdir(output));
    const result = run(['app', '--', 'test', '--scenario', id, '--output-dir', output], 2);
    assert.match(result.stdout, /CLI E2E not-run \(subset 1\//);
    const dirs = (await readdir(output)).filter(name => !before.has(name));
    assert.equal(dirs.length, 1);
    const evidence = JSON.parse(await readFile(join(output, dirs[0], 'evidence.json'), 'utf8'));
    assert.equal(evidence.selection.mode, 'subset');
    assert.equal(evidence.selection.selectedScenarioCount, 1);
    assert.equal(evidence.selection.availableScenarioCount, catalog.scenarios.length);
    assert.equal(evidence.fullSuitePassed, false);
    assert.deepEqual(evidence.scenarios, [{ scenario: `tests/e2e/${id}.mjs`, status: 'not-run', reason: process.platform === 'darwin' ? 'SCRIV_E2E_APP-required' : 'macos-required' }]);
  });
  await journey('preserve legacy help and failed-launch routing; native JSON round trips remain unverified', () => {
    const help = spawnSync(process.execPath, ['cli/scriv.mjs', '--help'], { cwd: root, env, encoding: 'utf8', timeout: 30000 });
    assert.equal(help.status, 0);
    assert.match(help.stdout, /JSON-line control/);
    assert.match(help.stdout, /node cli\/scriv.mjs \/path\/to\/ScrivAutomation.app/);
    // A deliberately absent path cannot launch an app on any platform.
    for (const app of [join(output, 'NotPresent.app'), join(output, 'NotPresent.app') + '/', join(output, 'NotPresentAlias')]) {
      const viaTracer = run(['app', '--', app], 1);
      const direct = spawnSync(process.execPath, ['cli/scriv.mjs', app], { cwd: root, env, encoding: 'utf8', timeout: 30000 });
      assert.equal(direct.status, viaTracer.status);
      assert.equal(direct.stderr, viaTracer.stderr);
      assert.doesNotMatch(viaTracer.stderr, /Expected an automation app path/);
    }
  });
  await journey('refuse recursive tooling execution instead of testing the tester forever', () => {
    const result = run(['app', '--', 'test', 'tooling'], 2);
    assert.match(result.stderr, /nested-tooling-journey-refused/);
    assert.doesNotMatch(result.stdout, /PASS \d+\/\d+ public Tracer CLI journeys/);
    assert.ok(result.stderr.length > 0);
  });
  await journey('reject unpinned or unbounded coverage requests before a native launch', () => {
    for (const args of [
      ['--coverage'], ['--coverage', '--scenario', 'workspace'],
      ['--coverage-build-record', '/tmp/missing-build.json'],
      ['--coverage', '--coverage-max-sessions', '0'], ['--coverage', '--coverage-max-sessions', '65'],
      ['--llvm-cov', 'relative-tool'], ['--coverage-max-sessions', '1'],
    ]) {
      const result = run(['app', '--', 'test', ...args], 2);
      assert.equal(result.stdout, '');
      assert.ok(result.stderr.length > 0);
    }
  });
  await journey('exercise coverage builder discovery and required provenance arguments', () => {
    const build = args => spawnSync('python3', ['scripts/rebuild-catalyst-cli.py', ...args], { cwd: root, env, encoding: 'utf8', timeout: 30000 });
    const help = build(['--help']); assert.equal(help.status, 0);
    assert.match(help.stdout, /--coverage-source-manifest-sha256/);
    assert.match(help.stdout, /--coverage-build-record/);
    // Invalid argument combinations must stop before template/toolchain access.
    const base = ['--sparkle-framework', join(output, 'Sparkle.framework'), '--template', join(output, 'AbsentTemplate.app'), '--output', join(output, 'AbsentOutput.app'), '--work', join(output, 'AbsentWork'), '--identity', 'unused', '--version', '1', '--build', '1'];
    for (const args of [['--automation', '--coverage'], ['--coverage-source-manifest', join(output, 'AbsentSource.json')]]) {
      const result = build([...base, ...args]);
      assert.equal(result.status, 2);
      assert.match(result.stderr, args.includes('--coverage') ? /--coverage requires --coverage-source-manifest, --coverage-source-manifest-sha256 and --coverage-build-record together/ : /Coverage source manifest, digest and build record require --coverage/);
    }
  });
  await journey('keep a pinned coverage request explicitly not-run without a native environment', async () => {
    const git = spawnSync('git', ['ls-files', '--others', '--exclude-standard', '-z'], { cwd: root, env, encoding: 'utf8', timeout: 30000 });
    assert.equal(git.status, 0);
    const includes = git.stdout.split('\0').filter(path => path && !path.split('/').includes('__pycache__') && path !== 'cloud/.dev.vars.example');
    const manifest = join(output, 'source.json');
    const exported = spawnSync(process.execPath, ['scripts/export-cli-source-manifest.mjs', '--output', manifest,
      ...includes.flatMap(path => ['--include', path])], { cwd: root, env, encoding: 'utf8', timeout: 30000, maxBuffer: 1024 * 1024 });
    assert.equal(exported.status, 0, exported.stderr);
    const digest = JSON.parse(exported.stdout).manifestSHA256;
    const before = new Set(await readdir(output));
    const result = run(['app', '--', 'test', '--coverage', '--scenario', 'workspace', '--source-manifest', manifest,
      '--source-manifest-sha256', digest, '--coverage-build-record', join(output, 'AbsentBuildRecord.json'), '--output-dir', output], 2);
    assert.match(result.stdout, /CLI E2E not-run \(subset 1\//);
    const dirs = (await readdir(output)).filter(name => !before.has(name)); assert.equal(dirs.length, 1);
    const evidence = JSON.parse(await readFile(join(output, dirs[0], 'evidence.json'), 'utf8'));
    assert.equal(evidence.status, 'not-run');
    assert.equal(evidence.blocker, process.platform === 'darwin' ? 'SCRIV_E2E_APP-required' : 'macos-required');
    assert.equal(evidence.source.mode, 'verified-exported-source-manifest');
    assert.equal(evidence.coverage.status, 'not-run'); assert.equal(evidence.coverage.imported, 0);
    assert.deepEqual(evidence.coverage.intervals, []);
    assert.equal(evidence.buildAttestation, null);
    assert.deepEqual(await readdir(join(output, dirs[0])), ['evidence.json']);
  });
  await journey('discover fixed local service routes and refuse arbitrary targets', () => assertServiceDiscovery(run));
  await journey('run the npm Tracer wrapper and propagate setup failures', () => {
    const wrapper = environment => spawnSync(process.execPath, ['scripts/tracer-cli.mjs', 'actions'], {
      cwd: root, env: { ...env, ...environment }, encoding: 'utf8', timeout: 30000,
    });
    const success = wrapper({});
    assert.equal(success.status, 0, success.stderr);
    assert.equal(success.stdout, run(['actions']).stdout);
    const relative = wrapper({ SCRIV_TRACER_CLI: 'relative-tool' });
    assert.equal(relative.status, 2);
    assert.match(relative.stderr, /must be an absolute/);
    const missing = wrapper({ SCRIV_TRACER_CLI: join(output, 'NotPresentTracer') });
    assert.equal(missing.status, 2);
    assert.match(missing.stderr, /Tracer could not start/);
  });
  await journey('inspect owned filesystem fixtures without granting path-based resume or changing data', async () => {
    async function fixture({ markerMode = 0o600, markerText, missingLock = false, rootMode = 0o700 } = {}) {
      const id = randomUUID(), directory = join(output, `ScrivVerification-CLI-${id}`);
      await mkdir(directory, { mode: 0o700 });
      await writeFile(join(directory, '.scriv-cli-persistent'), markerText ?? `ScrivCLIWorkspace-v1\n${id}\n`, { mode: markerMode, flag: 'wx' });
      if (!missingLock) await writeFile(join(directory, '.scriv-cli-session.lock'), '', { mode: 0o600, flag: 'wx' });
      await writeFile(join(directory, 'synthetic-sentinel.txt'), 'Preserve this synthetic fixture exactly.\n', { mode: 0o600, flag: 'wx' });
      if (rootMode !== 0o700) await chmod(directory, rootMode); // Only this newly created synthetic negative-case directory.
      return directory;
    }
    const valid = await fixture();
    const beforeNames = await readdir(valid), before = await Promise.all(beforeNames.map(name => readFile(join(valid, name))));
    const inspected = JSON.parse(run(['app', '--', 'workspace', 'inspect', valid]).stdout);
    assert.deepEqual(inspected, { kind: 'owned-synthetic-workspace-inspection', hostOwnership: 'valid',
      nativeDescendantsAndLock: 'not-validated', retainedProcessLease: false, resumeAuthorized: false });
    assert.deepEqual(await readdir(valid), beforeNames);
    assert.deepEqual(await Promise.all(beforeNames.map(name => readFile(join(valid, name)))), before);
    const symbolic = join(output, `ScrivVerification-CLI-${randomUUID()}`); await symlink(valid, symbolic);
    const parentAlias = join(output, 'parent-alias'); await symlink(output, parentAlias);
    const ancestorSymbolic = join(parentAlias, valid.slice(output.length + 1));
    const hardLinked = await fixture(); await link(join(hardLinked, '.scriv-cli-persistent'), join(output, 'marker-alias'));
    const unsafe = [symbolic, ancestorSymbolic, hardLinked, await fixture({ markerMode: 0o400 }), await fixture({ markerText: 'not an ownership marker\n' }),
      await fixture({ missingLock: true }), await fixture({ rootMode: 0o755 }), join(output, 'NotOwned'), '../outside'];
    for (const directory of unsafe) {
      const rejected = run(['app', '--', 'workspace', 'inspect', directory], 1);
      assert.equal(rejected.stdout, ''); assert.match(rejected.stderr, /owned-workspace-unavailable/);
    }
    for (const action of ['resume', 'reset', 'delete']) {
      const rejected = run(['app', '--', 'workspace', action, valid], 1);
      assert.match(rejected.stderr, /path-based resume is unavailable/);
    }
    assert.deepEqual(await Promise.all(beforeNames.map(name => readFile(join(valid, name)))), before);
  });
  await journey('keep private Tracer audit storage out of source exports', async () => {
    const manifest = join(output, 'private-audit-source.json');
    const rejected = spawnSync(process.execPath, ['scripts/export-cli-source-manifest.mjs', '--output', manifest, '--include', '.tracer'], { cwd: root, env, encoding: 'utf8', timeout: 30000 });
    assert.equal(rejected.status, 2);
    assert.match(rejected.stderr, /Source manifest export failed/);
    assert.ok(!(await readdir(output)).includes('private-audit-source.json'));
    // The successful pinned-source journey above verifies the current eligible
    // tree while a real supervised audit queue exists outside application source.
  });
  await journey('refuse malformed and nested provenance dispatch before running a fixture', () => {
    for (const [extra, active] of [[['extra'], '0'], [[], '1']]) {
      const rejected = run(['app', '--', 'test', 'provenance', ...extra], 2, { SCRIV_CLI_TOOLING_ACTIVE: active });
      assert.equal(rejected.stdout, '');
      assert.equal(rejected.stderr, 'Invalid or nested provenance journey\n');
    }
  });
  if (process.platform === 'darwin') await journey('reject an unsigned non-executable bundle before starting a native scenario', async () => {
    // This fixture cannot execute, including against the old unguarded runner.
    // The journey asserts prelaunch rejection and establishes no native acceptance.
    const fixture = await realpath(await mkdtemp(join(tmpdir(), 'scriv-unsigned-bundle-')));
    const app = join(fixture, 'Unsigned.app');
    const executable = join(app, 'Contents/MacOS/Scriv');
    const sentinel = 'Synthetic unsigned non-executable fixture.\n';
    await mkdir(dirname(executable), { recursive: true });
    await writeFile(executable, sentinel, { mode: 0o600, flag: 'wx' });
    await chmod(executable, 0o600);
    assert.ok(catalog.scenarios.some(row => row.id === 'workspace' && !row.restriction));
    const before = new Set(await readdir(output));
    const result = run(['app', '--', 'test', '--scenario', 'workspace', '--app', app, '--output-dir', output], 2);
    assert.equal(result.stderr, '');
    const dirs = (await readdir(output)).filter(name => !before.has(name));
    assert.equal(dirs.length, 1);
    const evidence = JSON.parse(await readFile(join(output, dirs[0], 'evidence.json'), 'utf8'));
    assert.equal(evidence.status, 'not-run');
    assert.equal(evidence.blocker, 'app-signature-verification-failed');
    assert.equal(evidence.app, null);
    assert.equal(evidence.appUnchanged, undefined);
    assert.equal(evidence.fullSuitePassed, false);
    assert.equal(evidence.baselineMigrated, false);
    assert.equal(evidence.sourceToAppMatch, 'not-established');
    assert.equal(evidence.buildAttestation, null);
    assert.deepEqual(evidence.scenarios, [{ scenario: 'tests/e2e/workspace.mjs', status: 'not-run', reason: 'app-signature-verification-failed' }]);
    assert.equal(await readFile(executable, 'utf8'), sentinel);
    assert.deepEqual(await readdir(join(output, dirs[0])), ['evidence.json']);
    assert.equal(result.stdout.includes(sentinel.trim()), false);
  });
  console.log(`PASS ${passed}/${passed} public Tracer CLI journeys. Native scenarios executed: 0; tooling artifacts: ${output}`);
  return 0;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) main().then(code => { process.exitCode = code; }).catch(error => { console.error(error.message); process.exitCode = 1; });
