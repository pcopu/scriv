// Coordinator for real native scenario captures. No synthetic coverage fallback.
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { createHash, randomUUID } from 'node:crypto';
import { constants } from 'node:fs';
import { access, lstat, realpath, readFile, writeFile, mkdir, readdir, rename } from 'node:fs/promises';
import { basename, dirname, isAbsolute, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { hashFile, probeIdentity, verifyCoverageContextSources } from '../cli/coverage-session.mjs';
import { compactFile } from './compact-cli-archive.mjs';
import { prepareAnalysisRoot } from './prepare-coverage-analysis.mjs';
import { safeSourcePath, verifySourceManifest } from './export-cli-source-manifest.mjs';

const execute = promisify(execFile);
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const coveragePrefix = '/scriv-source/';
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const uuid = value => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value);
const required = condition => { if (!condition) throw new Error('coverage-provenance-invalid'); };
async function input(path, maximum = 8 * 1024 * 1024) {
  const info = await lstat(path);
  required(info.isFile() && !info.isSymbolicLink() && info.size <= maximum && await realpath(path) === path);
  return readFile(path);
}
async function write(path, data) { await writeFile(path, data, { flag: 'wx', mode: 0o600 }); }
export async function saveCoverageStatus(capture) {
  const temporary = join(capture.directory, 'capture.next.json');
  await write(temporary, JSON.stringify(capture.report, null, 2) + '\n');
  await rename(temporary, join(capture.directory, 'capture.json'));
}
async function resolveExecutable(name) {
  const candidates = isAbsolute(name) ? [name] : (process.env.PATH ?? '').split(':').filter(Boolean).map(dir => resolve(dir, name));
  for (const path of candidates) {
    try { await access(path, constants.X_OK); const canonical = await realpath(path); if ((await lstat(canonical)).isFile()) return canonical; } catch {}
  }
  throw new Error('coverage-tool-unavailable');
}
async function tool(name, path, prefix = []) {
  const executable = await resolveExecutable(path);
  const hash = await hashFile(executable);
  const result = await execute(executable, [...prefix, '--version'], { encoding: 'utf8', timeout: 30000, maxBuffer: 65536, env: { ...process.env, TRACER_NO_UPDATE: '1' } });
  const version = result.stdout.replace(/[\x00-\x20\x7f]+/g, ' ').trim();
  required(version.length > 0 && version.length <= 2048 && await hashFile(executable) === hash);
  return { executable, prefix, identity: { name, version, sha256: hash, hashTiming: 'capture' } };
}
async function tracerTool(configured) {
  const path = configured || process.env.SCRIV_TRACER_CLI || 'tracer';
  const canonical = path.endsWith('.mjs') ? await realpath(path) : await resolveExecutable(path);
  // Resolve the actual installed package, not an opaque managed launcher that
  // may select different code later. --tracer can name the package entrypoint.
  required(basename(canonical) === 'tracer.mjs' && basename(dirname(canonical)) === 'bin');
  const packageRoot = dirname(dirname(canonical));
  const packageBytes = await input(join(packageRoot, 'package.json'), 65536);
  const metadata = JSON.parse(packageBytes);
  required(metadata.name === '@pcopu/tracercli');
  const packageFiles = async () => {
    const files = [{ path: 'package.json', sha256: sha(await input(join(packageRoot, 'package.json'), 65536)) }];
    const walk = async directory => {
      for (const entry of await readdir(join(packageRoot, directory), { withFileTypes: true })) {
        const relative = `${directory}/${entry.name}`;
        required(!entry.isSymbolicLink());
        if (entry.isDirectory()) await walk(relative);
        else { required(entry.isFile()); files.push({ path: relative, sha256: await hashFile(join(packageRoot, relative)) }); }
      }
    };
    await walk('bin'); await walk('src');
    return files.sort((a, b) => a.path < b.path ? -1 : a.path > b.path ? 1 : 0);
  };
  const files = await packageFiles(), packageSHA256 = sha(JSON.stringify(files));
  const hash = await hashFile(canonical);
  const node = await tool('node', process.execPath);
  const result = await execute(node.executable, [canonical, '--version'], { encoding: 'utf8', timeout: 30000, maxBuffer: 65536, env: { ...process.env, TRACER_NO_UPDATE: '1' } });
  const version = result.stdout.replace(/[\x00-\x20\x7f]+/g, ' ').trim();
  required([metadata.version, `Tracer ${metadata.version}`].includes(version) && await hashFile(canonical) === hash && sha(JSON.stringify(await packageFiles())) === packageSHA256);
  return { executable: node.executable, prefix: [canonical], identity: { name: 'tracer', version, sha256: hash, hashTiming: 'capture' },
    hashedPath: canonical, node, packageFiles, packageIdentity: { sha256: packageSHA256, files } };
}
async function verifyTools(capture) {
  for (const entry of capture.tools) required(await hashFile(entry.hashedPath ?? entry.executable) === entry.identity.sha256);
  required(sha(JSON.stringify(await capture.tracerCLI.packageFiles())) === capture.tracerCLI.packageIdentity.sha256);
}

