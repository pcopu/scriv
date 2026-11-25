#!/usr/bin/env node
/** Public Tracer subprocess journeys. No imported production implementation,
 * fake app, model substitute, native acceptance or baseline retirement. */
import assert from 'node:assert/strict';
import { assertServiceDiscovery } from './service-discovery.mjs';
import { runStorageInputsJourney } from './storage-inputs-journey.mjs';
import { runStorageMeasureJourney } from './storage-measure-journey.mjs';
import { runStorageRetentionJourney } from './storage-retention-journey.mjs';
import { spawnSync } from 'node:child_process';
import { mkdtemp, realpath, readFile, readdir, mkdir, writeFile, symlink, link, chmod, lstat, rm } from 'node:fs/promises';
import { createHash, randomUUID } from 'node:crypto';
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
    const storage = args[0] === 'app' && args[1] === '--' && args[2] === 'test' && args[3] === 'storage';
    const child = spawnSync(executable, [...prefix, ...args], { cwd: root, env: { ...env, ...environment }, encoding: 'utf8',
      timeout: storage ? 120000 : 30000, maxBuffer: storage ? 16 * 1024 * 1024 : 1024 * 1024, shell: false });
    if (child.error) throw new Error(`Tracer could not run (${child.error.code ?? 'spawn-error'}). Install Tracer or set SCRIV_TRACER_CLI to its absolute entrypoint.`);
    assert.equal(child.signal, null);
    assert.equal(child.status, expected, child.stderr);
    return child;
  };
  const journey = async (name, work) => { await work(); passed++; console.log(`PASS Tracer CLI journey: ${name}`); };
  // Storage verification pins the actual package, even when the public entry
  // was a managed launcher or an npm/PATH symlink. Discovery never updates it.
  const immutableTracer = async () => {
    const candidates = configured ? [configured]
      : (process.env.PATH ?? '').split(':').filter(Boolean).map(path => resolve(path, 'tracer'));
    for (const candidate of candidates) {
      const canonical = await realpath(candidate).catch(() => null);
      if (canonical?.endsWith('/bin/tracer.mjs')) return canonical;
    }
    const status = JSON.parse(run(['update', '--status', '--json']).stdout);
    if (status.runningManaged && isAbsolute(status.home) && /^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(status.current)) {
      const path = join(status.home, 'releases', status.current, 'bin/tracer.mjs');
      if (await realpath(path) === path) return path;
    }
    throw new Error('Storage tooling requires the immutable Tracer package bin/tracer.mjs; set SCRIV_TRACER_CLI to that entrypoint.');
  };
  let catalog;
  await journey('discover the advertised native and tooling routes', () => {
    const actions = run(['actions']);
    assert.match(actions.stdout, /tracer app -- test --list/);
    assert.match(actions.stdout, /tracer app -- test tooling/);
    assert.match(actions.stdout, /tracer app -- test compact --archive/);
    assert.match(actions.stdout, /tracer app -- test storage init/);
    assert.match(actions.stdout, /--fresh-startup/);
    assert.match(actions.stdout, /--startup-trace/);
    assert.match(actions.stdout, /"command":"relaunch-recover"/);
    assert.equal(run(['app', '--', '--help']).stdout, actions.stdout);
    const help = run(['app', '--', 'test', '--help']).stdout;
    assert.match(help, /--coverage-activate CONTROL_ID/);
    assert.match(help, /--keep-indexed-profiles/);
    assert.ok(/No app, no macOS or failed provenance means not-run/.test(help) && /--coverage-build-record/.test(help) && /--coverage-startup/.test(help));
  });
  await journey('list genuine native entrypoints without launching an app', async () => {
    catalog = JSON.parse(run(['app', '--', 'test', '--list']).stdout);
    assert.equal(catalog.kind, 'native-cli-scenario-catalog');
    assert.deepEqual(catalog.launchModes, ['--persistent-workspace', '--fresh-startup', '--startup-trace']);
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
    const audio = catalog.scenarios.find(row => row.id === 'journeys/audio-library');
    assert.deepEqual(audio.groups, ['import', 'mix', 'timing', 'attachment', 'attachment-direction', 'timing-source-shrink', 'timing-boundaries']);
    const pictures = catalog.scenarios.find(row => row.id === 'journeys/picture-coverage');
    assert.deepEqual(pictures.groupWitnessPaths.follow, ['tests/e2e/journeys/support/picture-follow-steps.mjs']);
    assert.deepEqual(pictures.groupWitnessPaths['empty-storyboard'], ['tests/e2e/journeys/support/empty-storyboard.mjs']);
    const structure = catalog.scenarios.find(row => row.id === 'journeys/script-structure');
    assert.deepEqual(structure.groupWitnessPaths['owned-duration-dialog'], ['tests/e2e/journeys/support/script-owned-duration-steps.mjs']);
    const direct = spawnSync(process.execPath, ['scripts/run-cli-e2e.mjs', '--list'], { cwd: root, env, encoding: 'utf8', timeout: 30000 });
    assert.equal(direct.status, 0);
    assert.deepEqual(JSON.parse(direct.stdout), catalog);
  });
  await journey('compact archived coverage maps and reports without changing readable evidence', async () => {
    const archive = join(output, 'archive');
    const snapshot = join(archive, 'batch', 'source');
    const maps = join(snapshot, 'docs', 'testing');
    await mkdir(maps, { recursive: true, mode: 0o700 });
    await writeFile(join(snapshot, 'package.json'), '{"name":"scriv"}');
    await writeFile(join(snapshot, 'tracer.json'), '{}');
    const bytes = Buffer.from(JSON.stringify({ observations: 'a retained source assertion\n'.repeat(24000) }));
    const map = join(maps, 'code-e2e-links.json');
    const report = join(archive, 'batch', 'gap-series-report.json');
    const reportBytes = Buffer.from(JSON.stringify({
      kind: 'lcov-reference-gap-series',
      series: [],
      reports: [],
      notice: 'a retained measurement result\n'.repeat(16000),
    }));
    const outside = join(output, 'outside.json');
    await writeFile(map, bytes, { mode: 0o600 });
    await writeFile(report, reportBytes, { mode: 0o600 });
    await writeFile(join(archive, 'unrelated-report.json'), bytes);
    await writeFile(join(archive, 'incomplete-report.json'), reportBytes.subarray(0, reportBytes.length - 1));
    await writeFile(outside, bytes);
    await symlink(outside, join(maps, 'assertion-journey-map-native.json'));
    await symlink(snapshot, join(archive, 'linked-snapshot'));
    await link(outside, join(maps, 'assertion-journey-map-services.json'));
    await writeFile(join(maps, 'unrelated.json'), bytes);
    const artifacts = [[map, bytes], [report, reportBytes]];
    const before = await Promise.all(artifacts.map(([path]) => lstat(path)));
    const args = ['app', '--', 'test', 'compact', '--archive', archive];
    const preview = JSON.parse(run(args).stdout);
    assert.equal(preview.mode, 'preview');
    assert.deepEqual(preview.candidates, ['batch/gap-series-report.json', 'batch/source/docs/testing/code-e2e-links.json']);
    assert.equal(preview.filesCompacted, 0);
    assert.equal((await lstat(report)).ino, before[1].ino);
    run(['app', '--', 'test', 'compact', '--archive', root, '--apply'], 2);
    run([...args, '--archive', archive], 2);
    if (process.platform === 'darwin') {
      const applied = JSON.parse(run([...args, '--apply']).stdout);
      assert.equal(applied.mode, 'apply');
      const after = await Promise.all(artifacts.map(async ([path, contents], index) => {
        const stat = await lstat(path);
        assert.equal(stat.mode, before[index].mode);
        assert.equal(Math.trunc(stat.mtimeMs), Math.trunc(before[index].mtimeMs));
        assert.deepEqual(await readFile(path), contents);
        return (before[index].blocks - stat.blocks) * 512;
      }));
      assert.equal(applied.filesCompacted, after.filter(saved => saved > 0).length);
      assert.equal(applied.allocatedBytesSaved, after.reduce((sum, saved) => sum + saved, 0));
      assert.deepEqual(await readFile(outside), bytes);
      assert.equal(JSON.parse(run([...args, '--apply']).stdout).filesCompacted, 0);
    } else run([...args, '--apply'], 2);
    await rm(archive, { recursive: true });
    await rm(outside);
  });
  await journey('select exact IDs in stable native-runner order', () => {
    const ids = [catalog.scenarios.at(-1).id, catalog.scenarios[0].id];
    const selected = JSON.parse(run(['app', '--', 'test', '--list', ...ids.flatMap(id => ['--scenario', id])]).stdout);
    assert.deepEqual(selected.scenarios.map(row => row.id), [...ids].sort());
    assert.equal(selected.selection.mode, 'subset');
    assert.equal(selected.selection.selectedScenarioCount, 2);
    assert.equal(selected.selection.availableScenarioCount, catalog.scenarios.length);
  });
  await journey('discover and select one supported native journey group', async () => {
    const prefix = ['app', '--', 'test'];
    const scenario = 'journeys/script-authoring-source', group = 'retime-edited-words';
    const selected = JSON.parse(run([...prefix, '--list', '--scenario', scenario]).stdout);
    assert.deepEqual(selected.scenarios[0].groups, ['write-exact-source', 'return-boundary',
      'whitespace-word-preservation', 'exact-split', group]);
    for (const args of [
      ['--group', group], ['--scenario', scenario, '--group', 'unknown'],
      ['--scenario', scenario, '--group', '../outside'],
      ['--scenario', 'workspace', '--group', group],
      ['--scenario', scenario, '--scenario', 'workspace', '--group', group],
      ['--list', '--scenario', scenario, '--group', group],
    ]) assert.equal(run([...prefix, ...args], 2).stdout, '');
    const groupOutput = await realpath(await mkdtemp(join(tmpdir(), 'scriv-tracer-group-')));
    const notRun = run([...prefix, '--scenario', scenario, '--group', group, '--output-dir', groupOutput], 2);
    const path = notRun.stdout.match(/; evidence: (.+)\n$/)?.[1];
    assert.ok(path);
    const receipt = JSON.parse(await readFile(path, 'utf8'));
    assert.equal(receipt.selection.group, group);
    assert.equal(receipt.scenarios[0].group, group);
    assert.equal(receipt.status, 'not-run');
    assert.equal(receipt.fullSuitePassed, false);
  });
  await journey('discover the discussion attachment and cloud lease cases', async () => {
    const scenario = 'journeys/native-cloud-project-sync';
    const { scenarios: [entry] } = JSON.parse(run(['app', '--', 'test', '--list', '--scenario', scenario]).stdout);
    const discussionAndLeases = Object.entries(entry.groupActions).filter(([name]) => name === 'sync' || name.startsWith('lease-'));
    assert.deepEqual(discussionAndLeases.map(([name, [action]]) =>
      [name, action.id, action.command, action.trigger, action.condition]), [
      ['sync', 'attach-discussion-item', 'menu-action', 'discussion-attachment', 'selected-dialogue-attaches-once'],
      ['lease-renewal', 'edit-line', 'key', 'Command-Return', 'lease-available'],
      ['lease-contention', 'edit-line', 'key', 'Command-Return', 'lease-held-by-peer'],
    ]);
    for (const [group, [action]] of discussionAndLeases) {
      assert.ok(entry.groups.includes(group));
      const { path, start, end, sha256 } = action.entryPoint;
      assert.equal(path, 'apps/mac/Sources/ScrivApp/Services/WorkspaceStore.swift');
      assert.deepEqual([start, end], group === 'sync' ? [2491, 2495] : [1069, 1088]);
      const lines = (await readFile(join(root, path), 'utf8')).split(/(?<=\n)/);
      assert.equal(sha256, createHash('sha256').update(lines.slice(start - 1, end).join('')).digest('hex'));
    }
  });
  await journey('select multiple named cases in explicit order without launching a native app', async () => {
    const scenario = 'journeys/script-authoring-source';
    const groups = ['retime-edited-words', 'write-exact-source'];
    const selectors = groups.flatMap(group => ['--case', `${scenario}#${group}`]);
    const prefix = ['app', '--', 'test'];
    const output = await realpath(await mkdtemp(join(tmpdir(), 'scriv-tracer-case-batch-')));
    for (const flags of [
      ['--case', `${scenario}#unknown`], ['--case', '../outside#case'], ['--case', `${scenario}#`],
      [selectors[0], selectors[1], selectors[0], selectors[1]],
      [...selectors, '--scenario', scenario], [...selectors, '--group', groups[0]], [...selectors, '--list'],
    ]) {
      assert.equal(run([...prefix, ...flags, '--output-dir', output], 2).stdout, '');
      assert.deepEqual(await readdir(output), []);
    }
    const result = run([...prefix, ...selectors, '--output-dir', output], 2);
    const path = result.stdout.match(/; evidence: (.+)\n$/)?.[1];
    assert.ok(path);
    const evidence = JSON.parse(await readFile(path, 'utf8'));
    const cases = groups.map(group => ({ scenario: `tests/e2e/${scenario}.mjs`, group }));
    assert.deepEqual(evidence.selection.cases, cases);
    assert.equal(evidence.selection.selectedScenarioCount, 2);
    assert.equal(evidence.selection.mode, 'subset');
    assert.deepEqual(evidence.scenarios.map(({ scenario, group, status }) => ({ scenario, group, status })),
      cases.map(row => ({ ...row, status: 'not-run' })));
    assert.equal(evidence.fullSuitePassed, false);
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
      ['--llvm-cov', 'relative-tool'], ['--coverage-max-sessions', '1'], ['--coverage-startup'], ['--coverage-activate', 'cancel'],
      ['--keep-indexed-profiles'],
    ]) {
      const result = run(['app', '--', 'test', ...args], 2);
      assert.equal(result.stdout, '');
      assert.ok(result.stderr.length > 0);
    }
    assert.match(run(['app', '--', 'test', '--coverage-activate', '0.2'], 2).stderr, /coverage-activate-requires-control-identifier/);
    const pinned = ['--coverage', '--coverage-activate', 'cancel', '--scenario', 'workspace',
      '--source-manifest', '/tmp/missing-source.json', '--source-manifest-sha256', '0'.repeat(64),
      '--coverage-build-record', '/tmp/missing-build.json'];
    for (const options of [['--coverage-startup'], ['--scenario', 'second'], ['--coverage-max-sessions', '2']]) {
      assert.match(run(['app', '--', 'test', ...pinned, ...options], 2).stderr, /coverage-activate-requires-one-scenario-and-session/);
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
  if (process.platform === 'darwin') await journey('export exact Swift call sites from pinned sources', async () => {
    const sourceRoot = join(output, 'compiler-call-source');
    const core = 'apps/mac/Sources/ScrivCore/Recovery.swift', app = 'apps/catalyst/ScrivUIKit/Entry.swift';
    const header = 'apps/catalyst/CLIInstrumentation/ScrivCLICoverageBridge.h';
    const content = {
      [core]: 'public func productionRecovery() -> Int {\n    return 42\n}\n',
      [app]: 'import ScrivCore\nfunc action() -> Int {\n    return productionRecovery()\n}\n',
      [header]: '// Synthetic automation bridge.\n',
    };
    const hash = bytes => createHash('sha256').update(bytes).digest('hex');
    for (const [path, bytes] of Object.entries(content)) {
      await mkdir(dirname(join(sourceRoot, path)), { recursive: true });
      await writeFile(join(sourceRoot, path), bytes);
    }
    const files = Object.keys(content).sort().map(path => ({ path, sha256: hash(content[path]) }));
    const manifest = JSON.stringify({ schemaVersion: 1, kind: 'scriv-exported-source',
      baseCommit: '0'.repeat(40), files });
    const sourceManifest = join(output, 'compiler-call-source.json'), functions = join(output, 'compiler-functions.json');
    await writeFile(sourceManifest, manifest);
    const inputMap = { version: 1, kind: 'llvm-function-map', buildSha256: '1'.repeat(64),
      sourceManifestSha256: hash(manifest), files: files.filter(row => row.path.endsWith('.swift')).map(row => ({
        ...row, ranges: row.path === app ? [[2, 4]] : [[1, 3]],
      })) };
    await writeFile(functions, JSON.stringify(inputMap));
    const args = ['scripts/export-cli-call-map.py', '--source-root', sourceRoot, '--source-manifest', sourceManifest,
      '--functions', functions, '--scratch-directory', output];
    const compile = () => spawnSync('python3', args, { cwd: root, env, encoding: 'utf8', timeout: 120000 });
    const result = compile();
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(JSON.parse(result.stdout), { ...inputMap, calls: [
      { caller: { path: app, line: 3 }, callee: { path: core, start: 1, end: 3 } },
    ] });
    await writeFile(join(sourceRoot, core), content[core].replace('42', '43'));
    const stale = compile();
    assert.equal(stale.status, 2);
    assert.match(stale.stderr, /compiler call map.*pinned source/i);
    assert.equal(stale.stdout, '');
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
    const result = run(['app', '--', 'test', '--coverage', '--coverage-startup', '--scenario', 'workspace', '--source-manifest', manifest,
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
  await journey('record a typed scenario failure without publishing the error text', async () => {
    const root = join(output, 'diagnostic-probe', 'tests/e2e');
    const support = join(root, 'support');
    await mkdir(support, { recursive: true });
    const producer = join(support, 'scenario-diagnostic.mjs');
    await writeFile(producer, await readFile(new URL('../e2e/support/scenario-diagnostic.mjs', import.meta.url)));
    const scenario = join(root, 'diagnostic-probe.mjs');
    await writeFile(scenario, `const cause = Object.assign(new Error('fixture-only error text'), { code: 'SCRIV_UI_TARGET_AMBIGUOUS', matches: 2 });
throw new Error('wrapper-only error text', { cause });
`);
    const child = spawnSync(process.execPath, ['--import', producer, scenario], {
      env: { ...env, SCRIV_E2E_DIAGNOSTIC_FD: '3' }, encoding: 'utf8', timeout: 5000, maxBuffer: 8192,
      stdio: ['ignore', 'pipe', 'pipe', 'pipe'],
    });
    assert.ifError(child.error);
    assert.equal(child.status, 1);
    assert.deepEqual(JSON.parse(child.output[3]), {
      code: 'ui-target-ambiguous', matches: 2, location: { path: 'tests/e2e/diagnostic-probe.mjs', line: 1 },
    });
    const helper = join(support, 'probe-helper.mjs');
    await writeFile(helper, "export function checkTarget() { throw Object.assign(new Error('private helper message'), { code: 'SCRIV_UI_WAIT_TIMEOUT' }); }\n");
    await writeFile(scenario, "import { checkTarget } from './support/probe-helper.mjs';\ntry { checkTarget(); } catch (cause) { throw new Error('private outer message', { cause }); }\n");
    const nested = spawnSync(process.execPath, ['--import', producer, scenario], {
      env: { ...env, SCRIV_E2E_DIAGNOSTIC_FD: '3' }, encoding: 'utf8', timeout: 5000, maxBuffer: 8192,
      stdio: ['ignore', 'pipe', 'pipe', 'pipe'],
    });
    assert.ifError(nested.error);
    assert.equal(nested.status, 1);
    assert.deepEqual(JSON.parse(nested.output[3]), {
      code: 'ui-wait-timeout', location: { path: 'tests/e2e/support/probe-helper.mjs', line: 1 },
    });

  });
  await journey('compact only finished native profiles with exact export digests', async () => {
    const archive = join(output, 'profile-archive');
    const bytes = Buffer.from('retained raw counters\n'.repeat(12000));
    const runID = '3aadae12-851a-4981-838e-8cef5f319f93';
    const capture = join(archive, 'scriv-cli-e2e-sample', 'coverage');
    const session = join(capture, 'sessions', runID);
    const rawProfile = join(session, 'before.profraw');
    const staleProfile = join(session, 'after.profraw');
    const profileHash = createHash('sha256').update(bytes).digest('hex');
    await mkdir(session, { recursive: true });
    await writeFile(join(capture, 'capture.json'), JSON.stringify({
      status: 'imported', intervals: [{ runID, imported: true, status: 'imported' }],
    }));
    await writeFile(join(session, 'import.json'), JSON.stringify({ id: 'a'.repeat(64) }));
    await writeFile(join(session, 'exports.json'), JSON.stringify({
      before: { rawSHA256: profileHash }, after: { rawSHA256: 'b'.repeat(64) },
    }));
    await writeFile(rawProfile, bytes);
    await writeFile(staleProfile, bytes);
    const rawBefore = await lstat(rawProfile);
    const staleBefore = await lstat(staleProfile);
    const rawCandidate = 'scriv-cli-e2e-sample/coverage/sessions/' + runID + '/before.profraw';
    const args = ['app', '--', 'test', 'compact', '--archive', archive];
    const preview = JSON.parse(run(args).stdout);
    assert.deepEqual(preview.candidates, [rawCandidate]);
    assert.equal((await lstat(rawProfile)).ino, rawBefore.ino);
    if (process.platform === 'darwin') {
      const applied = JSON.parse(run([...args, '--apply']).stdout);
      const after = await lstat(rawProfile);
      assert.equal(applied.allocatedBytesSaved, (rawBefore.blocks - after.blocks) * 512);
      assert.equal(after.mode, rawBefore.mode);
      assert.deepEqual(await readFile(rawProfile), bytes);
      assert.equal((await lstat(staleProfile)).ino, staleBefore.ino);
    }
    await rm(archive, { recursive: true });
  });
  await journey('prune LLVM indexes only after the retained coverage passes integrity checks', async () => {
    const archive = join(output, 'index-archive');
    const directory = join(archive, 'scriv-cli-e2e-Test01');
    const coverage = join(directory, 'coverage');
    const analysis = join(coverage, 'analysis', 'source');
    const dataset = join(analysis, 'docs/testing/code-e2e-measurements.json');
    const runID = randomUUID(), invocationID = randomUUID();
    const session = join(coverage, 'sessions', runID);
    const hash = bytes => createHash('sha256').update(bytes).digest('hex');
    const json = (path, value) => writeFile(path, JSON.stringify(value));
    const source = 'synthetic coverage fixture\n';
    const sources = JSON.stringify({ version: 1, kind: 'tracer-source-manifest',
      files: [{ path: 'fixture.txt', sha256: hash(source), hashTiming: 'capture' }] });
    const tools = [{ name: 'synthetic-LCOV-fixture', version: '1', sha256: null, hashTiming: 'unavailable' }];
    const manifest = { version: 1, runId: runID, actions: ['synthetic fixture'], counterMode: 'cumulative', counterReset: false,
      sourceManifestSha256: hash(sources), probeSha256: hash('probe'), tools, limitations: ['Synthetic tooling coverage.'] };
    const exports = {};
    await mkdir(session, { recursive: true });
    await mkdir(analysis, { recursive: true });
    assert.equal(spawnSync('git', ['init', '-q', analysis], { env }).status, 0);
    await writeFile(join(analysis, 'fixture.txt'), source);
    await writeFile(join(coverage, 'build-sources.json'), sources);
    for (const [i, phase] of ['before', 'after'].entries()) {
      const raw = phase + ' synthetic raw profile', indexed = phase + ' disposable index';
      const lcov = `SF:/scriv-source/fixture.txt\nDA:1,${i}\nend_of_record\n`;
      await writeFile(join(session, phase + '.profraw'), raw);
      await writeFile(join(session, phase + '.profdata'), indexed);
      await writeFile(join(session, phase + '.lcov'), lcov);
      exports[phase] = { rawSHA256: hash(raw), indexedSHA256: hash(indexed), lcovSHA256: hash(lcov) };
      manifest[phase] = { sha256: hash(lcov), runId: runID, buildSha256: hash('build'),
        sourceManifestSha256: hash(sources), toolchainSha256: hash(JSON.stringify(tools)) };
    }
    await json(join(session, 'exports.json'), exports);
    await json(join(session, 'interval.json'), manifest);
    const imported = JSON.parse(run(['--root', analysis, 'measure', 'import', '--before', join(session, 'before.lcov'),
      '--after', join(session, 'after.lcov'), '--manifest', join(session, 'interval.json'), '--sources',
      join(coverage, 'build-sources.json'), '--strip-prefix', '/scriv-source/', '--json']).stdout);
    await json(join(session, 'import.json'), imported);
    const capture = { status: 'imported', invocationID, imported: 1, analysis: { root: analysis, dataset },
      intervals: [{ runID, status: 'imported', imported: true }] };
    await json(join(coverage, 'capture.json'), capture);
    const evidence = { schemaVersion: 1, kind: 'actual-app-cli-scenarios', status: 'passed',
      endedAt: new Date().toISOString(), sourceUnchanged: true, appUnchanged: true,
      scenarios: [{ status: 'passed', cleanup: 'owned-process-group-exited' }], coverage: capture };
    const receipt = join(directory, 'evidence.json');
    const prune = (...flags) => JSON.parse(run(['app', '--', 'test', 'compact', '--archive', archive, '--prune', ...flags]).stdout);
    assert.equal(prune('--apply').filesRemoved, 0);
    await json(receipt, { ...evidence, keepIndexedProfiles: true });
    assert.equal(prune('--apply').filesRemoved, 0);
    await json(receipt, evidence);
    const raw = join(session, 'before.profraw');
    const rawBytes = await readFile(raw);
    await writeFile(raw, 'corrupt');
    assert.equal(prune('--apply').filesRemoved, 0);
    await writeFile(raw, rawBytes);
    const retainedSource = join(analysis, 'fixture.txt');
    await writeFile(retainedSource, 'stale');
    assert.equal(prune('--apply').filesRemoved, 0);
    await writeFile(retainedSource, source);
    const retained = [receipt, dataset, raw, join(session, 'after.lcov'), join(session, 'import.json')];
    const before = await Promise.all(retained.map(path => readFile(path)));
    assert.equal(prune().candidates.length, 2);
    assert.equal(prune('--apply').filesRemoved, 2);
    assert.equal(prune('--apply').filesRemoved, 0);
    for (const phase of ['before', 'after']) {
      await assert.rejects(lstat(join(session, phase + '.profdata')), { code: 'ENOENT' });
    }
    assert.deepEqual(await Promise.all(retained.map(path => readFile(path))), before);
    assert.deepEqual(JSON.parse(run(['--root', analysis, 'measure', 'check', '--json']).stdout).invalid, []);
    await rm(archive, { recursive: true });
  });
  await runStorageInputsJourney({ run, output, journey });
  await runStorageMeasureJourney({ run, output, journey });
  await runStorageRetentionJourney({ run, output, journey, tracerCLI: await immutableTracer() });
  await journey('verify the exact source of each declared native action', async () => {
    const { scenarios } = JSON.parse(run(['app', '--', 'test', '--list']).stdout);
    for (const { id, groups, groupActions } of scenarios) {
      for (const [group, actions] of Object.entries(groupActions ?? {})) {
        assert.ok(groups.includes(group));
        for (const { id: action, entryPoint } of actions) {
          if (!entryPoint) continue;
          const { path, start, end, sha256 } = entryPoint;
          const lines = (await readFile(join(root, path), 'utf8')).split(/(?<=\n)/);
          const actual = createHash('sha256').update(lines.slice(start - 1, end).join('')).digest('hex');
          assert.equal(sha256, actual, `${id}#${group} ${action} must anchor the exact source snippet`);
        }
      }
    }
  });
  console.log(`PASS ${passed}/${passed} public Tracer CLI journeys. Native scenarios executed: 0; tooling artifacts: ${output}`);
  return 0;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) main().then(code => { process.exitCode = code; }).catch(error => { console.error(error.message); process.exitCode = 1; });
