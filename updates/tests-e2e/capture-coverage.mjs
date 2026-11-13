/** Actual opt-in update Worker counters; all evidence and Tracer data stay outside source. */
import assert from 'node:assert/strict';
import { createHash, randomUUID, randomBytes } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { lstat, mkdir, readFile, readdir, realpath, writeFile } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { basename, dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { instrumentWorker, collectorPath, nonceBinding, counterNotice } from './instrument-worker.mjs';
import { exportSourceManifest, verifySourceManifest } from '../../scripts/export-cli-source-manifest.mjs';
import { prepareAnalysisRoot } from '../../scripts/prepare-coverage-analysis.mjs';

const repository = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const sourcePath = 'updates/src/worker.mjs';
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
export async function prepareUpdateCapture(output, selectedTracer) {
  assert.equal(typeof output, 'string'); assert.equal(output, resolve(output));
  const parent = dirname(output); assert.equal(await realpath(parent), parent);
  const info = await lstat(parent); assert(info.isDirectory() && info.uid === process.getuid() && !(info.mode & 0o022));
  assert(outside(repository, output) && outside(output, repository));
  assert(selectedTracer?.endsWith('/bin/tracer.mjs') && selectedTracer === resolve(selectedTracer));
  assert.equal(await realpath(selectedTracer), selectedTracer);
  await mkdir(output, { mode: 0o700 });
  for (const name of ['home', 'tmp']) await mkdir(join(output, name), { mode: 0o700 });
  const runId = randomUUID(), probeFiles = ['updates/tests-e2e/instrument-worker.mjs',
    'updates/tests-e2e/capture-coverage.mjs', 'updates/tests-e2e/update-journey.mjs',
    'scripts/export-cli-source-manifest.mjs', 'scripts/prepare-coverage-analysis.mjs'];
  const probe = [];
  for (const path of probeFiles) probe.push({ path, sha256: await hashFile(join(repository, path)) });
  const probeSHA256 = sha(JSON.stringify(probe));
  const source = await readFile(join(repository, sourcePath));
  const built = instrumentWorker(new TextDecoder('utf-8', { fatal: true }).decode(source), { runId, probeSHA256 });
  assert.equal(built.sourceSHA256, sha(source));
  await write(join(output, 'original.mjs'), source);
  await write(join(output, 'instrumented.mjs'), built.module); await write(join(output, 'entry.mjs'), built.wrapper);
  await write(join(output, 'sites.json'), built.siteManifestBytes); await write(join(output, 'insertions.json'), json(built.insertionLedger));
  await write(join(output, 'probe.json'), json(probe));
  const manifest = join(output, 'sources.json');
  // Explicitly include only this test directory while developing an uncommitted
  // capture. Exact file-set verification still refuses any other untracked source.
  const exported = await exportSourceManifest(repository, manifest, ['updates/tests-e2e']);
  await verifySourceManifest(repository, manifest, exported.manifestSHA256);
  const pinned = new Map(JSON.parse(await readFile(manifest)).files.map(file => [file.path, file.sha256]));
  assert.equal(pinned.get(sourcePath), built.sourceSHA256, 'Built Worker must match exported source identity');
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
    { name: 'Tracer entrypoint', version: '0.3', path: selectedTracer }];
  for (const tool of toolFiles) tool.sha256 = await hashFile(tool.path);
  const tools = toolFiles.map(({ name, version, sha256 }) => ({ name, version, sha256, hashTiming: 'capture' }));
  tools.push({ name: 'Miniflare dist graph', version: await packageVersion('miniflare'), sha256: miniflare.sha256, hashTiming: 'capture' },
    { name: 'Tracer source graph', version: '0.3', sha256: tracerGraph.sha256, hashTiming: 'capture' });
  const toolInputs = { toolFiles, graphs: [miniflare, tracerGraph] };
  await write(join(output, 'tool-inputs.json'), json(toolInputs));
  const moduleSHA256 = sha(built.module), wrapperSHA256 = sha(built.wrapper);
  const buildSHA256 = sha(JSON.stringify({ moduleSHA256, wrapperSHA256, siteManifestSHA256: built.siteManifestSHA256 }));
  const capture = { version: 1, directory: output, runId, tracer: selectedTracer, sourcePath, sourceSHA256: sha(source),
    sourceManifestSHA256: exported.manifestSHA256, probeSHA256, moduleSHA256, wrapperSHA256, buildSHA256,
    siteManifestSHA256: built.siteManifestSHA256, slotCount: built.siteManifest.sites.length, tools,
    limitations: [counterNotice, 'Instrumentation is a test-build transform, not production performance or a compiler coverage attestation.',
      'Only this single update Worker module is represented; native, cloud Durable Objects, helpers and other project code are unknown.',
      'Module initialization occurs before the baseline; counter deltas do not include it.',
      'Listed tool input hashes are producer-declared identity evidence, not a cryptographic build or complete operating-system attestation.'] };
  const version = tracer(capture, repository, ['--version']).trim(); assert.match(version, /\b0\.3(?:\b|\.)/);
  await write(join(output, 'capture.json'), json(capture));
  return { path: join(output, 'capture.json'), finish: interrupted => finishUpdateCapture(capture, interrupted) };
}