// These host files are outside the native build graph. Every other path,
// including all app resources, packages and build scripts, must remain exact.
const hostProbePaths = new Set(['cli/scriv.mjs', 'cli/owned-workspace.mjs', 'cli/scenario-restrictions.mjs',
  'cli/coverage-profile.mjs', 'cli/coverage-session.mjs', 'scripts/run-cli-e2e.mjs', 'scripts/run-service-journeys.mjs',
  'scripts/collect-cli-coverage.mjs', 'scripts/compact-cli-archive.mjs', 'scripts/export-cli-source-manifest.mjs', 'scripts/prepare-coverage-analysis.mjs']);
function hostOnlyChange(path) {
  return path === 'AGENTS.md' || hostProbePaths.has(path)
    || ['tests/e2e/', 'tests/tracer/', 'cloud/tests-e2e/', 'updates/tests-e2e/', 'docs/'].some(prefix => path.startsWith(prefix));
}
export async function verifyCoverageSources({ sourceRoot = root, sourceOptions,
  buildSourceRoot = sourceRoot, buildSourceOptions = sourceOptions }) {
  const journeyRoot = await realpath(sourceRoot), buildRoot = await realpath(buildSourceRoot);
  required(journeyRoot === resolve(sourceRoot) && buildRoot === resolve(buildSourceRoot));
  await verifySourceManifest(journeyRoot, sourceOptions.manifest, sourceOptions.manifestSHA256);
  await verifySourceManifest(buildRoot, buildSourceOptions.manifest, buildSourceOptions.manifestSHA256);
  const journeyBytes = await input(sourceOptions.manifest, 64 * 1024 * 1024);
  const buildBytes = await input(buildSourceOptions.manifest, 64 * 1024 * 1024);
  required(sha(journeyBytes) === sourceOptions.manifestSHA256 && sha(buildBytes) === buildSourceOptions.manifestSHA256);
  const journey = JSON.parse(journeyBytes), build = JSON.parse(buildBytes);
  const before = new Map(build.files.map(file => [file.path, file.sha256]));
  const after = new Map(journey.files.map(file => [file.path, file.sha256]));
  const differences = [...new Set([...before.keys(), ...after.keys()])].sort()
    .filter(path => before.get(path) !== after.get(path))
    .map(path => ({ path, beforeSHA256: before.get(path) ?? null, afterSHA256: after.get(path) ?? null }));
  required(differences.every(file => hostOnlyChange(file.path)));
  return { version: 1, kind: 'scriv-coverage-source-comparison', buildSourceRoot: buildRoot,
    journeySourceRoot: journeyRoot, sourceManifestSHA256: buildSourceOptions.manifestSHA256,
    journeySourceManifestSHA256: sourceOptions.manifestSHA256,
    nativeInputsUnchanged: true, differences,
    policy: 'Exact full manifest comparison; only enumerated host tooling, test directories, docs and AGENTS.md may differ.',
    sourceToBinaryAttestation: 'not-established' };
}
async function verifyCaptureSources(capture) {
  const comparison = await verifyCoverageSources(capture.sourceInputs);
  required(JSON.stringify(comparison) === JSON.stringify(capture.sourceProvenance));
}

