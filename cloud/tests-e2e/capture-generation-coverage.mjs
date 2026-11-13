/** Actual opt-in module-instance counters; evidence and Tracer data stay outside source. */
import assert from 'node:assert/strict';
import { createHash, randomUUID, randomBytes } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { lstat, mkdir, readFile, readdir, realpath, writeFile } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { instrumentGeneration, generationWrapper, measuredSources, collectorPath, nonceBinding, counterNotice } from './instrument-generation.mjs';
import { exportSourceManifest, verifySourceManifest } from '../../scripts/export-cli-source-manifest.mjs';
import { prepareAnalysisRoot } from '../../scripts/prepare-coverage-analysis.mjs';

const repository = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const sha = value => createHash('sha256').update(value).digest('hex');
const write = (path, value) => writeFile(path, value, { flag: 'wx', mode: 0o600 });
const json = value => JSON.stringify(value, null, 2) + '\n';
const outside = (root, path) => { const r = relative(root, path); return r === '..' || r.startsWith('../'); };
async function hashFile(path) {
  path = await realpath(path); assert((await lstat(path)).isFile());
  const hash = createHash('sha256'); for await (const chunk of createReadStream(path)) hash.update(chunk);
  return hash.digest('hex');
}
async function graph(root) {
  root = await realpath(root); const files = [];
  async function walk(path = '') {
    for (const name of (await readdir(join(root, path))).sort()) {
      const next = path ? `${path}/${name}` : name, info = await lstat(join(root, next));
      assert(!info.isSymbolicLink());
      if (info.isDirectory()) await walk(next);
      else { assert(info.isFile()); assert(files.length < 1000); files.push({ path: next, sha256: await hashFile(join(root, next)) }); }
    }
  }
  await walk(); return { root, files, sha256: sha(JSON.stringify(files)) };
}
function tracer(capture, root, args) {
  assert.equal(capture.interrupted?.() ?? false, false, 'Capture interrupted; do not start another Tracer process');
  return execFileSync(process.execPath, [capture.tracer, ...(args.length === 1 && args[0] === '--version' ? [] : ['--root', root]), ...args], {
    cwd: root, timeout: 30000, maxBuffer: 8 * 1024 * 1024, encoding: 'utf8',
    env: { PATH: process.env.PATH, HOME: join(capture.directory, 'home'), TMPDIR: join(capture.directory, 'tmp'),
      XDG_CONFIG_HOME: join(capture.directory, 'home'), TRACER_NO_UPDATE: '1' },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
}
async function buildGenerationBundle(directory, pinned, compiled, wrapperSHA256) {
  assert.deepEqual([...compiled.keys()], measuredSources);
  for (const module of compiled.values()) assert.equal(sha(module.contents), module.moduleSHA256);
  const wrapperPath = join(directory, 'entry.ts'), entry = await readFile(wrapperPath);
  assert.equal(sha(entry), wrapperSHA256);
  const inputs = [], loaded = new Set();
  const options = { absWorkingDir: repository, entryPoints: [wrapperPath], outfile: join(directory, 'bundle.mjs'),
    bundle: true, format: 'esm', platform: 'neutral', target: 'es2022', external: ['cloudflare:*'],
    logLevel: 'silent', write: false, metafile: true, sourcemap: false };
  assert.equal(process.env.ESBUILD_BINARY_PATH, undefined, 'Do not substitute an unpinned esbuild binary');
  const { build, stop } = await import('../node_modules/esbuild/lib/main.js');
  let result;
  try { result = await build({ ...options, plugins: [{ name: 'pinned-selected-modules', setup(builder) {
    builder.onLoad({ filter: /./ }, async args => {
      assert.equal(args.namespace, 'file'); assert.equal(await realpath(args.path), args.path);
      assert(!loaded.has(args.path), 'Each source module resolves exactly once'); loaded.add(args.path);
      if (args.path === wrapperPath) {
        assert.equal(await hashFile(args.path), wrapperSHA256);
        return { contents: new TextDecoder('utf-8', { fatal: true }).decode(entry), loader: 'ts', resolveDir: directory };
      }
      const path = relative(repository, args.path);
      assert(/^cloud\/src\/[a-z-]+\.ts$/.test(path) && pinned.has(path), 'Build inputs must be pinned production TypeScript');
      const original = await readFile(args.path); assert.equal(sha(original), pinned.get(path));
      const module = compiled.get(path), transformed = !!module;
      inputs.push({ path, originalSHA256: sha(original), compiledSHA256: transformed ? module.moduleSHA256 : sha(original), transformed });
      return { contents: transformed ? module.contents : new TextDecoder('utf-8', { fatal: true }).decode(original), loader: 'ts', resolveDir: dirname(args.path) };
    });
  } }] }); } finally { stop(); }
  assert.deepEqual(inputs.filter(input => input.transformed).map(input => input.path).sort(), measuredSources);
  assert(inputs.some(input => input.path === 'cloud/src/index.ts'));
  assert.equal(result.outputFiles.length, 1);
  const bundle = result.outputFiles[0].contents; assert(bundle.length > 0 && bundle.length <= 4 * 1024 * 1024);
  const metaInputs = Object.keys(result.metafile.inputs).map(path => resolve(repository, path));
  assert.deepEqual([...metaInputs].sort(), [...loaded].sort(), 'Metafile must match exactly the pinned loader graph');
  for (const input of Object.values(result.metafile.inputs)) for (const dependency of input.imports)
    if (dependency.external) assert(dependency.path.startsWith('cloudflare:'), 'No external runtime import outside Cloudflare builtin');
  const output = Object.values(result.metafile.outputs); assert.equal(output.length, 1);
  assert.deepEqual([...output[0].exports].sort(), ['BillingCoordinator', 'ProjectRoom', 'default']);
  for (const path of measuredSources) assert(output[0].inputs[path]?.bytesInOutput > 0, 'Every selected module must be retained in bundle');
  const buildRecord = { version: 1, options, inputs: inputs.sort((a, b) => a.path.localeCompare(b.path)),
    wrapperSHA256, modules: [...compiled].map(([path, module]) => ({ path, moduleSHA256: module.moduleSHA256 })), bundleSHA256: sha(bundle), metafile: result.metafile,
    notice: 'Producer-declared original/transformed build graph; not cryptographic compiler attestation. Statement anchors are selected before TypeScript transpilation.' };
  const bytes = json(buildRecord); await write(join(directory, 'build.json'), bytes); await write(join(directory, 'bundle.mjs'), bundle);
  return { bundleSHA256: sha(bundle), buildRecordSHA256: sha(bytes) };
}

export async function prepareGenerationCapture(output, selectedTracer) {
  assert.equal(typeof output, 'string'); assert.equal(output, resolve(output));
  const parent = dirname(output); assert.equal(await realpath(parent), parent);
  const info = await lstat(parent); assert(info.isDirectory() && info.uid === process.getuid() && !(info.mode & 0o022));
  assert(outside(repository, output) && outside(output, repository));
  assert(selectedTracer?.endsWith('/bin/tracer.mjs') && selectedTracer === resolve(selectedTracer));
  assert.equal(await realpath(selectedTracer), selectedTracer);
  await mkdir(output, { mode: 0o700 });
  for (const name of ['home', 'tmp']) await mkdir(join(output, name), { mode: 0o700 });
  const runId = randomUUID(), probeFiles = ['cloud/tests-e2e/instrument-generation.mjs',
    'cloud/tests-e2e/capture-generation-coverage.mjs', 'cloud/tests-e2e/generation-journey.mjs',
    'scripts/export-cli-source-manifest.mjs', 'scripts/prepare-coverage-analysis.mjs'];
  const probe = [];
  for (const path of probeFiles) probe.push({ path, sha256: await hashFile(join(repository, path)) });
  const probeSHA256 = sha(JSON.stringify(probe));
  const compiled = new Map(), modules = [], sites = [];
  for (const [index, sourcePath] of measuredSources.entries()) {
    const source = await readFile(join(repository, sourcePath));
    const built = instrumentGeneration(new TextDecoder('utf-8', { fatal: true }).decode(source), { runId, probeSHA256, sourcePath });
    assert.equal(built.sourceSHA256, sha(source));
    const originalFile = `original-${index}.ts`, instrumentedFile = `instrumented-${index}.ts`;
    await write(join(output, originalFile), source); await write(join(output, instrumentedFile), built.module);
    await write(join(output, `insertions-${index}.json`), json(built.insertionLedger));
    const module = { sourcePath, sourceSHA256: sha(source), moduleSHA256: sha(built.module),
      siteManifestSHA256: built.siteManifestSHA256, slotCount: built.siteManifest.sites.length, originalFile, instrumentedFile };
    modules.push(module); sites.push(built.siteManifest); compiled.set(sourcePath, { ...module, contents: built.module });
  }
  assert(modules.reduce((sum, module) => sum + module.slotCount, 0) <= 4096);
  const siteManifestBytes = json({ version: 2, modules: sites, notice: counterNotice }), siteManifestSHA256 = sha(siteManifestBytes);
  const wrapper = generationWrapper(Object.fromEntries(measuredSources.map(path => [path, join(repository, path)])), { runId, probeSHA256 });
  await write(join(output, 'entry.ts'), wrapper); await write(join(output, 'sites.json'), siteManifestBytes);
  await write(join(output, 'probe.json'), json(probe));
  const manifest = join(output, 'sources.json');
  // Explicitly include only this test directory while developing an uncommitted
  // capture. Exact file-set verification still refuses any other untracked source.
  const exported = await exportSourceManifest(repository, manifest, ['cloud/tests-e2e']);
  await verifySourceManifest(repository, manifest, exported.manifestSHA256);
  const pinned = new Map(JSON.parse(await readFile(manifest)).files.map(file => [file.path, file.sha256]));
  for (const module of modules) assert.equal(pinned.get(module.sourcePath), module.sourceSHA256, 'Every instrumented input must match exported source identity');
  for (const input of probe) assert.equal(pinned.get(input.path), input.sha256, 'Probe bytes must match exported source identity');
  const miniflare = await graph(join(repository, 'cloud/node_modules/miniflare/dist'));
  const tracerGraph = await graph(join(dirname(dirname(selectedTracer)), 'src'));
  const workerdModule = (await import(pathToFileURL(join(repository, 'cloud/node_modules/workerd/lib/main.js')).href)).default;
  const workerd = typeof workerdModule === 'string' ? workerdModule : workerdModule.default;
  assert.equal(typeof workerd, 'string');
  const packageVersion = async name => JSON.parse(await readFile(join(repository, `cloud/node_modules/${name}/package.json`))).version;
  const toolFiles = [{ name: 'Node executable', version: process.version, path: await realpath(process.execPath) },
    { name: 'TypeScript parser', version: await packageVersion('typescript'), path: join(repository, 'cloud/node_modules/typescript/lib/typescript.js') },
    { name: 'workerd executable', version: await packageVersion('workerd'), path: await realpath(workerd) },
    { name: 'Tracer entrypoint', version: '0.3', path: selectedTracer },
    { name: 'esbuild binary', version: await packageVersion('esbuild'), path: join(repository, 'cloud/node_modules/esbuild/bin/esbuild') },
    { name: 'esbuild JS API', version: await packageVersion('esbuild'), path: join(repository, 'cloud/node_modules/esbuild/lib/main.js') },
    { name: 'esbuild platform binary', version: await packageVersion('esbuild'), path: join(repository, `cloud/node_modules/@esbuild/${process.platform}-${process.arch}/bin/esbuild`) }];
  for (const tool of toolFiles) tool.sha256 = await hashFile(tool.path);
  const tools = toolFiles.map(({ name, version, sha256 }) => ({ name, version, sha256, hashTiming: 'capture' }));
  tools.push({ name: 'Miniflare dist graph', version: await packageVersion('miniflare'), sha256: miniflare.sha256, hashTiming: 'capture' },
    { name: 'Tracer source graph', version: '0.3', sha256: tracerGraph.sha256, hashTiming: 'capture' });
  const toolInputs = { toolFiles, graphs: [miniflare, tracerGraph] };
  await write(join(output, 'tool-inputs.json'), json(toolInputs));
  const wrapperSHA256 = sha(wrapper);
  const bundleIdentity = await buildGenerationBundle(output, pinned, compiled, wrapperSHA256);
  await verifySourceManifest(repository, manifest, exported.manifestSHA256);
  const buildSHA256 = sha(JSON.stringify({ modules, wrapperSHA256, ...bundleIdentity, siteManifestSHA256 }));
  const capture = { version: 2, directory: output, runId, tracer: selectedTracer, modules,
    sourceManifestSHA256: exported.manifestSHA256, probeSHA256, wrapperSHA256, buildSHA256, ...bundleIdentity,
    siteManifestSHA256, tools,
    limitations: [counterNotice, 'Instrumentation is a test-build transform, not production performance or a compiler coverage attestation.',
      'Selected statement entries in four modules, sampled through one Worker module instance during the existing generation journey; no Durable Object instance, other-isolate, branch or overall-project coverage claim.',
      'Shared helpers can be called by background or Durable Object work sharing the collected module instance. Counter increases do not establish main-fetch-only or per-request attribution.',
      'TypeScript is instrumented before esbuild transpilation; original statement positions identify anchors, not generated bundle line ranges or full-line coverage.',
      'Module initialization occurs before the baseline; counter deltas do not include it.',
      'Listed tool input hashes are producer-declared identity evidence, not a cryptographic build or complete operating-system attestation.'] };
  const version = tracer(capture, repository, ['--version']).trim(); assert.match(version, /\b0\.3(?:\b|\.)/);
  await write(join(output, 'capture.json'), json(capture));
  return { path: join(output, 'capture.json'), finish: interrupted => finishGenerationCapture(capture, interrupted) };
}

export async function loadGenerationCapture(path) {
  assert.equal(await realpath(path), resolve(path)); assert((await lstat(path)).size < 65536);
  const capture = JSON.parse(await readFile(path)); assert.equal(capture.version, 2);
  assert.equal(dirname(path), capture.directory); assert(outside(repository, capture.directory));
  assert.match(capture.runId, /^[0-9a-f-]{36}$/);
  assert.deepEqual(capture.modules.map(module => module.sourcePath), measuredSources);
  assert.equal(await hashFile(join(capture.directory, 'entry.ts')), capture.wrapperSHA256);
  const sitesBytes = await readFile(join(capture.directory, 'sites.json')); assert.equal(sha(sitesBytes), capture.siteManifestSHA256);
  const siteManifest = JSON.parse(sitesBytes); assert.equal(siteManifest.version, 2);
  assert.deepEqual(siteManifest.modules.map(module => module.source), measuredSources);
  for (const [index, module] of capture.modules.entries()) {
    assert.equal(await hashFile(join(repository, module.sourcePath)), module.sourceSHA256);
    assert.equal(await hashFile(join(capture.directory, module.originalFile)), module.sourceSHA256);
    assert.equal(await hashFile(join(capture.directory, module.instrumentedFile)), module.moduleSHA256);
    assert.equal(sha(json(siteManifest.modules[index])), module.siteManifestSHA256);
    assert.equal(siteManifest.modules[index].sites.length, module.slotCount);
  }
  const nonce = randomBytes(32).toString('hex'); let collectorRequests = 0, previous, baseline;
  const bundle = await readFile(join(capture.directory, 'bundle.mjs'));
  assert.equal(sha(bundle), capture.bundleSHA256);
  const options = { script: new TextDecoder('utf-8', { fatal: true }).decode(bundle), bindings: { [nonceBinding]: nonce } };
  async function request(base, label, credential = nonce, status = 200) {
    assert.equal(base.hostname, '127.0.0.1'); assert.equal(base.protocol, 'http:'); assert(Number(base.port) > 0);
    const url = new URL(collectorPath, base); assert.equal(url.origin, base.origin); assert(++collectorRequests <= 6);
    const response = await fetch(url, { redirect: 'error', signal: AbortSignal.timeout(5000),
      headers: credential === null ? {} : { 'x-scriv-test-coverage': credential } });
    const chunks = []; let size = 0;
    for await (const chunk of response.body) { size += chunk.length; assert(size <= 65536); chunks.push(chunk); }
    assert.equal(response.status, status); assert.equal(response.headers.get('cache-control'), 'no-store');
    const body = Buffer.concat(chunks);
    if (status !== 200) { assert.equal(body.toString(), 'Not found'); return; }
    await write(join(capture.directory, `${label}.json`), body);
    const value = JSON.parse(body);
    assert.deepEqual(Object.keys(value).sort(), ['version', 'runId', 'probeSHA256', 'modules'].sort());
    assert.equal(value.version, 2); assert.equal(value.runId, capture.runId); assert.equal(value.probeSHA256, capture.probeSHA256);
    assert.deepEqual(value.modules.map(module => module.sourcePath), measuredSources);
    for (const [index, module] of value.modules.entries()) {
      const expected = capture.modules[index], prior = previous?.modules[index];
      assert.deepEqual(Object.keys(module).sort(), ['version', 'sourcePath', 'runId', 'sourceSHA256', 'siteManifestSHA256', 'probeSHA256', 'generation', 'sequence', 'invalid', 'counts'].sort());
      assert.equal(module.version, 1); assert.equal(module.runId, capture.runId); assert.equal(module.probeSHA256, capture.probeSHA256);
      for (const key of ['sourceSHA256', 'siteManifestSHA256']) assert.equal(module[key], expected[key]);
      assert.equal(module.invalid, false); assert.match(module.generation, /^[0-9a-f-]{36}$/);
      assert.equal(module.sequence, prior ? prior.sequence + 1 : 1);
      assert(Array.isArray(module.counts) && module.counts.length === expected.slotCount);
      assert(module.counts.every(count => Number.isSafeInteger(count) && count >= 0));
      if (prior) {
        assert.equal(module.generation, prior.generation, 'Collected module generation must not reset');
        assert(module.counts.every((count, slot) => count >= prior.counts[slot]), 'Counters must not decrease');
      }
    }
    previous = value; return value;
  }
  return { options,
    async begin(base) {
      const b0 = await request(base, 'before-control');
      await request(base, 'missing-nonce', null, 404); await request(base, 'wrong-nonce', 'invalid', 404);
      baseline = await request(base, 'before'); assert.deepEqual(baseline.modules.map(module => module.counts), b0.modules.map(module => module.counts), 'Collector reads/refusals do not execute original probes');
    },
    async end(base, ordinaryRequests) {
      assert.equal(ordinaryRequests, 80); assert(baseline);
      const after = await request(base, 'after'), a1 = await request(base, 'after-control');
      assert.deepEqual(a1.modules.map(module => module.counts), after.modules.map(module => module.counts), 'Repeated snapshots do not reset or increment counters');
      assert(after.modules.some((module, index) => module.counts.some((count, slot) => count > baseline.modules[index].counts[slot])), 'Require genuine positive counter deltas');
      assert.equal(collectorRequests, 6);
      const lineSets = siteManifest.modules.map(module => [...new Set(module.sites.map(site => site.line))].sort((a, b) => a - b));
      const instrumentedAnchorLines = lineSets.reduce((sum, lines) => sum + lines.length, 0);
      const exportLCOV = snapshot => snapshot.modules.map((module, index) => {
        const lines = lineSets[index], totals = new Map(lines.map(line => [line, 0]));
        for (const [slot, site] of siteManifest.modules[index].sites.entries()) {
          const count = totals.get(site.line) + module.counts[slot]; assert(Number.isSafeInteger(count)); totals.set(site.line, count);
        }
        return `TN:${capture.runId}\nSF:${module.sourcePath}\nVER:${module.sourceSHA256}\n${lines.map(line => `DA:${line},${totals.get(line)}`).join('\n')}\nend_of_record\n`;
      }).join('');
      const beforeLCOV = exportLCOV(baseline), afterLCOV = exportLCOV(after);
      await write(join(capture.directory, 'before.lcov'), beforeLCOV); await write(join(capture.directory, 'after.lcov'), afterLCOV);
      const snapshot = bytes => ({ sha256: sha(bytes), runId: capture.runId, buildSha256: capture.buildSHA256,
        sourceManifestSha256: capture.sourceManifestSHA256, toolchainSha256: sha(JSON.stringify(capture.tools)) });
      const interval = { version: 1, runId: capture.runId,
        actions: ['Run the existing generation-service journey through its 80 ordered public HTTP checks with original assertions unchanged.'],
        counterMode: 'cumulative', counterReset: false, sourceManifestSha256: capture.sourceManifestSHA256,
        probeSha256: capture.probeSHA256, tools: capture.tools, limitations: capture.limitations,
        before: snapshot(beforeLCOV), after: snapshot(afterLCOV) };
      await write(join(capture.directory, 'interval.json'), json(interval));
      await write(join(capture.directory, 'export.json'), json({ status: 'exported', ordinaryRequests, collectorRequests,
        modules: after.modules.map((module, index) => ({ sourcePath: module.sourcePath, generation: module.generation, sites: module.counts.length, instrumentedAnchorLines: lineSets[index].length })), instrumentedAnchorLines, sourceUnchanged: true,
        notice: counterNotice }));
      console.log(JSON.stringify({ kind: 'generation-counter-capture', status: 'exported', ordinaryRequests, collectorRequests,
        instrumentedAnchorLines, nativeExecution: 'not-run', notice: counterNotice }));
    },
  };
}

async function finishGenerationCapture(capture, interrupted = () => false) {
  capture.interrupted = interrupted;
  assert.equal(interrupted(), false, 'Capture interrupted before finalization');
  const directory = capture.directory, manifest = join(directory, 'sources.json');
  const exported = JSON.parse(await readFile(join(directory, 'export.json'))); assert.equal(exported.status, 'exported');
  await verifySourceManifest(repository, manifest, capture.sourceManifestSHA256);
  const tools = JSON.parse(await readFile(join(directory, 'tool-inputs.json')));
  for (const tool of tools.toolFiles) assert.equal(await hashFile(tool.path), tool.sha256);
  for (const input of tools.graphs) assert.equal((await graph(input.root)).sha256, input.sha256);
  for (const [name, expected] of [...capture.modules.flatMap(module => [[module.instrumentedFile, module.moduleSHA256], [module.originalFile, module.sourceSHA256]]), ['entry.ts', capture.wrapperSHA256], ['sites.json', capture.siteManifestSHA256], ['bundle.mjs', capture.bundleSHA256], ['build.json', capture.buildRecordSHA256]])
    assert.equal(await hashFile(join(directory, name)), expected);
  const interval = JSON.parse(await readFile(join(directory, 'interval.json')));
  // Real endpoints reversed, not fabricated counts. A fresh validation root must
  // reject negative deltas and remain without a measurement dataset.
  const validation = await prepareAnalysisRoot(repository, manifest, capture.sourceManifestSHA256, join(directory, 'negative-control'));
  const reversed = { ...interval, before: interval.after, after: interval.before,
    limitations: [...interval.limitations, 'INVALID CONTROL: real captured endpoints reversed; never a measured result.'] };
  await write(join(directory, 'invalid-reversed.json'), json(reversed));
  let rejected = false;
  try { tracer(capture, validation.root, ['measure', 'import', '--before', join(directory, 'after.lcov'), '--after', join(directory, 'before.lcov'),
    '--manifest', join(directory, 'invalid-reversed.json'), '--sources', manifest, '--json']); }
  catch (error) { assert.equal(error.status, 1); assert.match(String(error.stderr), /Negative delta or counter reset/); rejected = true;
    await write(join(directory, 'negative-control-result.txt'), String(error.stderr)); }
  assert(rejected); await assert.rejects(lstat(validation.dataset), error => error.code === 'ENOENT');
  const analysis = await prepareAnalysisRoot(repository, manifest, capture.sourceManifestSHA256, join(directory, 'analysis'));
  await write(join(directory, 'import-attempt.json'), json({ status: 'attempting-once', root: analysis.root }));
  // Never retry an uncertain import automatically. Keep this marker and all raw
  // snapshots if the process times out or fails; inspect measure report first.
  const result = tracer(capture, analysis.root, ['measure', 'import', '--before', join(directory, 'before.lcov'), '--after', join(directory, 'after.lcov'),
    '--manifest', join(directory, 'interval.json'), '--sources', manifest, '--json']);
  await write(join(directory, 'import-result.json'), result);
  const report = tracer(capture, analysis.root, ['measure', 'report', '--json']);
  await write(join(directory, 'measurement-report.json'), report);
  await write(join(directory, 'measurement-check.json'), tracer(capture, analysis.root, ['measure', 'check', '--json']));
  await verifySourceManifest(repository, manifest, capture.sourceManifestSHA256);
  const completed = { kind: 'generation-measured-interval', status: 'imported', evidence: directory, analysisRoot: analysis.root,
    ordinaryRequests: 80, collectorRequests: 6, sourceUnchanged: true, negativeDeltaControl: 'rejected',
    nativeExecution: 'not-run', notice: counterNotice };
  await write(join(directory, 'completed.json'), json(completed)); console.log(JSON.stringify(completed));
}