export async function loadUpdateCapture(path, source, temporaryRoot) {
  assert.equal(await realpath(path), resolve(path)); assert((await lstat(path)).size < 65536);
  const capture = JSON.parse(await readFile(path)); assert.equal(capture.version, 1);
  assert.equal(dirname(path), capture.directory); assert(outside(repository, capture.directory));
  assert.equal(sha(source), capture.sourceSHA256); assert.match(capture.runId, /^[0-9a-f-]{36}$/);
  const module = await readFile(join(capture.directory, 'instrumented.mjs'), 'utf8');
  const wrapper = await readFile(join(capture.directory, 'entry.mjs'), 'utf8');
  assert.equal(sha(module), capture.moduleSHA256); assert.equal(sha(wrapper), capture.wrapperSHA256);
  const sitesBytes = await readFile(join(capture.directory, 'sites.json')); assert.equal(sha(sitesBytes), capture.siteManifestSHA256);
  const siteManifest = JSON.parse(sitesBytes); assert.equal(siteManifest.sites.length, capture.slotCount);
  const nonce = randomBytes(32).toString('hex'); let collectorRequests = 0, previous, baseline;
  const options = { modules: [{ type: 'ESModule', path: join(temporaryRoot, 'entry.mjs'), contents: wrapper },
    { type: 'ESModule', path: join(temporaryRoot, 'instrumented.mjs'), contents: module }], bindings: { [nonceBinding]: nonce } };
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
    assert.deepEqual(Object.keys(value).sort(), ['version', 'runId', 'sourceSHA256', 'siteManifestSHA256', 'probeSHA256', 'generation', 'sequence', 'invalid', 'counts'].sort());
    assert.equal(value.version, 1); assert.equal(value.runId, capture.runId);
    for (const key of ['sourceSHA256', 'siteManifestSHA256', 'probeSHA256']) assert.equal(value[key], capture[key]);
    assert.equal(value.invalid, false); assert.match(value.generation, /^[0-9a-f-]{36}$/);
    assert.equal(value.sequence, previous ? previous.sequence + 1 : 1);
    assert(Array.isArray(value.counts) && value.counts.length === capture.slotCount);
    assert(value.counts.every(count => Number.isSafeInteger(count) && count >= 0));
    if (previous) {
      assert.equal(value.generation, previous.generation, 'Worker generation must not reset');
      assert(value.counts.every((count, index) => count >= previous.counts[index]), 'Counters must not decrease');
    }
    previous = value; return value;
  }
  return { options,
    async begin(base) {
      const b0 = await request(base, 'before-control');
      await request(base, 'missing-nonce', null, 404); await request(base, 'wrong-nonce', 'invalid', 404);
      baseline = await request(base, 'before'); assert.deepEqual(baseline.counts, b0.counts, 'Collector reads/refusals do not execute original probes');
    },
    async end(base, ordinaryRequests) {
      assert.equal(ordinaryRequests, 48); assert(baseline);
      const after = await request(base, 'after'), a1 = await request(base, 'after-control');
      assert.deepEqual(a1.counts, after.counts, 'Repeated snapshots do not reset or increment counters');
      assert(after.counts.some((count, index) => count > baseline.counts[index]), 'Require genuine positive counter deltas');
      assert.equal(collectorRequests, 6);
      const lines = [...new Set(siteManifest.sites.map(site => site.line))].sort((a, b) => a - b);
      const exportLCOV = snapshot => {
        const totals = new Map(lines.map(line => [line, 0]));
        for (const [index, site] of siteManifest.sites.entries()) {
          const count = totals.get(site.line) + snapshot.counts[index]; assert(Number.isSafeInteger(count)); totals.set(site.line, count);
        }
        return `TN:${capture.runId}\nSF:${sourcePath}\nVER:${capture.sourceSHA256}\n${lines.map(line => `DA:${line},${totals.get(line)}`).join('\n')}\nend_of_record\n`;
      };
      const beforeLCOV = exportLCOV(baseline), afterLCOV = exportLCOV(after);
      await write(join(capture.directory, 'before.lcov'), beforeLCOV); await write(join(capture.directory, 'after.lcov'), afterLCOV);
      const snapshot = bytes => ({ sha256: sha(bytes), runId: capture.runId, buildSha256: capture.buildSHA256,
        sourceManifestSha256: capture.sourceManifestSHA256, toolchainSha256: sha(JSON.stringify(capture.tools)) });
      const interval = { version: 1, runId: capture.runId,
        actions: ['Run the existing update-distribution journey through its 48 ordered public HTTP checks with original assertions unchanged.'],
        counterMode: 'cumulative', counterReset: false, sourceManifestSha256: capture.sourceManifestSHA256,
        probeSha256: capture.probeSHA256, tools: capture.tools, limitations: capture.limitations,
        before: snapshot(beforeLCOV), after: snapshot(afterLCOV) };
      await write(join(capture.directory, 'interval.json'), json(interval));
      await write(join(capture.directory, 'export.json'), json({ status: 'exported', ordinaryRequests, collectorRequests,
        generation: after.generation, sites: siteManifest.sites.length, instrumentedAnchorLines: lines.length, sourceUnchanged: true,
        notice: counterNotice }));
      console.log(JSON.stringify({ kind: 'update-counter-capture', status: 'exported', ordinaryRequests, collectorRequests,
        instrumentedAnchorLines: lines.length, nativeExecution: 'not-run', notice: counterNotice }));
    },
  };
}

