#!/usr/bin/env node
/** Public subprocess provenance journey. Synthetic source only; never launches an app. */
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { cp, mkdir, mkdtemp, readFile, readdir, realpath, rename, rm, symlink, writeFile, lstat, readlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, isAbsolute, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
export async function main() {
  const runtimePath = process.env.SCRIV_TRACER_RUNTIME;
  if (!runtimePath || !isAbsolute(runtimePath) || await realpath(runtimePath) !== runtimePath || !runtimePath.endsWith('/scenario-runtime.mjs')) throw new Error('Trusted canonical runtime required');
  const pins = {
    'scenario-runtime.mjs': 'b5f634d2d9318f216b044104f40636187ea6808f62ba78b64082ef5f6a2f829d',
    'scenarios.mjs': '1c2fce69d317e4397b39789f351b8700613c2289f5c50d900b61ae2e1822acee',
    'tracer.mjs': '97ab1e28255ee4b6a702ea9732b05c0532abd8179189ee3b02a7c09aa71b8eb6',
    'proposals.mjs': '8775d1938f43c707191636462f9897bd625935912f5ba6770282604eb7fedb1f',
    'catalog.mjs': 'a084193be6c6bdaf95c94b0df36545182eb3cf47e976abe268f811b7f5a1a1c1',
  };
  for (const [name, hash] of Object.entries(pins)) {
    const path = join(dirname(runtimePath), name);
    if (await realpath(path) !== path || sha(await readFile(path)) !== hash) throw new Error('Untrusted runtime');
  }
  const { createScenarioRun } = await import(pathToFileURL(runtimePath).href);
  const catalog = JSON.parse(await readFile(join(root, 'docs/testing/source-provenance-steps.json')));
  const run = createScenarioRun({ catalog, scenarioId: 'source-provenance-recovery', runId: randomUUID(), context: { build: 'copied-current-cli-source', platform: process.platform, inputRoute: 'Tracer to public Scriv CLI and exporter' } });
  const output = await mkdtemp(join(tmpdir(), 'scriv-source-provenance-'));
  const fixture = join(output, 'source'); await mkdir(fixture);
  const env = { ...process.env, TRACER_NO_UPDATE: '1', SCRIV_CLI_TOOLING_ACTIVE: '1' };
  delete env.SCRIV_E2E_APP; delete env.SCRIV_E2E_COVERAGE_CONTEXT;
  // Exact current public implementation bytes, not an imported helper or fake app.
  for (const path of ['cli', 'scripts', 'tests/e2e', 'tracer.json']) await cp(join(root, path), join(fixture, path), { recursive: true, dereference: false });
  await mkdir(join(fixture, 'synthetic'));
  await writeFile(join(fixture, 'synthetic/story.txt'), 'Synthetic source v1\n');
  await writeFile(join(fixture, 'retired.txt'), 'Synthetic retired file\n');
  const spawn = (exe, args, expected = 0) => {
    const child = spawnSync(exe, args, { cwd: fixture, env, encoding: 'utf8', timeout: 30000, maxBuffer: 1024 * 1024, shell: false });
    assert.equal(child.error, undefined); assert.equal(child.signal, null); assert.equal(child.status, expected, child.stderr); return child;
  };
  for (const args of [['init', '-q'], ['add', '.'], ['-c', 'user.name=Synthetic Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'Synthetic source']]) spawn('git', args);
  await rm(join(fixture, 'retired.txt'));
  await mkdir(join(fixture, 'extra')); await writeFile(join(fixture, 'extra/included.txt'), 'Explicit untracked source\n');
  const manifest = join(output, 'source.json');
  let digest, manifestBytes, exported;
  // Snapshot all non-Git fixture names, types, modes, contents and readlink target strings without following links or reading target contents.
  async function snapshot(directory = fixture, prefix = '') {
    const entries = [];
    for (const name of (await readdir(directory)).sort()) {
      if (name === '.git') continue;
      const path = join(directory, name), key = prefix + name, info = await lstat(path);
      entries.push([key, info.mode & 0o777, info.isSymbolicLink() ? ['link', await readlink(path)] : info.isDirectory() ? ['directory'] : ['file', sha(await readFile(path))]]);
      if (info.isDirectory()) entries.push(...await snapshot(path, key + '/'));
    }
    return entries;
  }
  const cli = args => spawn(process.execPath, ['scripts/tracer-cli.mjs', 'app', '--', ...args], 2);
  async function verify(expected, selectedDigest = digest, selectedManifest = manifest) {
    const before = await snapshot(); const pinned = await readFile(selectedManifest);
    const result = cli(['test', '--scenario', 'character-aliases', '--source-manifest', selectedManifest, '--source-manifest-sha256', selectedDigest, '--output-dir', output]);
    const match = result.stdout.match(/evidence: (.+)\n?$/); assert.ok(match);
    const evidence = JSON.parse(await readFile(match[1].trim()));
    assert.equal(evidence.blocker, expected); assert.equal(evidence.status, 'not-run'); assert.equal(evidence.fullSuitePassed, false);
    assert.equal(evidence.app, null); assert.equal(evidence.sourceToAppMatch, 'not-established');
    assert.equal(evidence.scenarios.length, 1); assert.equal(evidence.scenarios[0].status, 'not-run');
    assert.equal(evidence.scenarios[0].reason, 'native-alert-route-library-validation-blocked');
    assert.equal(evidence.scenarios[0].startedAt, undefined);
    assert.deepEqual(await snapshot(), before); assert.deepEqual(await readFile(selectedManifest), pinned);
    if (expected === 'selected-scenarios-blocked') {
      assert.equal(evidence.source.mode, 'verified-exported-source-manifest'); assert.equal(evidence.source.manifestSHA256, selectedDigest);
      assert.equal(evidence.source.fileCount, exported.fileCount); assert.equal(evidence.source.worktreeSHA256, sha(JSON.stringify(JSON.parse(manifestBytes).files)));
      assert.equal(evidence.source.baseCommit, JSON.parse(manifestBytes).baseCommit);
      assert.equal(evidence.source.baseCommitStatus, 'producer-declared-not-consumer-git-verified');
      assert.equal(evidence.source.sourceToBinaryAttestation, 'not-established');
    } else assert.equal(evidence.source, null);
    return evidence;
  }
  async function verifyVariant(data, expected) {
    const path = join(output, `variant-${randomUUID()}.json`);
    const bytes = typeof data === 'string' ? data : JSON.stringify(data);
    await writeFile(path, bytes, { mode: 0o600 });
    return verify(expected, sha(bytes), path);
  }
  async function stage(id, action, execute, check) {
    let result;
    await run.step(id, async step => {
      result = await step.action(action, execute);
      await step.expect('observed', () => check(result));
    });
  }
  try {
    // STEP export-source
    await stage('export-source', 'node scripts/export-cli-source-manifest.mjs --output ${externalManifest} --include extra', async () => {
      const before = await snapshot();
      const result = spawn(process.execPath, ['scripts/export-cli-source-manifest.mjs', '--output', manifest, '--include', 'extra']);
      exported = JSON.parse(result.stdout); digest = exported.manifestSHA256; manifestBytes = await readFile(manifest);
      return { before, after: await snapshot(), data: JSON.parse(manifestBytes) };
    }, ({ before, after, data }) => {
      assert.deepEqual(after, before); assert.equal(digest, sha(manifestBytes)); assert.equal(exported.fileCount, data.files.length);
      assert.deepEqual(data.deletedTrackedPaths, ['retired.txt']); assert.ok(data.files.some(entry => entry.path === 'extra/included.txt'));
      assert.equal(data.kind, 'scriv-exported-source'); assert.equal(data.schemaVersion, 1);
    });
    // STEP valid-readback
    await stage('valid-readback', 'tracer app -- test --scenario character-aliases --source-manifest ${externalManifest} --source-manifest-sha256 ${digest} --output-dir ${externalOutput}', () => verify('selected-scenarios-blocked'), evidence => assert.equal(evidence.source.manifestSHA256, digest));
    // STEP refuse-overwrite
    await stage('refuse-overwrite', 'node scripts/export-cli-source-manifest.mjs --output ${externalManifest} --include extra', async () => {
      const before = await snapshot(); const result = spawn(process.execPath, ['scripts/export-cli-source-manifest.mjs', '--output', manifest, '--include', 'extra'], 2);
      return { before, after: await snapshot(), bytes: await readFile(manifest), stderr: result.stderr };
    }, value => { assert.deepEqual(value.before, value.after); assert.deepEqual(value.bytes, manifestBytes); assert.equal(value.stderr, 'Source manifest export failed; inspect selected source paths and output destination.\n'); });
    // STEP reject-digest
    await stage('reject-digest', 'tracer app -- test --scenario character-aliases --source-manifest ${externalManifest} --source-manifest-sha256 ${wrongDigest} --output-dir ${externalOutput}', () => verify('source-manifest-digest-mismatch', '0'.repeat(64)), evidence => assert.equal(evidence.blocker, 'source-manifest-digest-mismatch'));
    // STEP reject-content
    await writeFile(join(fixture, 'synthetic/story.txt'), 'Changed synthetic source\n');
    await stage('reject-content', 'tracer app -- test --scenario character-aliases --source-manifest ${externalManifest} --source-manifest-sha256 ${digest} --output-dir ${externalOutput}', () => verify('source-manifest-content-mismatch'), evidence => assert.equal(evidence.blocker, 'source-manifest-content-mismatch'));
    await writeFile(join(fixture, 'synthetic/story.txt'), 'Synthetic source v1\n');
    // STEP reject-extra-file
    await writeFile(join(fixture, 'extra/unlisted.txt'), 'Not in source manifest\n');
    await stage('reject-extra-file', 'tracer app -- test --scenario character-aliases --source-manifest ${externalManifest} --source-manifest-sha256 ${digest} --output-dir ${externalOutput}', () => verify('source-manifest-file-set-mismatch'), evidence => assert.equal(evidence.blocker, 'source-manifest-file-set-mismatch'));
    await rm(join(fixture, 'extra/unlisted.txt'));
    // STEP reject-missing-file
    await rename(join(fixture, 'synthetic/story.txt'), join(output, 'saved-story.txt'));
    await stage('reject-missing-file', 'tracer app -- test --scenario character-aliases --source-manifest ${externalManifest} --source-manifest-sha256 ${digest} --output-dir ${externalOutput}', () => verify('source-manifest-missing-file'), evidence => assert.equal(evidence.blocker, 'source-manifest-missing-file'));
    await rename(join(output, 'saved-story.txt'), join(fixture, 'synthetic/story.txt'));
    // STEP reject-ancestor-symlink
    await rename(join(fixture, 'synthetic'), join(output, 'saved-synthetic'));
    await symlink(join(output, 'saved-synthetic'), join(fixture, 'synthetic'));
    await stage('reject-ancestor-symlink', 'tracer app -- test --scenario character-aliases --source-manifest ${externalManifest} --source-manifest-sha256 ${digest} --output-dir ${externalOutput}', () => verify('source-manifest-symlink'), evidence => assert.equal(evidence.blocker, 'source-manifest-symlink'));
    await rm(join(fixture, 'synthetic')); await rename(join(output, 'saved-synthetic'), join(fixture, 'synthetic'));
    // STEP reject-malformed-json
    await stage('reject-malformed-json', 'tracer app -- test --scenario character-aliases --source-manifest ${malformedManifest} --source-manifest-sha256 ${matchingDigest} --output-dir ${externalOutput}', () => verifyVariant('{', 'source-manifest-invalid'), evidence => assert.equal(evidence.blocker, 'source-manifest-invalid'));
    // STEP reject-schema
    await stage('reject-schema', 'tracer app -- test --scenario character-aliases --source-manifest ${schemaManifest} --source-manifest-sha256 ${matchingDigest} --output-dir ${externalOutput}', () => verifyVariant({ ...JSON.parse(manifestBytes), schemaVersion: 2 }, 'source-manifest-invalid'), evidence => assert.equal(evidence.blocker, 'source-manifest-invalid'));
    // STEP reject-unsafe-path
    await stage('reject-unsafe-path', 'tracer app -- test --scenario character-aliases --source-manifest ${unsafePathManifest} --source-manifest-sha256 ${matchingDigest} --output-dir ${externalOutput}', () => {
      const data = JSON.parse(manifestBytes); data.files[0].path = '../outside.txt';
      return verifyVariant(data, 'source-manifest-unsafe-path');
    }, evidence => assert.equal(evidence.blocker, 'source-manifest-unsafe-path'));
    // STEP reject-duplicate-path
    await stage('reject-duplicate-path', 'tracer app -- test --scenario character-aliases --source-manifest ${duplicatePathManifest} --source-manifest-sha256 ${matchingDigest} --output-dir ${externalOutput}', () => {
      const data = JSON.parse(manifestBytes); data.files.splice(0, 0, { ...data.files[0] });
      return verifyVariant(data, 'source-manifest-invalid');
    }, evidence => assert.equal(evidence.blocker, 'source-manifest-invalid'));
    // STEP reject-entry-hash-format
    await stage('reject-entry-hash-format', 'tracer app -- test --scenario character-aliases --source-manifest ${invalidEntryHashManifest} --source-manifest-sha256 ${matchingDigest} --output-dir ${externalOutput}', () => {
      const data = JSON.parse(manifestBytes); data.files[0].sha256 = 'invalid-hash';
      return verifyVariant(data, 'source-manifest-invalid');
    }, evidence => assert.equal(evidence.blocker, 'source-manifest-invalid'));
    // STEP reject-entry-hash-mismatch
    await stage('reject-entry-hash-mismatch', 'tracer app -- test --scenario character-aliases --source-manifest ${wrongEntryHashManifest} --source-manifest-sha256 ${matchingDigest} --output-dir ${externalOutput}', () => {
      const data = JSON.parse(manifestBytes); data.files[0].sha256 = '0'.repeat(64);
      return verifyVariant(data, 'source-manifest-content-mismatch');
    }, evidence => assert.equal(evidence.blocker, 'source-manifest-content-mismatch'));
    // STEP refuse-inside-output
    await stage('refuse-inside-output', 'node scripts/export-cli-source-manifest.mjs --output ${sourceRoot}/inside-manifest.json --include extra', async () => {
      const before = await snapshot();
      const result = spawn(process.execPath, ['scripts/export-cli-source-manifest.mjs', '--output', join(fixture, 'inside-manifest.json'), '--include', 'extra'], 2);
      return { before, after: await snapshot(), bytes: await readFile(manifest), stderr: result.stderr, insideExists: await lstat(join(fixture, 'inside-manifest.json')).then(() => true, error => { if (error.code === 'ENOENT') return false; throw error; }) };
    }, value => { assert.deepEqual(value.before, value.after); assert.deepEqual(value.bytes, manifestBytes); assert.equal(value.insideExists, false); assert.equal(value.stderr, 'Source manifest export failed; inspect selected source paths and output destination.\n'); });
    // STEP recover-readback
    await stage('recover-readback', 'tracer app -- test --scenario character-aliases --source-manifest ${externalManifest} --source-manifest-sha256 ${digest} --output-dir ${externalOutput}', () => verify('selected-scenarios-blocked'), evidence => assert.equal(evidence.source.manifestSHA256, digest));
  } finally {
    const result = run.finish();
    await writeFile(join(output, 'scenario-result.json'), JSON.stringify(result, null, 2) + '\n', { mode: 0o600 });
    console.log(JSON.stringify({ kind: 'source-provenance-journey', status: result.status, evidence: join(output, 'scenario-result.json'), nativeExecution: 'not-run' }));
  }
  return 0;
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) main().then(code => { process.exitCode = code; }).catch(error => { console.error(error.message); process.exitCode = 1; });