export async function prepareCoverage({ app, output, sourceOptions, buildSourceRoot = root, buildSourceOptions = sourceOptions, buildRecordPath, llvmProfdata, llvmCov, tracer, maximumSessions = 64, startup = false }) {
  const sourceInputs = { sourceRoot: root, sourceOptions, buildSourceRoot, buildSourceOptions };
  const sourceProvenance = await verifyCoverageSources(sourceInputs);
  const outputRoot = await realpath(output);
  for (const sourceRoot of [sourceProvenance.buildSourceRoot, sourceProvenance.journeySourceRoot]) {
    required(outputRoot !== sourceRoot && !outputRoot.startsWith(sourceRoot + '/'));
  }
  const source = await input(buildSourceOptions.manifest, 64 * 1024 * 1024);
  required(sha(source) === buildSourceOptions.manifestSHA256);
  const buildBytes = await input(buildRecordPath, 65536), build = JSON.parse(buildBytes);
  const executable = await realpath(join(app, 'Contents/MacOS/Scriv'));
  const executableSHA256 = await hashFile(executable);
  required(build.version === 1 && build.kind === 'scriv-coverage-build' && build.sourceUnchanged === true
    && build.sourceManifestSha256 === buildSourceOptions.manifestSHA256 && build.executableSha256 === executableSHA256
    && build.coveragePrefix === coveragePrefix && Array.isArray(build.limitations));
  const findLLVM = async (configured, name) => configured || (await execute('xcrun', ['--find', name], { encoding: 'utf8', timeout: 30000, maxBuffer: 65536 })).stdout.trim();
  const profdata = await tool('llvm-profdata', await findLLVM(llvmProfdata, 'llvm-profdata'));
  const cov = await tool('llvm-cov', await findLLVM(llvmCov, 'llvm-cov'));
  const tracerCLI = await tracerTool(tracer);
  // Run-scoped interval identities require the corrected importer, not 0.1.1.
  const version = /(?:Tracer\s+)?(\d+)\.(\d+)\.(\d+)/.exec(tracerCLI.identity.version);
  required(version && (Number(version[1]) > 0 || Number(version[2]) > 1 || Number(version[2]) === 1 && Number(version[3]) >= 2));
  const probe = await probeIdentity();
  const directory = join(output, 'coverage');
  await mkdir(directory, { mode: 0o700 });
  await mkdir(join(directory, 'sessions'), { mode: 0o700 });
  await mkdir(join(directory, 'slots'), { mode: 0o700 });
  await write(join(directory, 'build-sources.json'), source);
  await write(join(directory, 'build-record.json'), buildBytes);
  const journeySource = await input(sourceOptions.manifest, 64 * 1024 * 1024);
  required(sha(journeySource) === sourceOptions.manifestSHA256);
  await write(join(directory, 'journey-sources.json'), journeySource);
  await write(join(directory, 'source-comparison.json'), JSON.stringify(sourceProvenance, null, 2) + '\n');
  await write(join(directory, 'probe-sources.json'), JSON.stringify(probe, null, 2) + '\n');
  await write(join(directory, 'tracer-sources.json'), JSON.stringify(tracerCLI.packageIdentity, null, 2) + '\n');
  const capture = { directory, executable, executableSHA256, sourceManifestSHA256: buildSourceOptions.manifestSHA256,
    journeySourceManifestSHA256: sourceOptions.manifestSHA256, sourceInputs, sourceProvenance,
    buildRecordSHA256: sha(buildBytes), probe, invocationID: randomUUID(), maximumSessions, startup,
    profdata, cov, tracerCLI, tools: [profdata, cov, tracerCLI, ...(tracerCLI.node ? [tracerCLI.node] : [])], intervals: [] };
  capture.report = { status: 'ready', invocationID: capture.invocationID, buildRecordSHA256: capture.buildRecordSHA256,
    sourceManifestSHA256: capture.sourceManifestSHA256, journeySourceManifestSHA256: capture.journeySourceManifestSHA256,
    sourceProvenance, probeSHA256: probe.sha256, maximumSessions, ...(startup && { scope: 'startup' }),
    tools: capture.tools.map(tool => tool.identity), intervals: [], imported: 0,
    tracerPackageSHA256: tracerCLI.packageIdentity.sha256,
    limitations: ['Producer-declared build record binds source and signed executable; this is not a cryptographic attestation.',
      'Each real app session has a separate cumulative pair; different processes are never merged.',
      'Counter increases include polling, transport, capture and background work, not action causality or assertion proof.',
      'Only instrumented app/Core code is measured; helpers, services and other languages need separate adapters.'] };
  capture.report.limitations.push(`Pinned Tracer bin/src/package manifest SHA-256 ${tracerCLI.packageIdentity.sha256}; tool hashes identify actual launcher/Node bytes, not a hash substituted for a binary.`);
  await verifyCaptureSources(capture);
  await write(join(directory, 'capture.json'), JSON.stringify(capture.report, null, 2) + '\n');
  return capture;
}