async function finishUpdateCapture(capture, interrupted = () => false) {
  capture.interrupted = interrupted;
  assert.equal(interrupted(), false, 'Capture interrupted before finalization');
  const directory = capture.directory, manifest = join(directory, 'sources.json');
  const exported = JSON.parse(await readFile(join(directory, 'export.json'))); assert.equal(exported.status, 'exported');
  await verifySourceManifest(repository, manifest, capture.sourceManifestSHA256);
  const tools = JSON.parse(await readFile(join(directory, 'tool-inputs.json')));
  for (const tool of tools.toolFiles) assert.equal(await hashFile(tool.path), tool.sha256);
  for (const input of tools.graphs) assert.equal((await graph(input.root)).sha256, input.sha256);
  for (const [name, expected] of [['instrumented.mjs', capture.moduleSHA256], ['entry.mjs', capture.wrapperSHA256], ['sites.json', capture.siteManifestSHA256]])
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
  const completed = { kind: 'update-measured-interval', status: 'imported', evidence: directory, analysisRoot: analysis.root,
    ordinaryRequests: 48, collectorRequests: 6, sourceUnchanged: true, negativeDeltaControl: 'rejected',
    nativeExecution: 'not-run', notice: counterNotice };
  await write(join(directory, 'completed.json'), json(completed)); console.log(JSON.stringify(completed));
}
