/** Public CLI continuation with explicitly synthetic LCOV, never native evidence. */
import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { lstat, mkdir, readFile, readdir, realpath, rm, symlink, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

const sha = bytes => createHash('sha256').update(bytes).digest('hex');
export async function runMeasurementOutputJourney({ output, fixture, manifest, digest, spawn, snapshot, verify }) {
  output = await realpath(output); fixture = await realpath(fixture); manifest = await realpath(manifest);
  let checks = 0;
  const check = async action => { await action(); checks++; };
  const original = await snapshot(), source = JSON.parse(await readFile(manifest));
  const analysisPath = join(output, 'analysis');
  const prepare = (path, expected = 0) => spawn(process.execPath, ['scripts/prepare-coverage-analysis.mjs',
    '--source-manifest', manifest, '--source-manifest-sha256', digest, '--output', path], expected);
  const analysis = JSON.parse(prepare(analysisPath).stdout);
  const absent = async path => lstat(path).then(() => false, error => { if (error.code === 'ENOENT') return true; throw error; });
  const unchanged = async () => assert.deepEqual(await snapshot(), original);
  await check(async () => {
    assert.equal(analysis.kind, 'scriv-external-coverage-analysis'); assert.equal(analysis.root, join(analysisPath, 'source'));
    assert.equal(analysis.sourceManifestSHA256, digest); assert.equal(analysis.fileCount, source.files.length);
    assert.equal(analysis.sourceUnchanged, true); assert.equal(analysis.worktreeSHA256, sha(JSON.stringify(source.files)));
    assert.equal(analysis.dataset, join(analysis.root, 'docs/testing/code-e2e-measurements.json'));
    for (const file of source.files) assert.equal(sha(await readFile(join(analysis.root, file.path))), file.sha256);
    assert.equal(await absent(analysis.dataset), true); await unchanged();
  });
  // Match the public CLI's explicitly selected entrypoint/executable or PATH route.
  const configured = process.env.SCRIV_TRACER_CLI;
  const executable = configured?.endsWith('.mjs') ? process.execPath : configured || 'tracer';
  const prefix = configured?.endsWith('.mjs') ? [configured] : [];
  const tools = [{ name: 'synthetic-LCOV-fixture', version: '1', sha256: null, hashTiming: 'unavailable' }];
  const artifacts = [];
  for (const count of [1, 2, 3]) {
    const runId = `synthetic-tooling-${randomUUID()}`;
    const before = 'SF:/scriv-source/synthetic/story.txt\nDA:1,0\nend_of_record\n';
    const after = `SF:/scriv-source/synthetic/story.txt\nDA:1,${count}\nend_of_record\n`;
    const identity = text => ({ sha256: sha(text), runId, buildSha256: sha('explicitly synthetic fixture, no app build'),
      sourceManifestSha256: digest, toolchainSha256: sha(JSON.stringify(tools)) });
    const data = { version: 1, runId, actions: ['synthetic tooling fixture; no native execution'], counterMode: 'cumulative', counterReset: false,
      sourceManifestSha256: digest, probeSha256: sha('synthetic fixture, no native probe'), tools,
      limitations: ['Hand-authored LCOV solely tests public output isolation; not measured application execution.'],
      before: identity(before), after: identity(after) };
    const paths = Object.fromEntries(['before', 'after', 'manifest'].map(name => [name, join(output, `synthetic-${count}-${name}`)]));
    await writeFile(paths.before, before, { flag: 'wx', mode: 0o600 });
    await writeFile(paths.after, after, { flag: 'wx', mode: 0o600 });
    await writeFile(paths.manifest, JSON.stringify(data), { flag: 'wx', mode: 0o600 });
    artifacts.push(paths);
  }
  const measure = (args, expected = 0) => spawn(executable, [...prefix, '--root', analysis.root, 'measure', ...args, '--json'], expected);
  const importInterval = (index, expected = 0) => measure(['import', '--before', artifacts[index].before, '--after', artifacts[index].after,
    '--manifest', artifacts[index].manifest, '--sources', manifest, '--strip-prefix', '/scriv-source/'], expected);
  let first, two;
  await check(async () => {
    assert.equal(JSON.parse(importInterval(0).stdout).changed, true);
    first = JSON.parse(await readFile(analysis.dataset)); assert.equal(first.intervals.length, 1);
    await unchanged(); await verify('selected-scenarios-blocked');
  });
  await check(async () => {
    assert.equal(JSON.parse(importInterval(1).stdout).changed, true);
    two = await readFile(analysis.dataset);
    const data = JSON.parse(two); assert.equal(data.intervals.length, 2); assert.deepEqual(data.intervals[0], first.intervals[0]);
    const report = JSON.parse(measure(['report']).stdout);
    assert.equal(report.intervals.length, 2);
    for (const interval of report.intervals) {
      assert.equal(interval.totals.instrumentedLines, 1); assert.equal(interval.totals.observedLines, 1);
      assert.equal(interval.totals.staleFiles, 0); assert.equal(interval.files[0].path, 'synthetic/story.txt');
    }
    assert.deepEqual(JSON.parse(measure(['check']).stdout).invalid, []);
    await unchanged(); await verify('selected-scenarios-blocked');
  });
  await check(async () => {
    assert.equal(JSON.parse(importInterval(0).stdout).changed, false);
    assert.deepEqual(await readFile(analysis.dataset), two); await unchanged();
  });
  await check(async () => {
    const again = JSON.parse(prepare(join(output, 'analysis-second-invocation')).stdout);
    assert.equal(again.worktreeSHA256, analysis.worktreeSHA256); assert.equal(await absent(again.dataset), true);
    assert.deepEqual(await readFile(analysis.dataset), two); await unchanged();
  });
  await check(async () => {
    const before = await snapshot(analysisPath);
    prepare(analysisPath, 2); assert.deepEqual(await snapshot(analysisPath), before); await unchanged();
  });
  await check(async () => {
    prepare(join(fixture, 'analysis-inside-source'), 2);
    assert.equal(await absent(join(fixture, 'analysis-inside-source')), true); await unchanged();
  });
  await check(async () => {
    const path = join(fixture, 'synthetic/story.txt'), originalBytes = await readFile(path);
    await writeFile(path, 'Changed source\n');
    prepare(join(output, 'analysis-stale-source'), 2);
    assert.equal(await absent(join(output, 'analysis-stale-source')), true);
    assert.equal((await readFile(path, 'utf8')), 'Changed source\n');
    await writeFile(path, originalBytes); await unchanged();
  });
  await check(async () => {
    const path = join(analysis.root, 'synthetic/story.txt'), originalBytes = await readFile(path);
    await writeFile(path, 'Changed analysis copy\n');
    assert.equal(JSON.parse(measure(['check'], 1).stdout).invalid.length, 2);
    importInterval(2, 1); assert.deepEqual(await readFile(analysis.dataset), two);
    await writeFile(path, originalBytes); await unchanged();
  });
  await check(async () => {
    const path = join(fixture, 'prior-measurements.json');
    await writeFile(path, two, { flag: 'wx', mode: 0o600 });
    prepare(join(output, 'analysis-extra-source'), 2);
    assert.equal(await absent(join(output, 'analysis-extra-source')), true);
    assert.deepEqual(await readFile(path), two);
    await rm(path); // Only this journey's own synthetic fixture file.
    await unchanged();
  });
  await check(async () => {
    const path = join(output, 'analysis-link'); await symlink(analysisPath, path);
    prepare(path, 2); assert.deepEqual(await readFile(analysis.dataset), two); await unchanged();
  });
  await check(async () => {
    const directory = join(fixture, 'docs/testing'), path = join(directory, 'code-e2e-measurements.json');
    assert.equal(await absent(join(fixture, 'docs')), true);
    await mkdir(directory, { recursive: true }); await writeFile(path, two, { flag: 'wx', mode: 0o600 });
    prepare(join(output, 'analysis-unlisted-dataset'), 2);
    assert.equal(await absent(join(output, 'analysis-unlisted-dataset')), true);
    const included = join(output, 'source-with-dataset.json');
    const exported = JSON.parse(spawn(process.execPath, ['scripts/export-cli-source-manifest.mjs', '--output', included,
      '--include', 'extra', '--include', 'docs']).stdout);
    spawn(process.execPath, ['scripts/prepare-coverage-analysis.mjs', '--source-manifest', included,
      '--source-manifest-sha256', exported.manifestSHA256, '--output', join(output, 'analysis-included-dataset')], 2);
    assert.equal(await absent(join(output, 'analysis-included-dataset')), true);
    assert.deepEqual(await readFile(path), two); assert.deepEqual(await readFile(analysis.dataset), two);
    await rm(path); await rm(directory, { recursive: true }); await rm(join(fixture, 'docs'), { recursive: true });
    await unchanged();
  });
  await check(async () => {
    await verify('selected-scenarios-blocked'); await unchanged();
    assert.deepEqual(await readFile(analysis.dataset), two);
    assert.equal((await readdir(output)).includes('analysis'), true);
  });
  const result = { kind: 'measurement-output-journey', status: 'passed', checks,
    nativeExecution: 'not-run', measurements: 'synthetic importer fixtures, not app coverage', evidence: analysisPath };
  console.log(JSON.stringify(result)); return result;
}