export async function coverageContext(capture, scenario, index) {
  await verifyCaptureSources(capture);
  const path = join(capture.directory, `context-${index}.json`);
  const context = JSON.stringify({ version: 1, invocationID: capture.invocationID, scenario,
    executableSHA256: capture.executableSHA256, sourceManifestSHA256: capture.sourceManifestSHA256,
    journeySourceManifestSHA256: capture.journeySourceManifestSHA256, sourceProvenance: capture.sourceProvenance,
    buildRecordSHA256: capture.buildRecordSHA256, probeSHA256: capture.probe.sha256, maximumSessions: capture.maximumSessions,
    ...(capture.startup && { startup: true }) }) + '\n';
  required(Buffer.byteLength(context) <= 8 * 1024 * 1024);
  await write(path, context);
  return path;
}

export async function exportCoverage(capture, scenarios) {
  await verifyCaptureSources(capture);
  capture.report.status = 'exporting';
  await saveCoverageStatus(capture);
  required(!scenarios.some(scenario => scenario.cleanup?.startsWith('uncertain')));
  required(await hashFile(capture.executable) === capture.executableSHA256 && (await probeIdentity()).sha256 === capture.probe.sha256);
  await verifyTools(capture);
  const names = await readdir(join(capture.directory, 'sessions'));
  required(names.length > 0 && names.length <= capture.maximumSessions && names.every(uuid));
  required((await readdir(join(capture.directory, 'slots'))).length === names.length);
  const records = [];
  for (const runID of names) {
    const directory = join(capture.directory, 'sessions', runID);
    const record = JSON.parse(await input(join(directory, 'session.json')));
    const scenario = scenarios.find(item => item.scenario === record.scenario && item.startedAt);
    required(record.version === 1 && record.kind === 'scriv-session-coverage' && record.status === 'captured' && record.runID === runID
      && uuid(record.workspaceID)
      && record.invocationID === capture.invocationID && scenario && record.executableSHA256 === capture.executableSHA256
      && record.executableUnchanged === true && record.sourceManifestSHA256 === capture.sourceManifestSHA256
      && record.journeySourceManifestSHA256 === capture.journeySourceManifestSHA256
      && JSON.stringify(record.sourceProvenance) === JSON.stringify(capture.sourceProvenance)
      && record.buildRecordSHA256 === capture.buildRecordSHA256 && record.probeSHA256 === capture.probe.sha256
      && record.scope === (capture.startup ? 'startup' : undefined)
      && record.counterMode === 'cumulative' && record.counterReset === false && Number.isSafeInteger(record.slot)
      && record.slot >= 0 && record.slot < capture.maximumSessions);
    required((await input(join(capture.directory, 'slots', String(record.slot)), 128)).toString() === runID);
    required(Array.isArray(record.commands) && record.commands.length > 0 && record.commands.length <= 32768);
    required(record.commands.every((entry, i) => entry.ordinal === i + 1 && /^[a-z][a-z0-9-]{0,63}$/.test(entry.command) && ['completed', 'failed-or-uncertain'].includes(entry.status)));
    records.push({ directory, record, scenario });
  }
  required(new Set(records.map(row => row.record.slot)).size === records.length);
  for (const scenario of scenarios.filter(item => item.startedAt)) required(records.some(row => row.scenario === scenario));
  const measuredPaths = new Set();
  capture.report.allocatedBytesSaved = 0;
  for (const { directory, record, scenario } of records.sort((a, b) => a.record.slot - b.record.slot)) {
    const interval = { runID: record.runID, workspaceID: record.workspaceID, scenario: record.scenario,
      scenarioStatus: scenario.status, status: 'exporting', imported: false, ...(capture.startup && { scope: 'startup' }) };
    capture.report.intervals.push(interval);
    await saveCoverageStatus(capture);
    const profiles = {};
    for (const phase of ['before', 'after']) {
      const metadata = record.profiles[phase];
      required(metadata?.file === `${phase}.profraw`);
      const raw = join(directory, `${phase}.profraw`), bytes = await input(raw, 16 * 1024 * 1024);
      required(bytes.length > 0 && bytes.length === metadata.byteCount && sha(bytes) === metadata.sha256);
      const indexed = join(directory, `${phase}.profdata`);
      // Each cumulative profile is indexed independently. Never merge the pair.
      await execute(capture.profdata.executable, ['merge', '-sparse', raw, '-o', indexed], { timeout: 120000, maxBuffer: 65536 });
      const indexedBytes = await input(indexed, 64 * 1024 * 1024);
      // Tracer imports line counters. Keep the raw profiles for re-exporting
      // function and branch data when a separate analysis needs it.
      const result = await execute(capture.cov.executable, ['export', capture.executable, `-instr-profile=${indexed}`,
        '-format=lcov', '-skip-functions', '-skip-branches'], { timeout: 120000, maxBuffer: 64 * 1024 * 1024, encoding: 'buffer' });
      required(result.stdout.length > 0);
      const lcov = join(directory, `${phase}.lcov`);
      await write(lcov, result.stdout);
      for (const path of [raw, indexed, lcov]) capture.report.allocatedBytesSaved += await compactFile(path);
      for (const [, source] of result.stdout.toString('utf8').matchAll(/^SF:([^\r\n]+)\r?$/gm)) {
        const path = source.slice(coveragePrefix.length);
        required(source.startsWith(coveragePrefix) && safeSourcePath(path));
        measuredPaths.add(path);
      }
      profiles[phase] = { rawSHA256: metadata.sha256, indexedSHA256: sha(indexedBytes), lcovSHA256: sha(result.stdout) };
    }
    await verifyTools(capture);
    required(await hashFile(capture.executable) === capture.executableSHA256);
    const tools = capture.tools.map(tool => tool.identity);
    const snapshot = phase => ({ sha256: profiles[phase].lcovSHA256, runId: record.runID, buildSha256: capture.executableSHA256,
      sourceManifestSha256: capture.sourceManifestSHA256, toolchainSha256: sha(JSON.stringify(tools)) });
    const actions = capture.startup ? ['launch isolated Scriv through the CLI', 'scriv capabilities']
      : record.commands.map(entry => `scriv ${entry.command}`);
    const manifest = { version: 1, runId: record.runID, actions,
      counterMode: 'cumulative', counterReset: false, sourceManifestSha256: capture.sourceManifestSHA256,
      probeSha256: capture.probe.sha256, tools, limitations: [...capture.report.limitations, ...record.limitations,
        `Scenario ${record.scenario} ended ${scenario.status}; this interval records observation, not assertion acceptance.`,
        `Journey source manifest SHA-256 ${capture.journeySourceManifestSHA256}; original build source SHA-256 ${capture.sourceManifestSHA256}; full source comparison is recorded separately in source-comparison.json.`],
      before: snapshot('before'), after: snapshot('after') };
    await write(join(directory, 'interval.json'), JSON.stringify(manifest, null, 2) + '\n');
    await write(join(directory, 'exports.json'), JSON.stringify(profiles, null, 2) + '\n');
    await write(join(directory, 'source-provenance.json'), JSON.stringify({ sourceManifestSHA256: capture.sourceManifestSHA256,
      journeySourceManifestSHA256: capture.journeySourceManifestSHA256, sourceProvenance: capture.sourceProvenance }, null, 2) + '\n');
    interval.status = 'exported';
    capture.intervals.push({ directory, interval });
    await saveCoverageStatus(capture);
  }
  // The full build manifest remains the import identity. Only files named by
  // the actual exports belong in the separate analysis copy.
  capture.analysis = await prepareAnalysisRoot(capture.sourceProvenance.buildSourceRoot,
    join(capture.directory, 'build-sources.json'), capture.sourceManifestSHA256,
    join(capture.directory, 'analysis'), measuredPaths);
  capture.report.analysis = capture.analysis;
  await verifyCaptureSources(capture);
  capture.report.status = 'exported';
  await saveCoverageStatus(capture);
}

