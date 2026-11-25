/** Public CLI storage journeys using explicitly synthetic receipts and LCOV.
 * The profile bytes below are fixture data, never a native capture or app pass. */
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { lstat, mkdir, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { dirname, join, relative } from 'node:path';

const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const jsonBytes = value => JSON.stringify(value, null, 2) + '\n';
const absent = async path => lstat(path).then(() => false, error => { if (error.code === 'ENOENT') return true; throw error; });
async function put(path, value) {
  await mkdir(dirname(path), { recursive: true, mode: 0o700 });
  await writeFile(path, value, { flag: 'wx', mode: 0o600 });
}
async function snapshot(root) {
  const files = [];
  async function visit(directory) {
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      const path = join(directory, entry.name);
      if (entry.isDirectory()) await visit(path);
      else { assert.ok(entry.isFile()); files.push({ path: relative(root, path), sha256: sha(await readFile(path)) }); }
    }
  }
  await visit(root);
  return files.sort((a, b) => a.path.localeCompare(b.path));
}

export async function runStorageRetentionJourney({ run, output, journey, tracerCLI = process.env.SCRIV_TRACER_CLI }) {
  const tracer = tracerCLI;
  assert.ok(tracer?.endsWith('/bin/tracer.mjs'), 'Storage tooling requires SCRIV_TRACER_CLI to name the immutable Tracer package bin/tracer.mjs.');
  const archive = join(output, 'storage-retention-archive');
  await mkdir(archive, { mode: 0o700 });
  const sourceRoot = join(archive, 'synthetic-input-source');
  const sourcePath = 'synthetic/story.txt', sourceText = 'synthetic fixture line one\nsynthetic fixture line two\nsynthetic fixture line three\n';
  await put(join(sourceRoot, sourcePath), sourceText);
  const sourceFiles = [{ path: sourcePath, sha256: sha(sourceText) }];
  const sourceManifest = jsonBytes({ schemaVersion: 1, kind: 'scriv-exported-source', baseCommit: '1'.repeat(40),
    deletedTrackedPaths: [], files: sourceFiles });
  const sourceManifestSHA256 = sha(sourceManifest), executableSHA256 = sha('synthetic app identity; no native executable');
  const notice = 'Explicitly synthetic storage fixture. No native app, LLVM profile capture, scenario execution or coverage acceptance is claimed.';
  const tools = ['llvm-profdata', 'llvm-cov', 'tracer', 'node'].map(name =>
    ({ name, version: 'synthetic-storage-fixture-1', sha256: sha(`synthetic tool identity: ${name}`), hashTiming: 'capture' }));
  const probeFiles = [{ path: 'synthetic/probe.mjs', sha256: sha('synthetic probe') }];
  const tracerFiles = [{ path: 'synthetic/tracer.mjs', sha256: sha('synthetic recorded Tracer') }];
  const probeSHA256 = sha(JSON.stringify(probeFiles)), tracerPackageSHA256 = sha(JSON.stringify(tracerFiles));
  const scenario = 'tests/e2e/workspace.mjs';
  const sourceProvenance = { version: 1, kind: 'scriv-coverage-source-comparison', buildSourceRoot: sourceRoot,
    journeySourceRoot: sourceRoot, sourceManifestSHA256, journeySourceManifestSHA256: sourceManifestSHA256,
    nativeInputsUnchanged: true, differences: [], policy: notice, sourceToBinaryAttestation: 'not-established' };
  const storage = (args, expected = 0) => JSON.parse(run(['app', '--', 'test', 'storage', ...args], expected).stdout);
  const clean = (fixture, apply = false) => storage(['clean', '--archive', archive, '--run', fixture.root,
    '--tracer', tracer, ...(apply ? ['--apply'] : [])]);
  const measure = (fixture, args) => JSON.parse(run(['--root', fixture.analysisRoot, 'measure', ...args, '--json']).stdout);
  await journey('initialize a private coverage archive with an explicit storage budget', () => {
    const initialized = storage(['init', '--archive', archive, '--budget-bytes', '1073741824',
      '--run-reserve-bytes', '1048576', '--min-free-bytes', '0']);
    assert.equal(initialized.policy.kind, 'scriv-coverage-storage-policy');
    assert.equal(initialized.policy.budgetBytes, 1073741824);
    assert.equal(initialized.policy.retention, 'coverage-replay-with-raw-profiles');
  });

  async function fixture(label, status = 'passed') {
    const root = join(archive, `scriv-cli-e2e-synthetic-${label}-${randomUUID()}`);
    const coverage = join(root, 'coverage'), runID = randomUUID(), invocationID = randomUUID(), workspaceID = randomUUID();
    const session = join(coverage, 'sessions', runID), analysisRoot = join(coverage, 'analysis/source');
    const dataset = join(analysisRoot, 'docs/testing/code-e2e-measurements.json');
    await put(join(analysisRoot, sourcePath), sourceText);
    const gitEnvironment = Object.fromEntries(Object.entries(process.env).filter(([name]) => !name.startsWith('GIT_')));
    const git = spawnSync('git', ['-c', 'core.sharedRepository=0', 'init', '--template=', '-q', analysisRoot],
      { env: gitEnvironment, encoding: 'utf8', timeout: 30000, shell: false });
    assert.equal(git.status, 0, git.stderr);
    const build = jsonBytes({ version: 1, kind: 'scriv-coverage-build', sourceUnchanged: true,
      sourceManifestSha256: sourceManifestSHA256, executableSha256: executableSHA256, coveragePrefix: '/scriv-source/', limitations: [notice] });
    const buildRecordSHA256 = sha(build);
    for (const name of ['build-sources.json', 'journey-sources.json']) await put(join(coverage, name), sourceManifest);
    await put(join(coverage, 'build-record.json'), build);
    await put(join(coverage, 'source-comparison.json'), jsonBytes(sourceProvenance));
    await put(join(coverage, 'probe-sources.json'), jsonBytes({ files: probeFiles, sha256: probeSHA256 }));
    await put(join(coverage, 'tracer-sources.json'), jsonBytes({ files: tracerFiles, sha256: tracerPackageSHA256 }));
    const analysis = { version: 1, kind: 'scriv-external-coverage-analysis', root: analysisRoot, dataset,
      sourceManifestSHA256, worktreeSHA256: sha(JSON.stringify(sourceFiles)), fileCount: 1,
      sourceBytes: Buffer.byteLength(sourceText), sourceUnchanged: true, scope: 'lcov-source-files',
      buildFileCount: 1, analysisManifestSHA256: sourceManifestSHA256, analysisWorktreeSHA256: sha(JSON.stringify(sourceFiles)), notice };
    await put(join(coverage, 'analysis/analysis.json'), jsonBytes(analysis));
    await put(join(coverage, 'analysis/analysis-sources.json'), sourceManifest);
    const shared = { invocationID, scenario, executableSHA256, sourceManifestSHA256,
      journeySourceManifestSHA256: sourceManifestSHA256, sourceProvenance, buildRecordSHA256, probeSHA256 };
    await put(join(coverage, 'context-0.json'), jsonBytes({ version: 1, ...shared, maximumSessions: 1 }));
    await put(join(coverage, 'slots/0'), runID);
    const profiles = {}, exported = {}, lcov = {};
    for (const phase of ['before', 'after']) {
      const raw = `Synthetic ${label} ${phase} original profile bytes; not LLVM execution.\n`;
      const indexed = `Synthetic ${label} ${phase} derived index bytes; not LLVM execution.\n`;
      lcov[phase] = `SF:/scriv-source/${sourcePath}\nDA:1,${phase === 'before' ? 0 : 2}\nDA:2,0\nDA:3,${phase === 'before' ? 1 : 4}\nend_of_record\n`;
      profiles[phase] = { file: `${phase}.profraw`, sha256: sha(raw), byteCount: Buffer.byteLength(raw), transferCompletedAt: '2000-01-01T00:00:01.000Z' };
      exported[phase] = { rawSHA256: sha(raw), indexedSHA256: sha(indexed), lcovSHA256: sha(lcov[phase]) };
      for (const [extension, bytes] of [['profraw', raw], ['profdata', indexed], ['lcov', lcov[phase]]]) await put(join(session, `${phase}.${extension}`), bytes);
    }
    const sessionRecord = { version: 1, kind: 'scriv-session-coverage', status: 'captured', phase: 'complete',
      ...shared, runID, workspaceID, slot: 0, startedAt: '2000-01-01T00:00:00.000Z', endedAt: '2000-01-01T00:00:02.000Z',
      executableUnchanged: true, counterMode: 'cumulative', counterReset: false, profiles,
      commands: [{ ordinal: 1, command: 'capabilities', status: 'completed' }], limitations: [notice], synthetic: true };
    await put(join(session, 'session.json'), jsonBytes(sessionRecord));
    const identity = phase => ({ sha256: sha(lcov[phase]), runId: runID, buildSha256: executableSHA256,
      sourceManifestSha256: sourceManifestSHA256, toolchainSha256: sha(JSON.stringify(tools)) });
    const interval = { version: 1, runId: runID, actions: ['synthetic storage fixture; no native execution'],
      counterMode: 'cumulative', counterReset: false, sourceManifestSha256: sourceManifestSHA256,
      probeSha256: probeSHA256, tools, limitations: [notice], before: identity('before'), after: identity('after') };
    await put(join(session, 'interval.json'), jsonBytes(interval));
    await put(join(session, 'exports.json'), jsonBytes(exported));
    await put(join(session, 'source-provenance.json'), jsonBytes({ sourceManifestSHA256,
      journeySourceManifestSHA256: sourceManifestSHA256, sourceProvenance }));
    const result = measure({ analysisRoot }, ['import', '--before', join(session, 'before.lcov'), '--after', join(session, 'after.lcov'),
      '--manifest', join(session, 'interval.json'), '--sources', join(coverage, 'build-sources.json'), '--strip-prefix', '/scriv-source/']);
    assert.equal(result.changed, true);
    await put(join(session, 'import.json'), jsonBytes(result));
    const capture = { status: 'imported', invocationID, buildRecordSHA256, sourceManifestSHA256,
      journeySourceManifestSHA256: sourceManifestSHA256, sourceProvenance, probeSHA256, maximumSessions: 1, tools,
      intervals: [{ runID, workspaceID, scenario, scenarioStatus: status, status: 'imported', imported: true }],
      imported: 1, tracerPackageSHA256, analysis, limitations: [notice] };
    await put(join(coverage, 'capture.json'), jsonBytes(capture));
    const evidence = { schemaVersion: 1, kind: 'actual-app-cli-scenarios', status,
      selection: { mode: 'subset', cases: [{ scenario }], selectedScenarioCount: 1 }, fullSuitePassed: false,
      startedAt: '2000-01-01T00:00:00.000Z', endedAt: '2000-01-01T00:00:03.000Z',
      sourceUnchanged: true, appUnchanged: true, app: { executableSHA256, bundleSHA256: sha('synthetic app bundle'), fileCount: 1 },
      blocker: null, scenarios: [{ scenario, status, startedAt: '2000-01-01T00:00:00.000Z',
        endedAt: '2000-01-01T00:00:02.000Z', exitCode: status === 'passed' ? 0 : 1, signal: null,
        cleanup: 'owned-process-group-exited' }], coverage: capture, synthetic: true, notice };
    await put(join(root, 'evidence.json'), jsonBytes(evidence));
    return { root, coverage, session, analysisRoot, dataset, evidence, capture, runID, intervalID: result.id };
  }

  let passing, original, previewProof, reportBefore;
  await journey('preview cleanup through Tracer and preserve every synthetic evidence byte', async () => {
    passing = await fixture('passing'); original = await snapshot(passing.root);
    reportBefore = measure(passing, ['report']);
    const preview = clean(passing), result = preview.runs[0];
    assert.equal(preview.cleanup.status, 'preview'); assert.equal(preview.cleanup.skippedRuns, 0);
    assert.equal(result.mode, 'preview'); assert.equal(result.derivedCandidates.length, 2); assert.deepEqual(result.removed, []);
    previewProof = result.proof;
    assert.equal(previewProof.intervals[0].id, passing.intervalID);
    assert.equal(previewProof.measured.allObserved.instrumentedLines, 3);
    assert.equal(previewProof.measured.allObserved.observedLines, 2);
    assert.equal(previewProof.measured.passedOnlyKnown.observedLines, 2);
    assert.deepEqual(previewProof.measured.outcomeCounts, { passed: 1, failed: 0, unknown: 0 });
    assert.deepEqual(await snapshot(passing.root), original);
  });
  await journey('remove only verified indexes and preserve IDs, counters, hashes and declared outcomes', async () => {
    const result = clean(passing, true);
    assert.equal(result.cleanup.status, 'verified'); assert.equal(result.runs[0].removed.length, 2);
    assert.deepEqual(result.runs[0].proof, previewProof);
    assert.deepEqual(measure(passing, ['report']), reportBefore);
    const retained = (await snapshot(passing.root)).filter(file => file.path !== 'retention.json');
    assert.deepEqual(retained, original.filter(file => !file.path.endsWith('.profdata')));
    const receipt = JSON.parse(await readFile(join(passing.root, 'retention.json')));
    assert.equal(receipt.evidenceSHA256, sha(await readFile(join(passing.root, 'evidence.json'))));
    assert.deepEqual(receipt.proof, previewProof); assert.equal(receipt.removed.length, 2);
  });
  await journey('repeat verified cleanup without rewriting evidence or the retention receipt', async () => {
    const before = await snapshot(passing.root), result = clean(passing, true);
    assert.equal(result.cleanup.status, 'verified'); assert.equal(result.runs[0].unchanged, true);
    assert.deepEqual(result.runs[0].removed, []); assert.deepEqual(result.runs[0].proof, previewProof);
    assert.deepEqual(await snapshot(passing.root), before);
  });
  await journey('honor keep-indexed-profiles while still verifying the complete retained evidence', async () => {
    const selected = await fixture('kept-indexes'); selected.evidence.keepIndexedProfiles = true;
    await writeFile(join(selected.root, 'evidence.json'), jsonBytes(selected.evidence));
    const before = await snapshot(selected.root);
    const indexes = await Promise.all(['before', 'after'].map(async phase => ({
      path: join(selected.session, `${phase}.profdata`), info: await lstat(join(selected.session, `${phase}.profdata`)),
    })));
    const preview = clean(selected).runs[0];
    assert.equal(preview.indexPolicy, 'keep-indexed-profiles');
    assert.deepEqual(preview.derivedCandidates, []); assert.equal(preview.retainedDerived.length, 2);
    const applied = clean(selected, true), result = applied.runs[0];
    assert.equal(applied.cleanup.status, 'verified'); assert.equal(result.indexPolicy, 'keep-indexed-profiles');
    assert.deepEqual(result.removed, []); assert.equal(result.allocatedBytesRemoved, 0);
    assert.deepEqual(result.proof, preview.proof);
    for (const { path, info } of indexes) {
      const current = await lstat(path); assert.equal(current.ino, info.ino); assert.equal(current.size, info.size);
    }
    assert.deepEqual((await snapshot(selected.root)).filter(file => file.path !== 'retention.json'), before);
    const receipt = JSON.parse(await readFile(join(selected.root, 'retention.json')));
    assert.equal(receipt.status, 'verified'); assert.equal(receipt.indexPolicy, 'keep-indexed-profiles');
    const retained = await snapshot(selected.root), repeated = clean(selected, true);
    assert.equal(repeated.runs[0].unchanged, true); assert.deepEqual(await snapshot(selected.root), retained);
    await writeFile(join(selected.session, 'after.profraw'), 'invalid retained raw profile');
    const damaged = await snapshot(selected.root), rejected = clean(selected, true);
    assert.equal(rejected.cleanup.status, 'partial'); assert.equal(rejected.runs[0].status, 'retained-unverified');
    assert.deepEqual(await snapshot(selected.root), damaged);
  });
  await journey('retain two reproducible gap reports without changing original outcomes or captures', async () => {
    const captures = join(archive, 'synthetic-captures.json'), outcomes = join(archive, 'synthetic-outcomes.json');
    const outcomeBytes = jsonBytes({ version: 1, intervals: [{ id: passing.intervalID, journey: scenario, status: 'passed',
      evidence: { path: join(passing.root, 'evidence.json'), sha256: sha(await readFile(join(passing.root, 'evidence.json'))) } }] });
    const captureBytes = jsonBytes({ version: 1, scope: 'source-lines', inputRoots: [passing.analysisRoot], outcomes });
    await put(captures, captureBytes); await put(outcomes, outcomeBytes);
    const before = await snapshot(passing.root), reports = [];
    for (let index = 0; index < 3; index++) {
      const report = storage(['report', '--archive', archive, '--tracer', tracer,
        '--capture-set', captures, '--reference-root', passing.analysisRoot]);
      const recipe = JSON.parse(await readFile(report.recipe));
      assert.equal(recipe.kind, 'scriv-regenerable-coverage-report');
      assert.equal(recipe.sha256, sha(await readFile(report.file)));
      assert.equal(recipe.captureSetSHA256, sha(captureBytes));
      assert.equal(recipe.captureSet, captures); assert.equal(recipe.referenceRoot, passing.analysisRoot);
      const result = JSON.parse(await readFile(report.file));
      assert.equal(result.passedOnlyKnown.instrumentedLines, 3);
      // Storage reports use the current app repository. This synthetic path
      // exists only in the reference snapshot and cannot earn current credit.
      assert.equal(result.passedOnlyKnown.observedLines, 0);
      assert.equal(result.files[0].status, 'unavailable-current-source');
      assert.deepEqual(result.intervals.outcomes, { passed: 1, failed: 0, unknown: 0 });
      reports.push(report);
    }
    assert.equal(await absent(reports[0].file), true);
    assert.equal(await absent(reports[0].recipe), true);
    assert.equal(await absent(reports[0].recipe + '.retired'), false);
    for (const report of reports.slice(1)) {
      assert.equal(await absent(report.file), false); assert.equal(await absent(report.recipe), false);
    }
    assert.equal(reports.at(-1).cache.retained.length, 2); assert.equal(reports.at(-1).cache.removed.length, 1);
    const checked = storage(['clean', '--archive', archive, '--run', passing.root, '--tracer', tracer,
      '--capture-set', captures, '--reference-root', passing.analysisRoot, '--apply']);
    assert.equal(checked.cleanup.status, 'verified'); assert.equal(checked.cleanup.captureSetUnchanged, true);
    assert.match(checked.cleanup.coverageSHA256, /^[a-f0-9]{64}$/);
    assert.deepEqual(await snapshot(passing.root), before);
    assert.equal((await readFile(captures)).toString(), captureBytes); assert.equal((await readFile(outcomes)).toString(), outcomeBytes);
  });
  await journey('retain a valid failed capture without granting passing coverage', async () => {
    const failed = await fixture('failed', 'failed'), before = await snapshot(failed.root);
    const result = clean(failed, true), proof = result.runs[0].proof;
    assert.equal(result.cleanup.status, 'verified'); assert.equal(proof.status, 'failed');
    assert.equal(proof.measured.allObserved.observedLines, 2); assert.equal(proof.measured.passedOnlyKnown.observedLines, 0);
    assert.deepEqual(proof.measured.outcomeCounts, { passed: 0, failed: 1, unknown: 0 });
    assert.deepEqual((await snapshot(failed.root)).filter(file => file.path !== 'retention.json'), before.filter(file => !file.path.endsWith('.profdata')));
  });
  await journey('verify legacy interval IDs and already removed indexes without rewriting history', async () => {
    const legacy = await fixture('legacy'), data = JSON.parse(await readFile(legacy.dataset));
    const { payloadSha256: _priorDigest, ...payload } = data.intervals[0];
    payload.id = sha(JSON.stringify([payload.manifest.before.sha256, payload.manifest.after.sha256, payload.manifest.before.buildSha256]));
    data.intervals[0] = { ...payload, payloadSha256: sha(JSON.stringify(payload)) };
    await writeFile(legacy.dataset, JSON.stringify(data) + '\n');
    const imported = JSON.parse(await readFile(join(legacy.session, 'import.json'))); imported.id = payload.id;
    await writeFile(join(legacy.session, 'import.json'), jsonBytes(imported));
    for (const phase of ['before', 'after']) await rm(join(legacy.session, `${phase}.profdata`));
    const before = await snapshot(legacy.root), result = clean(legacy, true), checked = result.runs[0];
    assert.equal(result.cleanup.status, 'verified'); assert.deepEqual(checked.removed, []); assert.equal(checked.absentDerived.length, 2);
    assert.equal(checked.proof.intervals[0].id, payload.id);
    assert.deepEqual((await snapshot(legacy.root)).filter(file => file.path !== 'retention.json'), before);
  });
  await journey('reject an edited retention proof instead of reporting an unchanged verified receipt', async () => {
    const selected = await fixture('edited-retention');
    assert.equal(clean(selected, true).cleanup.status, 'verified');
    const path = join(selected.root, 'retention.json'), value = JSON.parse(await readFile(path));
    value.proof.measured.passedOnlyKnown.observedLines++;
    await writeFile(path, jsonBytes(value));
    const before = await snapshot(selected.root), result = clean(selected, true);
    assert.equal(result.cleanup.status, 'partial'); assert.equal(result.runs[0].reason, 'coverage-retention-retention-receipt-mismatch');
    assert.deepEqual(await snapshot(selected.root), before);
  });
  await journey('preserve incomplete, active and uncertain synthetic runs', async () => {
    for (const state of ['incomplete', 'active', 'uncertain']) {
      const selected = await fixture(state);
      if (state === 'incomplete') {
        selected.evidence.status = 'not-run'; await writeFile(join(selected.root, 'evidence.json'), jsonBytes(selected.evidence));
      } else if (state === 'active') await put(join(selected.root, 'evidence.json.tmp'), 'pending fixture write');
      else {
        selected.evidence.scenarios[0].cleanup = 'uncertain-owned-process-group';
        await writeFile(join(selected.root, 'evidence.json'), jsonBytes(selected.evidence));
      }
      const before = await snapshot(selected.root), result = clean(selected, true);
      assert.equal(result.cleanup.status, 'partial'); assert.equal(result.cleanup.skippedRuns, 1);
      assert.equal(result.runs[0].status, 'retained-unverified'); assert.deepEqual(await snapshot(selected.root), before);
      assert.equal(await absent(join(selected.root, 'retention.json')), true);
    }
  });
  await journey('preserve all indexes when a raw, LCOV, metadata, source or index digest is wrong', async () => {
    for (const changed of ['raw', 'lcov', 'index', 'metadata', 'source', 'dataset']) {
      const selected = await fixture(`tampered-${changed}`);
      const target = { raw: join(selected.session, 'after.profraw'), lcov: join(selected.session, 'after.lcov'),
        index: join(selected.session, 'after.profdata'), metadata: join(selected.coverage, 'context-0.json'),
        source: join(selected.analysisRoot, sourcePath), dataset: selected.dataset }[changed];
      if (changed === 'metadata') {
        const value = JSON.parse(await readFile(target)); value.probeSHA256 = '0'.repeat(64); await writeFile(target, jsonBytes(value));
      } else await writeFile(target, Buffer.concat([await readFile(target), Buffer.from('tampered fixture bytes\n')]));
      const before = await snapshot(selected.root), result = clean(selected, true);
      assert.equal(result.cleanup.status, 'partial', changed); assert.equal(result.cleanup.skippedRuns, 1, changed);
      assert.equal(result.runs[0].status, 'retained-unverified'); assert.deepEqual(await snapshot(selected.root), before, changed);
      assert.equal(await absent(join(selected.root, 'retention.json')), true);
    }
  });
}
