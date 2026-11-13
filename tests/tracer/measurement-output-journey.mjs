/** Public CLI continuation with explicitly synthetic LCOV, never native evidence. */
import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { chmod, lstat, mkdir, readFile, readdir, realpath, rm, symlink, writeFile } from 'node:fs/promises';
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
    assert.equal(analysis.version, 1);
    assert.equal(analysis.sourceBytes, (await Promise.all(source.files.map(file => readFile(join(fixture, file.path))))).reduce((total, bytes) => total + bytes.length, 0));
    assert.equal(analysis.notice, 'Exact source copy for Tracer measurement storage; not a new build, capture or attestation.');
    assert.deepEqual(JSON.parse(await readFile(join(analysisPath, 'analysis.json'))), analysis);
    for (const path of [analysisPath, analysis.root]) assert.equal((await lstat(path)).mode & 0o777, 0o700);
    assert.equal((await lstat(join(analysisPath, 'analysis.json'))).mode & 0o777, 0o600);
    for (const file of source.files) assert.equal((await lstat(join(analysis.root, file.path))).mode & 0o777, 0o600);
    assert.equal(analysis.kind, 'scriv-external-coverage-analysis'); assert.equal(analysis.root, join(analysisPath, 'source'));
    assert.equal(analysis.sourceManifestSHA256, digest); assert.equal(analysis.fileCount, source.files.length);
    assert.equal(analysis.sourceUnchanged, true); assert.equal(analysis.worktreeSHA256, sha(JSON.stringify(source.files)));
    assert.equal(analysis.dataset, join(analysis.root, 'docs/testing/code-e2e-measurements.json'));
    for (const file of source.files) assert.equal(sha(await readFile(join(analysis.root, file.path))), file.sha256);
    assert.equal(await absent(analysis.dataset), true); await unchanged();
  });
  const prepareArgs = ['--source-manifest', manifest, '--source-manifest-sha256', digest];
  const failedPreparation = async (args, destination) => {
    const before = await snapshot(output);
    const result = spawn(process.execPath, ['scripts/prepare-coverage-analysis.mjs', ...args], 2);
    assert.equal(result.stdout, '');
    assert.equal(result.stderr, 'Coverage analysis preparation failed; preserve existing source and evidence and inspect the selected inputs.\n');
    assert.equal(await absent(destination), true);
    assert.deepEqual(await snapshot(output), before); await unchanged();
  };
  // CHECK analysis-options
  await check(async () => {
    const destination = join(output, 'analysis-invalid-options');
    for (const args of [[], [...prepareArgs], [...prepareArgs, '--output'],
      [...prepareArgs, '--output', destination, '--unknown', 'value'],
      [...prepareArgs, '--output', destination, '--output', destination],
      [...prepareArgs, '--source-manifest', manifest, '--output', destination]]) {
      await failedPreparation(args, destination);
    }
  });
  // CHECK analysis-digests
  await check(async () => {
    const destination = join(output, 'analysis-invalid-digest');
    for (const selectedDigest of ['invalid-digest', '0'.repeat(64)]) {
      await failedPreparation(['--source-manifest', manifest, '--source-manifest-sha256', selectedDigest, '--output', destination], destination);
    }
  });
  // CHECK analysis-parent-permissions
  await check(async () => {
    const parent = join(output, 'unsafe-analysis-parent'); await mkdir(parent, { mode: 0o700 });
    await chmod(parent, 0o722);
    try { await failedPreparation([...prepareArgs, '--output', join(parent, 'copy')], join(parent, 'copy')); }
    finally { await chmod(parent, 0o700); }
    await unchanged();
  });
  // CHECK analysis-malformed-manifest
  await check(async () => {
    const invalid = join(output, 'analysis-invalid-source.json'); await writeFile(invalid, '{', { flag: 'wx', mode: 0o600 });
    const destination = join(output, 'analysis-malformed-source');
    await failedPreparation(['--source-manifest', invalid, '--source-manifest-sha256', sha('{'), '--output', destination], destination);
  });
  // CHECK export-options
  await check(async () => {
    const destination = join(output, 'invalid-export.json');
    for (const args of [[], ['--output'], ['--unknown', 'value'], ['--output', destination, '--include'],
      ['--output', destination, '--include', '../outside']]) {
      const before = await snapshot(output);
      const result = spawn(process.execPath, ['scripts/export-cli-source-manifest.mjs', ...args], 2);
      assert.equal(result.stdout, '');
      assert.equal(result.stderr, 'Source manifest export failed; inspect selected source paths and output destination.\n');
      assert.equal(await absent(destination), true); assert.deepEqual(await snapshot(output), before); await unchanged();
    }
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
    const sourcePath = join(fixture, 'synthetic/story.txt'), sourceBytes = await readFile(sourcePath);
    assert.deepEqual(originalBytes, sourceBytes, 'Analysis starts with exactly the pinned source bytes');
    try {
      await writeFile(path, 'Changed analysis copy\n');
      assert.deepEqual(await readFile(sourcePath), sourceBytes, 'An independent analysis write cannot mutate pinned source');
      assert.equal(JSON.parse(measure(['check'], 1).stdout).invalid.length, 2);
      importInterval(2, 1); assert.deepEqual(await readFile(analysis.dataset), two);
    } finally { await writeFile(path, originalBytes); }
    await unchanged();
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
    // Public preflight exercises the same exact-tree boundary used before capture.
    const base = join(output, 'dual-provenance'); await mkdir(base, { mode: 0o700 });
    const buildRoot = join(base, 'build'), journeyRoot = join(base, 'journey');
    const originalFiles = {
      'apps/catalyst/native.swift': 'retained compiled input\n',
      'tests/e2e/journeys/example.mjs': 'original journey\n',
      'docs/testing/retired.json': 'original documentation\n',
      'scripts/run-cli-e2e.mjs': 'original host runner\n',
    };
    const currentFiles = { ...originalFiles,
      'tests/e2e/journeys/example.mjs': 'updated journey\n',
      'tests/e2e/journeys/support/new.mjs': 'new host helper\n',
      'scripts/run-cli-e2e.mjs': 'updated host runner\n' };
    delete currentFiles['docs/testing/retired.json'];
    const populate = async (directory, files) => {
      await mkdir(directory, { mode: 0o700 });
      for (const [path, bytes] of Object.entries(files)) {
        await mkdir(join(directory, path, '..'), { recursive: true });
        await writeFile(join(directory, path), bytes, { mode: 0o600 });
      }
    };
    await populate(buildRoot, originalFiles); await populate(journeyRoot, currentFiles);
    const pin = async (name, files) => {
      const value = { schemaVersion: 1, kind: 'scriv-exported-source', baseCommit: 'a'.repeat(40),
        files: Object.keys(files).sort().map(path => ({ path, sha256: sha(files[path]) })) };
      const path = join(base, name), bytes = JSON.stringify(value) + '\n';
      await writeFile(path, bytes, { mode: 0o600 }); return { path, digest: sha(bytes) };
    };
    const originalPin = await pin('build.json', originalFiles);
    let journeyPin = await pin('journey.json', currentFiles);
    const differences = () => [...new Set([...Object.keys(originalFiles), ...Object.keys(currentFiles)])].sort()
      .filter(path => originalFiles[path] !== currentFiles[path])
      .map(path => ({ path, beforeSHA256: Object.hasOwn(originalFiles, path) ? sha(originalFiles[path]) : null,
        afterSHA256: Object.hasOwn(currentFiles, path) ? sha(currentFiles[path]) : null }));
    const command = (extra = [], expected = 0) => spawn(process.execPath, ['scripts/collect-cli-coverage.mjs',
      '--verify-source-provenance', '--source-root', journeyRoot,
      '--source-manifest', journeyPin.path, '--source-manifest-sha256', journeyPin.digest,
      '--coverage-build-source-root', buildRoot, '--coverage-build-source-manifest', originalPin.path,
      '--coverage-build-source-manifest-sha256', originalPin.digest, ...extra], expected);
    const receipt = JSON.parse(command().stdout);
    assert.equal(receipt.sourceManifestSHA256, originalPin.digest);
    assert.equal(receipt.journeySourceManifestSHA256, journeyPin.digest);
    assert.deepEqual(receipt.differences, differences());
    assert.equal(receipt.nativeInputsUnchanged, true);
    const single = spawn(process.execPath, ['scripts/collect-cli-coverage.mjs', '--verify-source-provenance',
      '--source-root', buildRoot, '--source-manifest', originalPin.path,
      '--source-manifest-sha256', originalPin.digest]);
    assert.deepEqual(JSON.parse(single.stdout).differences, []);
    await writeFile(join(journeyRoot, 'apps/catalyst/native.swift'), 'unlisted mutation\n');
    assert.equal(command([], 2).stdout, '');
    currentFiles['apps/catalyst/native.swift'] = 'unlisted mutation\n';
    journeyPin = await pin('journey-production.json', currentFiles);
    assert.equal(command([], 2).stdout, '');
    await writeFile(join(journeyRoot, 'apps/catalyst/native.swift'), originalFiles['apps/catalyst/native.swift']);
    currentFiles['apps/catalyst/native.swift'] = originalFiles['apps/catalyst/native.swift'];
    journeyPin = await pin('journey-restored.json', currentFiles);
    for (const path of ['apps/mac/Sources/ScrivApp/Resources/changed.json', 'Package.swift',
      'scripts/rebuild-catalyst-cli.py', 'tests/implementation/hidden.mjs']) {
      await mkdir(join(journeyRoot, path, '..'), { recursive: true });
      currentFiles[path] = 'changed native resource or unapproved build input\n';
      await writeFile(join(journeyRoot, path), currentFiles[path]);
      journeyPin = await pin(`journey-rejected-${sha(path)}.json`, currentFiles);
      assert.equal(command([], 2).stdout, '');
      delete currentFiles[path]; await rm(join(journeyRoot, path));
    }
    journeyPin = await pin('journey-after-rejections.json', currentFiles);
    const buildSnapshot = await snapshot(buildRoot);
    spawn(process.execPath, ['scripts/run-cli-e2e.mjs', '--coverage', '--scenario', 'journeys/audio-library',
      '--source-manifest', journeyPin.path, '--source-manifest-sha256', journeyPin.digest,
      '--coverage-build-source-root', buildRoot, '--coverage-build-source-manifest', originalPin.path,
      '--coverage-build-source-manifest-sha256', originalPin.digest,
      '--coverage-build-record', join(base, 'not-created-build-record.json'), '--output-dir', buildRoot], 2);
    assert.deepEqual(await snapshot(buildRoot), buildSnapshot, 'Reject evidence inside original build source before allocating output');
    await writeFile(join(buildRoot, 'apps/catalyst/native.swift'), 'stale original tree\n');
    assert.equal(command([], 2).stdout, '');
    await writeFile(join(buildRoot, 'apps/catalyst/native.swift'), originalFiles['apps/catalyst/native.swift']);
    assert.deepEqual(JSON.parse(command().stdout).differences, differences());
    // A cold relaunch reuses the scenario context but must recheck both trees
    // and the copied manifests before reserving its next capture slot.
    const contextPath = join(base, 'context.json');
    const context = { sourceManifestSHA256: originalPin.digest,
      journeySourceManifestSHA256: journeyPin.digest, sourceProvenance: receipt };
    const contextBytes = JSON.stringify(context);
    const copiedBuild = join(base, 'build-sources.json'), copiedJourney = join(base, 'journey-sources.json');
    const originalManifestBytes = await readFile(originalPin.path), journeyManifestBytes = await readFile(journeyPin.path);
    await writeFile(copiedBuild, originalManifestBytes); await writeFile(copiedJourney, journeyManifestBytes);
    await writeFile(contextPath, contextBytes);
    const sessionPreflight = (expected = 0) => spawn(process.execPath, ['scripts/collect-cli-coverage.mjs',
      '--verify-session-source-provenance', '--context', contextPath], expected);
    assert.deepEqual(JSON.parse(sessionPreflight().stdout), receipt);
    for (const path of [join(journeyRoot, 'tests/e2e/journeys/example.mjs'), join(buildRoot, 'apps/catalyst/native.swift')]) {
      const bytes = await readFile(path); await writeFile(path, 'changed after initial scenario preflight\n');
      assert.equal(sessionPreflight(2).stdout, '');
      await writeFile(path, bytes);
      assert.deepEqual(JSON.parse(sessionPreflight().stdout), receipt);
    }
    for (const path of [copiedBuild, copiedJourney]) {
      const bytes = await readFile(path); await writeFile(path, Buffer.concat([bytes, Buffer.from(' ')]));
      assert.equal(sessionPreflight(2).stdout, '');
      await writeFile(path, bytes);
    }
    await writeFile(contextPath, JSON.stringify({ ...context, sourceProvenance: { ...receipt, differences: [] } }));
    assert.equal(sessionPreflight(2).stdout, '');
    await writeFile(contextPath, contextBytes);
    assert.deepEqual(JSON.parse(sessionPreflight().stdout), receipt);
    await unchanged();
  });
  const result = { kind: 'measurement-output-journey', status: 'passed', checks,
    nativeExecution: 'not-run', measurements: 'synthetic importer fixtures, not app coverage', evidence: analysisPath };
  console.log(JSON.stringify(result)); return result;
}