export async function importCoverage(capture) {
  await verifyCaptureSources(capture);
  await verifySourceManifest(capture.sourceProvenance.buildSourceRoot, join(capture.directory, 'build-sources.json'), capture.sourceManifestSHA256);
  await verifySourceManifest(capture.sourceProvenance.journeySourceRoot, join(capture.directory, 'journey-sources.json'), capture.journeySourceManifestSHA256);
  capture.report.status = 'importing';
  await saveCoverageStatus(capture);
  for (const { directory, interval } of capture.intervals) {
    await verifyTools(capture);
    interval.status = 'importing'; await saveCoverageStatus(capture);
    let result;
    try { result = await execute(capture.tracerCLI.executable, [...capture.tracerCLI.prefix, '--root', capture.analysis.root, 'measure', 'import',
      '--before', join(directory, 'before.lcov'), '--after', join(directory, 'after.lcov'),
      '--manifest', join(directory, 'interval.json'), '--sources', join(capture.directory, 'build-sources.json'),
      '--strip-prefix', coveragePrefix, '--json'], { cwd: capture.analysis.root, timeout: 120000, maxBuffer: 1024 * 1024,
      env: { ...process.env, TRACER_NO_UPDATE: '1' } }); }
    catch (error) { interval.status = 'import-outcome-uncertain'; await saveCoverageStatus(capture); throw error; }
    // Preserve each successful import receipt. A later failure does not undo or
    // hide earlier imports, and no automatic retry or stale-data override occurs.
    interval.imported = true; interval.status = 'imported-receipt-pending'; capture.report.imported++;
    await saveCoverageStatus(capture);
    await write(join(directory, 'import.json'), result.stdout);
    interval.status = 'imported'; await saveCoverageStatus(capture);
  }
  await verifyCaptureSources(capture);
  await verifySourceManifest(capture.sourceProvenance.buildSourceRoot, join(capture.directory, 'build-sources.json'), capture.sourceManifestSHA256);
  await verifySourceManifest(capture.sourceProvenance.journeySourceRoot, join(capture.directory, 'journey-sources.json'), capture.journeySourceManifestSHA256);
  capture.report.allocatedBytesSaved += await compactFile(capture.analysis.dataset);
  capture.report.status = 'imported';
  await saveCoverageStatus(capture);
}

