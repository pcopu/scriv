#!/usr/bin/env node
/** Exported working-tree identity, not a Git checkout or a build attestation. */
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { lstat, readdir, readFile, realpath, writeFile } from 'node:fs/promises';
import { dirname, resolve, relative, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const repository = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const sha = data => createHash('sha256').update(data).digest('hex');
const verificationBatchSize = 8;
const excludedDirectory = /^(?:\.git|\.tracer|\.build|node_modules|\.wrangler|dist|build|coverage|\.swiftpm|xcuserdata|test-results|playwright-report|__pycache__)$/i;
const excludedFile = /^(?:\.DS_Store|\.env(?:\..*)?|\.dev\.vars(?:\..*)?|credentials(?:\..*)?|secrets?(?:\..*)?|.*\.(?:p12|p8|pem|key|mobileprovision|xcuserstate|log|pyc))$/i;
export function safeSourcePath(path) {
  return typeof path === 'string' && path.length > 0 && !path.includes('\\') && !/[\x00-\x1f\x7f:]/.test(path)
    && path.split('/').every(part => part && part !== '.' && part !== '..' && !excludedDirectory.test(part)
      && !excludedFile.test(part) && !/\.(?:app|dSYM|scriv)$/i.test(part));
}
async function sourceFiles(root, directory = '') {
  const paths = [];
  for (const entry of await readdir(join(root, directory), { withFileTypes: true })) {
    const path = directory ? `${directory}/${entry.name}` : entry.name;
    if (!safeSourcePath(path)) continue;
    if (entry.isSymbolicLink()) throw new Error('source-manifest-symlink');
    if (entry.isDirectory()) paths.push(...await sourceFiles(root, path));
    else if (entry.isFile()) paths.push(path);
    else throw new Error('source-manifest-special-file');
  }
  return paths.sort();
}
async function entryFor(root, path) {
  if (!safeSourcePath(path)) throw new Error('source-manifest-unsafe-path');
  // Check every ancestor, not only the final file. Never follow source symlinks.
  let current = root;
  const parts = path.split('/');
  for (let i = 0; i < parts.length; i++) {
    current = join(current, parts[i]);
    const info = await lstat(current).catch(() => null);
    if (!info) throw new Error('source-manifest-missing-file');
    if (info.isSymbolicLink()) throw new Error('source-manifest-symlink');
    if (i === parts.length - 1 ? !info.isFile() : !info.isDirectory()) throw new Error('source-manifest-special-file');
  }
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(current)) hash.update(chunk);
  return { path, sha256: hash.digest('hex') };
}
function outside(root, path) {
  const rel = relative(root, path);
  return rel === '..' || rel.startsWith('../');
}
export async function verifySourceManifest(root, manifestPath, expectedSHA256) {
  root = await realpath(root);
  manifestPath = await realpath(manifestPath);
  if (!outside(root, manifestPath)) throw new Error('source-manifest-must-be-outside-source');
  if (!/^[a-f0-9]{64}$/.test(expectedSHA256 ?? '')) throw new Error('source-manifest-digest-required');
  const bytes = await readFile(manifestPath);
  if (sha(bytes) !== expectedSHA256) throw new Error('source-manifest-digest-mismatch');
  let manifest;
  try { manifest = JSON.parse(bytes); } catch { throw new Error('source-manifest-invalid'); }
  if (manifest.schemaVersion !== 1 || manifest.kind !== 'scriv-exported-source' || !/^[a-f0-9]{40,64}$/.test(manifest.baseCommit ?? '')
      || !Array.isArray(manifest.files) || !manifest.files.length) throw new Error('source-manifest-invalid');
  const deleted = manifest.deletedTrackedPaths ?? [];
  if (!Array.isArray(deleted) || deleted.some(path => !safeSourcePath(path))
      || new Set(deleted).size !== deleted.length || JSON.stringify(deleted) !== JSON.stringify([...deleted].sort())) {
    throw new Error('source-manifest-invalid-deletions');
  }
  for (const path of deleted) {
    try { await lstat(join(root, path)); throw new Error('source-manifest-deleted-file-present'); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
  const paths = manifest.files.map(entry => entry?.path);
  if (paths.some(path => !safeSourcePath(path))) throw new Error('source-manifest-unsafe-path');
  if (new Set(paths).size !== paths.length || JSON.stringify(paths) !== JSON.stringify([...paths].sort())) throw new Error('source-manifest-invalid');
  // Recheck every pinned file at every boundary, with bounded open streams.
  // Inspect results in manifest order so concurrent failures keep the same precedence.
  for (let offset = 0; offset < manifest.files.length; offset += verificationBatchSize) {
    const batch = manifest.files.slice(offset, offset + verificationBatchSize);
    const checks = await Promise.allSettled(batch.map(async entry => {
      if (!/^[a-f0-9]{64}$/.test(entry.sha256 ?? '')) throw new Error('source-manifest-invalid');
      if ((await entryFor(root, entry.path)).sha256 !== entry.sha256) throw new Error('source-manifest-content-mismatch');
    }));
    const failure = checks.find(result => result.status === 'rejected');
    if (failure) throw failure.reason;
  }
  if (JSON.stringify(await sourceFiles(root)) !== JSON.stringify(paths)) throw new Error('source-manifest-file-set-mismatch');
  return { mode: 'verified-exported-source-manifest', baseCommit: manifest.baseCommit, baseCommitStatus: 'producer-declared-not-consumer-git-verified', manifestSHA256: expectedSHA256,
    worktreeSHA256: sha(JSON.stringify(manifest.files)), fileCount: paths.length,
    algorithm: 'sha256 of sorted JSON file entries containing relative paths and content sha256; exact eligible file set; no symlinks', sourceToBinaryAttestation: 'not-established' };
}
export async function exportSourceManifest(root, output, includes = []) {
  root = await realpath(root);
  output = join(await realpath(dirname(resolve(output))), resolve(output).split('/').at(-1));
  if (!outside(root, output)) throw new Error('source-manifest-must-be-outside-source');
  const git = (...args) => execFileSync('git', args, { cwd: root, maxBuffer: 64 * 1024 * 1024, stdio: ['ignore', 'pipe', 'ignore'] }).toString();
  if (git('ls-files', '--stage').split('\n').some(line => line.startsWith('160000 '))) throw new Error('submodule-provenance-unsupported');
  if (includes.some(path => !safeSourcePath(path))) throw new Error('source-manifest-unsafe-path');
  // Git's index still names intentionally retired files until a commit. Only
  // confirmed tracked deletions may be omitted; unreadable files remain errors.
  const deletedTrackedPaths = git('ls-files', '-z', '--deleted').split('\0').filter(Boolean).filter(safeSourcePath).sort();
  for (const path of deletedTrackedPaths) {
    try { await lstat(join(root, path)); throw new Error('source-manifest-deletion-raced'); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
  const deleted = new Set(deletedTrackedPaths);
  const tracked = git('ls-files', '-z', '--cached').split('\0').filter(Boolean).filter(safeSourcePath).filter(path => !deleted.has(path));
  const untracked = git('ls-files', '-z', '--others', '--exclude-standard').split('\0').filter(Boolean)
    .filter(path => includes.some(include => path === include || path.startsWith(include + '/')));
  const paths = [...new Set([...tracked, ...untracked])].sort();
  const files = [];
  for (const path of paths) files.push(await entryFor(root, path));
  const manifest = { schemaVersion: 1, kind: 'scriv-exported-source', baseCommit: git('rev-parse', 'HEAD').trim(), deletedTrackedPaths, files };
  const bytes = JSON.stringify(manifest, null, 2) + '\n';
  // Create only; do not overwrite existing files or follow output symlinks.
  await writeFile(output, bytes, { flag: 'wx', mode: 0o600 });
  return { manifestSHA256: sha(bytes), fileCount: files.length };
}
async function main(args) {
  let output; const includes = [];
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--output' && args[i + 1]) output = args[++i];
    else if (args[i] === '--include' && args[i + 1]) includes.push(args[++i]);
    else throw new Error('invalid-arguments');
  }
  if (!output) throw new Error('output-required');
  console.log(JSON.stringify(await exportSourceManifest(repository, output, includes)));
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main(process.argv.slice(2)).catch(() => { console.error('Source manifest export failed; inspect selected source paths and output destination.'); process.exitCode = 2; });
}
