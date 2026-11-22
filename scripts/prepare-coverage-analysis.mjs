#!/usr/bin/env node
/** Make a create-only analysis copy; never write measurement data into build source. */
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { constants } from 'node:fs';
import { chmod, copyFile, lstat, mkdir, readFile, realpath, writeFile } from 'node:fs/promises';
import { basename, dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { verifySourceManifest } from './export-cli-source-manifest.mjs';

const repository = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const dataset = 'docs/testing/code-e2e-measurements.json';
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const required = condition => { if (!condition) throw new Error('coverage-analysis-invalid'); };
const outside = (root, path) => { const rel = relative(root, path); return rel === '..' || rel.startsWith('../'); };

export async function prepareAnalysisRoot(sourceRoot, manifestPath, manifestSHA256, output, measuredPaths) {
  sourceRoot = await realpath(sourceRoot);
  const parent = await realpath(dirname(resolve(output)));
  output = join(parent, basename(resolve(output)));
  const owner = await lstat(parent);
  required(owner.isDirectory() && owner.uid === process.getuid() && !(owner.mode & 0o022)
    && outside(sourceRoot, output) && outside(output, sourceRoot));
  const identity = await verifySourceManifest(sourceRoot, manifestPath, manifestSHA256);
  const bytes = await readFile(manifestPath);
  required(sha(bytes) === manifestSHA256);
  const manifest = JSON.parse(bytes);
  required(manifest.files.length <= 10000 && !manifest.files.some(file => file.path === dataset));
  const files = measuredPaths === undefined ? manifest.files : manifest.files.filter(file => measuredPaths.has(file.path));
  required(files.length > 0 && (measuredPaths === undefined || files.length === measuredPaths.size));
  // Fail before allocating output if the snapshot exceeds this deliberate budget.
  let total = 0;
  for (const file of files) {
    const info = await lstat(join(sourceRoot, file.path));
    required(info.isFile() && !info.isSymbolicLink() && info.size <= 64 * 1024 * 1024);
    total += info.size; required(total <= 512 * 1024 * 1024);
  }
  await mkdir(output, { mode: 0o700 });
  const root = join(output, 'source');
  await mkdir(root, { mode: 0o700 });
  let copiedBytes = 0;
  for (const file of files) {
    const input = join(sourceRoot, file.path), target = join(root, file.path);
    required(await realpath(input) === input);
    const contents = await readFile(input);
    required(contents.length <= 64 * 1024 * 1024 && sha(contents) === file.sha256);
    copiedBytes += contents.length; required(copiedBytes <= 512 * 1024 * 1024);
    await mkdir(dirname(target), { recursive: true, mode: 0o700 });
    // Request an independent copy-on-write clone where supported. Node falls
    // back to an ordinary copy, while EXCL preserves the create-only boundary.
    await copyFile(input, target, constants.COPYFILE_EXCL | constants.COPYFILE_FICLONE);
    await chmod(target, 0o600);
  }
  let copyManifestPath = manifestPath, copyManifestSHA256 = manifestSHA256;
  if (measuredPaths !== undefined) {
    copyManifestPath = join(output, 'analysis-sources.json');
    const copyBytes = JSON.stringify({ ...manifest, files }, null, 2) + '\n';
    copyManifestSHA256 = sha(copyBytes);
    await writeFile(copyManifestPath, copyBytes, { flag: 'wx', mode: 0o600 });
  }
  const copy = await verifySourceManifest(root, copyManifestPath, copyManifestSHA256);
  required(copy.worktreeSHA256 === sha(JSON.stringify(files)) && copiedBytes === total);
  await verifySourceManifest(sourceRoot, manifestPath, manifestSHA256);
  // Tracer requires a repository root. Make empty local metadata only: no copied
  // Git history, template hooks, remotes, staging or commits, and no inherited GIT_* routing.
  const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith('GIT_')));
  execFileSync('git', ['-c', 'core.sharedRepository=0', 'init', '--template=', '-q', root],
    { cwd: output, env, timeout: 30000, maxBuffer: 65536, stdio: ['ignore', 'pipe', 'pipe'] });
  required((await realpath(execFileSync('git', ['rev-parse', '--show-toplevel'],
    { cwd: root, env, timeout: 30000, maxBuffer: 65536, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim())) === root);
  const report = { version: 1, kind: 'scriv-external-coverage-analysis', root,
    dataset: join(root, dataset), sourceManifestSHA256: manifestSHA256,
    worktreeSHA256: identity.worktreeSHA256, fileCount: copy.fileCount,
    sourceBytes: total, sourceUnchanged: true,
    notice: 'Exact source copy for Tracer measurement storage; not a new build, capture or attestation.' };
  if (measuredPaths !== undefined) {
    Object.assign(report, { scope: 'lcov-source-files', buildFileCount: identity.fileCount,
      analysisManifestSHA256: copyManifestSHA256, analysisWorktreeSHA256: copy.worktreeSHA256 });
  }
  await writeFile(join(output, 'analysis.json'), JSON.stringify(report, null, 2) + '\n', { flag: 'wx', mode: 0o600 });
  return report;
}

async function main(args) {
  const values = {};
  for (let i = 0; i < args.length; i += 2) {
    required(['--source-manifest', '--source-manifest-sha256', '--output'].includes(args[i])
      && args[i + 1] && !Object.hasOwn(values, args[i]));
    values[args[i]] = args[i + 1];
  }
  required(Object.keys(values).length === 3);
  console.log(JSON.stringify(await prepareAnalysisRoot(repository, values['--source-manifest'],
    values['--source-manifest-sha256'], values['--output'])));
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main(process.argv.slice(2)).catch(() => { console.error('Coverage analysis preparation failed; preserve existing source and evidence and inspect the selected inputs.'); process.exitCode = 2; });
}