// Public source preflight uses synthetic trees in tooling journeys and launches no app.
async function main(args) {
  if (args[0] === '--verify-session-source-provenance') {
    required(args.length === 3 && args[1] === '--context');
    const contextPath = resolve(args[2]);
    const context = JSON.parse(await input(contextPath));
    console.log(JSON.stringify(await verifyCoverageContextSources(context, dirname(contextPath))));
    return;
  }
  required(args[0] === '--verify-source-provenance');
  const values = {};
  const allowed = ['--source-root', '--source-manifest', '--source-manifest-sha256',
    '--coverage-build-source-root', '--coverage-build-source-manifest', '--coverage-build-source-manifest-sha256'];
  for (let index = 1; index < args.length; index += 2) {
    required(allowed.includes(args[index]) && args[index + 1] && !Object.hasOwn(values, args[index]));
    values[args[index]] = args[index + 1];
  }
  required(values['--source-root'] && values['--source-manifest'] && values['--source-manifest-sha256']);
  const buildFlags = allowed.slice(3).filter(flag => Object.hasOwn(values, flag));
  required(buildFlags.length === 0 || buildFlags.length === 3);
  const sourceOptions = { manifest: resolve(values['--source-manifest']), manifestSHA256: values['--source-manifest-sha256'] };
  const buildSourceOptions = buildFlags.length ? { manifest: resolve(values['--coverage-build-source-manifest']),
    manifestSHA256: values['--coverage-build-source-manifest-sha256'] } : sourceOptions;
  console.log(JSON.stringify(await verifyCoverageSources({ sourceRoot: resolve(values['--source-root']), sourceOptions,
    buildSourceRoot: buildFlags.length ? resolve(values['--coverage-build-source-root']) : resolve(values['--source-root']), buildSourceOptions })));
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main(process.argv.slice(2)).catch(() => { console.error('Coverage source preflight failed; preserve the pinned build and journey inputs.'); process.exitCode = 2; });
}
