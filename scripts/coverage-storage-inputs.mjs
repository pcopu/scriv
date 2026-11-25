/** Shared, verified coverage inputs. Call mutations under the archive owner's lock. */
import { execFile } from 'node:child_process';
import { createHash } from 'node:crypto';
import { constants, createReadStream } from 'node:fs';
import { chmod, chown, copyFile, lstat, mkdir, mkdtemp, readFile, readdir, readlink,
  realpath, rename, rm, statfs, writeFile } from 'node:fs/promises';
import { dirname, isAbsolute, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { verifySourceManifest } from './export-cli-source-manifest.mjs';

const execute = promisify(execFile);
const repository = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const hex = value => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);
const requireInput = (condition, reason) => { if (!condition) throw new Error(`coverage-storage-${reason}`); };
const contains = (root, path) => path === root || path.startsWith(root === '/' ? '/' : root + '/');
const sourceLimit = 512 * 1024 * 1024;
const fileLimit = 64 * 1024 * 1024;
const minimumCloneBytes = 16 * 1024;
const identityKeys = ['dev', 'ino', 'size', 'mode', 'uid', 'gid', 'nlink', 'mtimeNs', 'ctimeNs'];
const absent = async path => lstat(path).then(() => false, error => {
  if (error.code === 'ENOENT') return true;
  throw error;
});

async function canonical(path, type) {
  requireInput(typeof path === 'string' && isAbsolute(path) && resolve(path) === path
    && !/[\x00-\x1f\x7f]/.test(path), 'canonical-path-required');
  const info = await lstat(path);
  requireInput((type === 'directory' ? info.isDirectory() : info.isFile())
    && await realpath(path) === path, 'unsymlinked-input-required');
  return info;
}

async function archiveRoot(path) {
  const info = await canonical(path, 'directory');
  requireInput(path !== '/' && info.uid === process.getuid()
    && !(info.mode & 0o022), 'private-external-archive-required');
  await validateArchiveSourceSeparation(path, repository);
  return path;
}

/** A shared source can operate its owning archive; arbitrary nested repos cannot. */
export async function validateArchiveSourceSeparation(archive, sourceRepository) {
  const archiveInfo = await canonical(archive, 'directory');
  requireInput(archive !== '/' && archiveInfo.uid === process.getuid() && !(archiveInfo.mode & 0o022), 'private-external-archive-required');
  await canonical(sourceRepository, 'directory');
  requireInput(!contains(sourceRepository, archive), 'archive-must-not-be-inside-source');
  if (!contains(archive, sourceRepository)) return;
  const match = /^shared\/sources\/([a-f0-9]{64})\/source$/.exec(relative(archive, sourceRepository));
  requireInput(match, 'nested-repository-is-not-verified-shared-source');
  for (const path of [archive, join(archive, 'shared'), join(archive, 'shared', 'sources'),
    dirname(sourceRepository), sourceRepository]) {
    const info = await canonical(path, 'directory');
    requireInput(info.uid === process.getuid() && !(info.mode & 0o022), 'private-shared-directory-required');
  }
  const manifest = join(dirname(sourceRepository), 'sources.json');
  const info = await canonical(manifest, 'file');
  requireInput(info.uid === process.getuid() && info.nlink === 1 && !(info.mode & 0o022)
    && sha(await regularBytes(manifest)) === match[1], 'shared-source-layout-manifest-mismatch');
  await verifySourceManifest(sourceRepository, manifest, match[1]);
}

async function privateDirectory(path) {
  try { await mkdir(path, { mode: 0o700 }); }
  catch (error) { if (error.code !== 'EEXIST') throw error; }
  const info = await canonical(path, 'directory');
  requireInput(info.uid === process.getuid() && !(info.mode & 0o022), 'private-shared-directory-required');
}

async function sharedParent(archive, kind) {
  const shared = join(archive, 'shared');
  await privateDirectory(shared);
  const parent = join(shared, kind);
  await privateDirectory(parent);
  return parent;
}

async function regularBytes(path, maximum = fileLimit) {
  const info = await canonical(path, 'file');
  requireInput(info.size <= maximum, 'input-too-large');
  return readFile(path);
}

async function hashFile(path) {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(path)) hash.update(chunk);
  return hash.digest('hex');
}

async function copyReservation(archive, sizes, metadataBytes, directoryCount) {
  const block = Number((await statfs(archive)).bsize);
  requireInput(Number.isSafeInteger(block) && block > 0, 'allocation-unit-unavailable');
  const rounded = bytes => Math.ceil(bytes / block) * block;
  // Reserve ordinary copies even when APFS can share data. Include allocation
  // rounding and an explicit allowance for file/directory metadata and records.
  const bytes = sizes.reduce((total, size) => total + rounded(size) + 2 * block, 0)
    + 4 * block * directoryCount + rounded(metadataBytes) + 65536;
  requireInput(Number.isSafeInteger(bytes), 'copy-reservation-overflow');
  return bytes;
}

async function admitCopy(beforeCreate, bytes) {
  if (beforeCreate !== undefined) {
    requireInput(typeof beforeCreate === 'function', 'invalid-admission-callback');
    await beforeCreate(bytes);
  }
}

async function sharedGitRoot(root, initialize = false) {
  const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith('GIT_')));
  if (initialize) await execute('git', ['-c', 'core.sharedRepository=0', 'init', '--template=', '-q', root],
    { cwd: root, env, timeout: 30000, maxBuffer: 65536 });
  await canonical(join(root, '.git'), 'directory');
  const result = await execute('git', ['rev-parse', '--show-toplevel'], { cwd: root, env, timeout: 30000, maxBuffer: 65536 });
  requireInput(await realpath(result.stdout.trim()) === root, 'shared-git-root-mismatch');
}

async function sourceInput(root, manifest, manifestSHA256) {
  await canonical(root, 'directory');
  const bytes = await regularBytes(manifest);
  requireInput(hex(manifestSHA256) && sha(bytes) === manifestSHA256, 'source-manifest-digest-mismatch');
  await verifySourceManifest(root, manifest, manifestSHA256);
  const data = JSON.parse(bytes);
  requireInput(data.files.length <= 10000
    && !data.files.some(file => file.path === 'docs/testing/code-e2e-measurements.json'), 'invalid-source-selection');
  let sourceBytes = 0;
  const files = [];
  for (const file of data.files) {
    const path = join(root, file.path), info = await canonical(path, 'file');
    sourceBytes += info.size;
    requireInput(info.size <= fileLimit && sourceBytes <= sourceLimit, 'source-budget-exceeded');
    files.push({ ...file, absolute: path, info });
  }
  return { bytes, files, sourceBytes };
}

/** Preserve the complete build identity, including design assets and documentation. */
export async function shareSource({ archive, source, manifest, manifestSHA256, beforeCreate }) {
  await archiveRoot(archive);
  requireInput(!contains(source, archive) && !contains(join(archive, 'shared'), source), 'source-output-overlap');
  const input = await sourceInput(source, manifest, manifestSHA256);
  const parent = await sharedParent(archive, 'sources');
  const destination = join(parent, manifestSHA256), root = join(destination, 'source');
  const retainedManifest = join(destination, 'sources.json');
  if (!await absent(destination)) {
    await canonical(destination, 'directory');
    const retained = await sourceInput(root, retainedManifest, manifestSHA256);
    requireInput(retained.sourceBytes === input.sourceBytes && retained.files.every(file => file.info.nlink === 1), 'shared-source-mismatch');
    await sharedGitRoot(root);
    await verifySourceManifest(source, manifest, manifestSHA256);
    return { root, manifest: retainedManifest, manifestSHA256, created: false, sourceBytes: retained.sourceBytes };
  }
  const directories = new Set(['.']);
  for (const file of input.files) for (let path = dirname(file.path); path !== '.'; path = dirname(path)) directories.add(path);
  await admitCopy(beforeCreate, await copyReservation(archive, input.files.map(file => file.info.size), input.bytes.length, directories.size + 1));
  const staging = await mkdtemp(join(parent, '.source-'));
  try {
    const stagedRoot = join(staging, 'source'), stagedManifest = join(staging, 'sources.json');
    await mkdir(stagedRoot, { mode: 0o700 });
    await writeFile(stagedManifest, input.bytes, { flag: 'wx', mode: 0o600 });
    for (const file of input.files) {
      const target = join(stagedRoot, file.path);
      await mkdir(dirname(target), { recursive: true, mode: 0o700 });
      // FICLONE is independent copy-on-write, never a hardlink. Node falls back
      // to an ordinary copy if cloning is unavailable; non-Darwin uses copies.
      await copyFile(file.absolute, target, constants.COPYFILE_EXCL
        | (process.platform === 'darwin' ? constants.COPYFILE_FICLONE : 0));
      await chmod(target, file.info.mode & 0o777);
      requireInput((await lstat(target)).nlink === 1, 'independent-source-copy-required');
    }
    await verifySourceManifest(stagedRoot, stagedManifest, manifestSHA256);
    await verifySourceManifest(source, manifest, manifestSHA256);
    // Tracer requires its selected root to be a Git root. Create only empty
    // metadata: no copied history, hooks, remotes, index or consumer commit.
    await sharedGitRoot(stagedRoot, true);
    requireInput(await absent(destination), 'shared-destination-exists');
    await rename(staging, destination);
    return { root, manifest: retainedManifest, manifestSHA256, created: true, sourceBytes: input.sourceBytes };
  } finally { await rm(staging, { recursive: true, force: true }); }
}

async function signature(app) {
  try {
    await execute('/usr/bin/codesign', ['--verify', '--deep', '--strict', '--all-architectures', app],
      { timeout: 30000, maxBuffer: 65536 });
  } catch { throw new Error('coverage-storage-signature-verification-failed'); }
}

async function bundleIdentity(app, independent = false, files) {
  const rootInfo = await canonical(app, 'directory');
  requireInput(app.endsWith('.app'), 'app-bundle-required');
  const entries = [['.', rootInfo.mode & 0o7777, 'directory']];
  let sourceBytes = 0, fileCount = 0;
  async function walk(directory) {
    for (const entry of (await readdir(directory, { withFileTypes: true })).sort((a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0)) {
      const path = join(directory, entry.name), name = relative(app, path), info = await lstat(path);
      requireInput(!/[\x00-\x1f\x7f]/.test(name) && ++fileCount <= 100000, 'invalid-bundle-entry');
      if (info.isSymbolicLink()) {
        const target = await readlink(path);
        // Framework links may traverse within this bundle, but relocation must
        // never leave a link pointing back to the original or an external file.
        requireInput(!isAbsolute(target) && contains(app, resolve(dirname(path), target))
          && contains(app, await realpath(path)), 'external-bundle-symlink');
        entries.push([name, info.mode & 0o7777, `link:${target}`]);
      } else if (info.isDirectory()) {
        entries.push([name, info.mode & 0o7777, 'directory']);
        await walk(path);
      } else {
        requireInput(info.isFile() && (!independent || info.nlink === 1), 'regular-independent-bundle-files-required');
        sourceBytes += info.size;
        requireInput(sourceBytes <= 8 * 1024 * 1024 * 1024, 'bundle-budget-exceeded');
        const sha256 = await hashFile(path);
        entries.push([name, info.mode & 0o7777, sha256]);
        files?.push({ path: name, absolute: path, sha256, info });
      }
    }
  }
  await walk(app);
  const executable = join(app, 'Contents/MacOS/Scriv');
  await canonical(executable, 'file');
  entries.sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0);
  return { bundleSHA256: sha(JSON.stringify(entries)), executableSHA256: await hashFile(executable), fileCount, sourceBytes };
}

/** Sharing a native build requires real macOS signing verification. */
export async function shareBuild({ archive, app, buildRecord, beforeCreate }) {
  await archiveRoot(archive);
  requireInput(process.platform === 'darwin', 'build-sharing-requires-macos');
  requireInput(!contains(app, archive) && !contains(join(archive, 'shared'), app)
    && !contains(app, buildRecord), 'build-output-overlap');
  const recordBytes = await regularBytes(buildRecord, 65536), record = JSON.parse(recordBytes);
  requireInput(record.version === 1 && record.kind === 'scriv-coverage-build' && record.sourceUnchanged === true
    && record.coveragePrefix === '/scriv-source/' && hex(record.sourceManifestSha256)
    && hex(record.executableSha256), 'invalid-build-record');
  await signature(app);
  const files = [], original = await bundleIdentity(app, false, files);
  requireInput(original.executableSHA256 === record.executableSha256, 'build-executable-mismatch');
  const buildIdentity = { ...original, buildRecordSHA256: sha(recordBytes), sourceManifestSHA256: record.sourceManifestSha256 };
  const buildIdentitySHA256 = sha(JSON.stringify(buildIdentity));
  const parent = await sharedParent(archive, 'builds'), destination = join(parent, buildIdentitySHA256);
  const retainedApp = join(destination, 'Scriv.app'), retainedRecord = join(destination, 'build-record.json');
  const result = created => ({ app: retainedApp, buildRecord: retainedRecord, buildIdentitySHA256, buildIdentity, created });
  if (!await absent(destination)) {
    await canonical(destination, 'directory');
    requireInput(sha(await regularBytes(retainedRecord, 65536)) === buildIdentity.buildRecordSHA256, 'shared-build-record-mismatch');
    await signature(retainedApp);
    requireInput(JSON.stringify(await bundleIdentity(retainedApp, true)) === JSON.stringify(original), 'shared-bundle-mismatch');
    await signature(app);
    requireInput(JSON.stringify(await bundleIdentity(app)) === JSON.stringify(original)
      && sha(await regularBytes(buildRecord, 65536)) === buildIdentity.buildRecordSHA256, 'build-input-changed');
    return result(false);
  }
  await admitCopy(beforeCreate, await copyReservation(archive, files.map(file => file.info.size), recordBytes.length + 8192, original.fileCount + 2));
  const staging = await mkdtemp(join(parent, '.build-'));
  try {
    const stagedApp = join(staging, 'Scriv.app');
    // cp -c requests real filesystem clones; -Rp preserves framework links and
    // bundle metadata. A failed clone is not reported as an APFS saving.
    await execute('/bin/cp', ['-cRp', app, stagedApp], { timeout: 120000, maxBuffer: 65536 });
    await writeFile(join(staging, 'build-record.json'), recordBytes, { flag: 'wx', mode: 0o600 });
    await signature(stagedApp);
    requireInput(JSON.stringify(await bundleIdentity(stagedApp, true)) === JSON.stringify(original), 'shared-bundle-mismatch');
    await signature(app);
    requireInput(JSON.stringify(await bundleIdentity(app)) === JSON.stringify(original)
      && sha(await regularBytes(buildRecord, 65536)) === buildIdentity.buildRecordSHA256, 'build-input-changed');
    await writeFile(join(staging, 'identity.json'), JSON.stringify({ version: 1, buildIdentitySHA256, ...buildIdentity }) + '\n',
      { flag: 'wx', mode: 0o600 });
    requireInput(await absent(destination), 'shared-destination-exists');
    await rename(staging, destination);
    return result(true);
  } finally { await rm(staging, { recursive: true, force: true }); }
}

const sameFile = (a, b) => identityKeys.every(key => a[key] === b[key]);
const fileIdentity = info => JSON.stringify(identityKeys.map(key => String(info[key])));

async function cloneLedger(archive) {
  const path = join(archive, 'storage', 'input-clones.json');
  if (await absent(path)) return { path, before: null, files: Object.create(null) };
  const info = await canonical(path, 'file');
  requireInput(info.uid === process.getuid() && info.nlink === 1 && !(info.mode & 0o022), 'invalid-clone-ledger');
  const before = await lstat(path, { bigint: true });
  const bytes = await regularBytes(path, 32 * 1024 * 1024), data = JSON.parse(bytes);
  requireInput(data.version === 1 && data.kind === 'scriv-coverage-input-clones' && data.files
    && typeof data.files === 'object' && !Array.isArray(data.files), 'invalid-clone-ledger');
  for (const [target, record] of Object.entries(data.files)) requireInput(!isAbsolute(target)
    && target && relative(archive, resolve(archive, target)) === target && contains(archive, resolve(archive, target))
    && !/[\x00-\x1f\x7f]/.test(target) && record && hex(record.sha256)
    && typeof record.source === 'string' && typeof record.sourceIdentity === 'string'
    && typeof record.targetIdentity === 'string', 'invalid-clone-ledger');
  requireInput(sameFile(before, await lstat(path, { bigint: true })), 'clone-ledger-changed');
  return { path, before, files: data.files };
}

async function rememberedClone(ledger, archive, source, target) {
  const key = relative(archive, target.absolute), record = Object.hasOwn(ledger.files, key) ? ledger.files[key] : undefined;
  if (record?.sha256 !== target.sha256 || record.source !== relative(archive, source.absolute)) return false;
  return record.sourceIdentity === fileIdentity(await lstat(source.absolute, { bigint: true }))
    && record.targetIdentity === fileIdentity(await lstat(target.absolute, { bigint: true }));
}

async function saveCloneLedger(archive, ledger) {
  const directory = join(archive, 'storage'); await privateDirectory(directory);
  const bytes = JSON.stringify({ version: 1, kind: 'scriv-coverage-input-clones', files: ledger.files }) + '\n';
  requireInput(Buffer.byteLength(bytes) <= 32 * 1024 * 1024, 'clone-ledger-budget-exceeded');
  const staging = await mkdtemp(join(directory, '.clone-ledger-'));
  try {
    const path = join(staging, 'record.json'); await writeFile(path, bytes, { flag: 'wx', mode: 0o600 });
    requireInput(ledger.before ? sameFile(ledger.before, await lstat(ledger.path, { bigint: true })) : await absent(ledger.path), 'clone-ledger-changed');
    await rename(path, ledger.path);
  } finally { await rm(staging, { recursive: true, force: true }); }
}

async function plainMetadata(path) {
  try {
    const [attributes, access, flags] = await Promise.all([
      execute('/usr/bin/xattr', [path], { timeout: 30000, maxBuffer: 65536 }),
      execute('/bin/ls', ['-lde', path], { timeout: 30000, maxBuffer: 65536 }),
      execute('/usr/bin/stat', ['-f', '%f', path], { timeout: 30000, maxBuffer: 65536 }),
    ]);
    if (attributes.stdout.trim() || /^\s*\d+:/m.test(access.stdout)
        || access.stdout.split(/\s+/)[0].includes('+') || flags.stdout.trim() !== '0') return 'extended-metadata-preserved-by-skipping';
    return null;
  } catch { return 'metadata-inspection-unavailable'; }
}

async function cloneLegacyFile(source, target, expectedSHA256) {
  await canonical(source, 'file');
  await canonical(target, 'file');
  const [beforeSource, beforeTarget] = await Promise.all([lstat(source, { bigint: true }), lstat(target, { bigint: true })]);
  if (![beforeSource, beforeTarget].every(info => info.isFile() && info.nlink === 1n
    && info.uid === BigInt(process.getuid()) && !(info.mode & 0o7000n))) return { skipped: 'owned-independent-regular-files-required' };
  if (beforeSource.dev !== beforeTarget.dev) return { skipped: 'different-filesystems' };
  // A manifest check earlier in the scan cannot authorize overwriting a file
  // edited since that check. Bind both current files before staging anything.
  requireInput(await hashFile(source) === expectedSHA256 && await hashFile(target) === expectedSHA256
    && sameFile(beforeSource, await lstat(source, { bigint: true }))
    && sameFile(beforeTarget, await lstat(target, { bigint: true })), 'clone-input-changed');
  for (const path of [source, target]) {
    const reason = await plainMetadata(path);
    if (reason) return { skipped: reason };
  }
  const staging = await mkdtemp(join(dirname(target), '.scriv-source-clone-'));
  let replaced = false;
  try {
    const candidate = join(staging, 'copy');
    await execute('/bin/cp', ['-c', source, candidate], { timeout: 30000, maxBuffer: 65536 });
    await chmod(candidate, Number(beforeTarget.mode & 0o7777n));
    const copied = await lstat(candidate, { bigint: true });
    if (copied.uid !== beforeTarget.uid || copied.gid !== beforeTarget.gid) {
      await chown(candidate, Number(beforeTarget.uid), Number(beforeTarget.gid));
    }
    // touch -r retains the original timestamp precision; no guessed Date roundtrip.
    await execute('/usr/bin/touch', ['-r', target, candidate], { timeout: 30000, maxBuffer: 65536 });
    const current = await lstat(candidate, { bigint: true });
    requireInput(current.isFile() && current.nlink === 1n && current.ino !== beforeSource.ino
      && ['mode', 'uid', 'gid', 'size', 'mtimeNs'].every(key => current[key] === beforeTarget[key])
      && await hashFile(candidate) === expectedSHA256, 'clone-content-or-metadata-mismatch');
    for (const path of [source, target, candidate]) {
      const reason = await plainMetadata(path);
      if (reason) return { skipped: reason };
    }
    requireInput(sameFile(beforeSource, await lstat(source, { bigint: true }))
      && sameFile(beforeTarget, await lstat(target, { bigint: true })), 'clone-input-changed');
    await canonical(source, 'file'); await canonical(target, 'file');
    await rename(candidate, target);
    replaced = true;
    requireInput(await hashFile(target) === expectedSHA256, 'clone-verification-failed');
    return { replaced: true };
  } catch (error) {
    if (replaced) { error.mutated = true; throw error; }
    return { skipped: error.message?.startsWith('coverage-storage-') ? error.message : 'filesystem-clone-unavailable' };
  } finally {
    try { await rm(staging, { recursive: true, force: true }); }
    catch (error) { error.mutated = replaced; throw error; }
  }
}

async function gitObjects(sourceRoot) {
  const root = join(sourceRoot, '.git'), owner = await canonical(root, 'directory');
  requireInput(owner.uid === process.getuid(), 'owned-git-directory-required');
  const entries = [['.', owner.mode & 0o7777, owner.uid, owner.gid, 'directory']], files = [];
  let count = 0, bytes = 0;
  const objectPath = /^(?:objects\/[a-f0-9]{2}\/(?:[a-f0-9]{38}|[a-f0-9]{62})|objects\/pack\/pack-(?:[a-f0-9]{40}|[a-f0-9]{64})\.(?:pack|idx|rev))$/;
  async function walk(directory) {
    const names = (await readdir(directory)).sort();
    for (const name of names) {
      const absolute = join(directory, name), path = relative(root, absolute), info = await lstat(absolute, { bigint: true });
      requireInput(++count <= 20000 && !/[\x00-\x1f\x7f]/.test(path)
        && info.uid === BigInt(process.getuid()) && await realpath(absolute) === absolute, 'git-tree-bound-or-unsafe-entry');
      requireInput(!path.endsWith('.lock'), 'git-tree-has-active-lock');
      if (info.isDirectory()) {
        entries.push([path, Number(info.mode & 0o7777n), Number(info.uid), Number(info.gid), 'directory']);
        await walk(absolute);
      } else {
        requireInput(info.isFile() && info.size <= 2n * 1024n ** 3n, 'git-tree-special-or-oversized-file');
        bytes += Number(info.size); requireInput(bytes <= 4 * 1024 ** 3, 'git-tree-budget-exceeded');
        const sha256 = await hashFile(absolute);
        requireInput(sameFile(info, await lstat(absolute, { bigint: true })), 'git-tree-changed-during-inspection');
        // Inodes/ctimes change when independently cloning. File bytes, modes,
        // ownership and precise mtimes remain fixed; directory mtimes are not
        // a Git data identity and may reflect the temporary staging entry.
        entries.push([path, Number(info.mode & 0o7777n), Number(info.uid), Number(info.gid),
          String(info.mtimeNs), String(info.nlink), sha256]);
        if (objectPath.test(path)) files.push({ path, absolute, sha256, root,
          info: { size: Number(info.size) } });
      }
    }
  }
  await walk(root);
  return { root, sourceRoot, files, treeSHA256: sha(JSON.stringify(entries)), entries: count, sourceBytes: bytes };
}

/** Deduplicate bytes in place; never relocate paths referenced by old receipts. */
export async function deduplicateLegacyInputs({ archive, sourceRoots = [], apps = [], apply = false }) {
  await archiveRoot(archive);
  requireInput(Array.isArray(sourceRoots) && Array.isArray(apps) && typeof apply === 'boolean', 'invalid-legacy-inputs');
  const groups = new Map(), sources = [], seen = new Map(), skipped = [], invalidRoots = new Set(), seenFiles = new Set();
  const appGroups = new Map(), verifiedApps = [], seenApps = new Map(), invalidApps = new Set();
  const gitGroups = new Map(), verifiedGit = [], invalidGit = new Set();
  const postVerificationFailures = [];
  for (const item of sourceRoots) {
    try {
      requireInput(typeof item?.root === 'string' && typeof item.manifest === 'string'
        && contains(archive, item.root) && item.root !== archive && contains(archive, item.manifest), 'legacy-input-outside-archive-retained');
      requireInput(item.gitObjects === undefined || typeof item.gitObjects === 'boolean', 'invalid-git-object-opt-in');
      if (seen.has(item.root)) {
        requireInput(seen.get(item.root) === item.manifestSHA256
          && sha(await regularBytes(item.manifest)) === item.manifestSHA256, 'conflicting-legacy-source-identity');
        if (item.gitObjects === true) sources.find(source => source.root === item.root).gitObjects = true;
        continue;
      }
      const input = await sourceInput(item.root, item.manifest, item.manifestSHA256);
      seen.set(item.root, item.manifestSHA256);
      sources.push({ ...item });
      for (const file of input.files) {
        if (!file.info.size || seenFiles.has(file.absolute)) continue;
        seenFiles.add(file.absolute);
        const key = `${file.sha256}:${file.info.size}`;
        if (!groups.has(key)) groups.set(key, []);
        groups.get(key).push({ ...file, root: item.root });
      }
    } catch (error) {
      invalidRoots.add(item?.root ?? '(invalid-source-descriptor)');
      skipped.push({ path: item?.root ?? null, inputVerified: false, reason: error.message });
    }
  }
  for (const item of sources.filter(item => item.gitObjects === true && !invalidRoots.has(item.root))) {
    try {
      const inspected = await gitObjects(item.root);
      verifiedGit.push(inspected);
      for (const file of inspected.files) {
        const key = `${file.sha256}:${file.info.size}`;
        if (!gitGroups.has(key)) gitGroups.set(key, []);
        gitGroups.get(key).push(file);
      }
    } catch (error) {
      invalidGit.add(join(item.root, '.git'));
      skipped.push({ path: join(item.root, '.git'), inputVerified: false, reason: error.message });
    }
  }
  for (const item of apps) {
    const app = typeof item === 'string' ? item : item?.app;
    try {
      requireInput(process.platform === 'darwin', 'legacy-build-signature-verification-requires-macos');
      requireInput(typeof app === 'string' && contains(archive, app) && app !== archive
        && typeof item.buildRecord === 'string' && contains(archive, item.buildRecord)
        && !contains(app, item.buildRecord), 'registered-archived-app-and-build-record-required');
      const recordBytes = await regularBytes(item.buildRecord, 65536), record = JSON.parse(recordBytes);
      requireInput(record.version === 1 && record.kind === 'scriv-coverage-build' && record.sourceUnchanged === true
        && record.coveragePrefix === '/scriv-source/' && hex(record.sourceManifestSha256)
        && hex(record.executableSha256), 'invalid-build-record');
      const recordSHA256 = sha(recordBytes);
      if (seenApps.has(app)) {
        requireInput(seenApps.get(app) === recordSHA256, 'conflicting-legacy-build-identity');
        continue;
      }
      await signature(app);
      const files = [], identity = await bundleIdentity(app, false, files);
      requireInput(identity.executableSHA256 === record.executableSha256, 'build-executable-mismatch');
      const key = sha(JSON.stringify([identity, recordSHA256]));
      const verified = { app, buildRecord: item.buildRecord, recordSHA256, identity, files };
      if (!appGroups.has(key)) appGroups.set(key, []);
      appGroups.get(key).push(verified);
      seenApps.set(app, recordSHA256);
      verifiedApps.push(verified);
    } catch (error) {
      invalidApps.add(app ?? '(invalid-build-descriptor)');
      skipped.push({ path: app ?? null, inputVerified: false, reason: error.message });
    }
  }
  const candidates = [];
  let skippedSmallFiles = 0, skippedSmallLogicalBytes = 0;
  function candidate(kind, source, target) {
    if (target.info.size < minimumCloneBytes) {
      skippedSmallFiles++; skippedSmallLogicalBytes += target.info.size;
    } else candidates.push({ kind, source, target });
  }
  const shared = join(archive, 'shared');
  for (const group of groups.values()) {
    const files = group.filter(file => !invalidRoots.has(file.root));
    files.sort((a, b) => Number(contains(shared, b.absolute)) - Number(contains(shared, a.absolute))
      || a.absolute.localeCompare(b.absolute));
    for (const target of files.slice(1)) candidate('source', files[0], target);
  }
  for (const group of appGroups.values()) {
    const bundles = group.filter(item => !invalidApps.has(item.app)).sort((a, b) =>
      Number(contains(shared, b.app)) - Number(contains(shared, a.app)) || a.app.localeCompare(b.app));
    if (bundles.length < 2) continue;
    const first = bundles[0], files = new Map(first.files.map(file => [file.path, file]));
    for (const bundle of bundles.slice(1)) for (const target of bundle.files) {
      if (!target.info.size) continue;
      const source = files.get(target.path);
      requireInput(source?.sha256 === target.sha256, 'matching-bundle-file-required');
      candidate('app', { ...source, root: first.app }, { ...target, root: bundle.app });
    }
  }
  for (const files of gitGroups.values()) {
    files.sort((a, b) => a.absolute.localeCompare(b.absolute));
    for (const target of files.slice(1)) candidate('git', files[0], target);
  }
  const invalidFor = kind => kind === 'app' ? invalidApps : kind === 'git' ? invalidGit : invalidRoots;
  let filesDeduplicated = 0, clonedLogicalBytes = 0, alreadyClonedFiles = 0, ledger;
  const remembered = new Set(), newlyCloned = [];
  if (process.platform === 'darwin') {
    try { ledger = await cloneLedger(archive); }
    catch (error) { skipped.push({ path: 'storage/input-clones.json', inputVerified: false, reason: error.message }); }
    if (ledger) for (const { source, target } of candidates) {
      try {
        if (await rememberedClone(ledger, archive, source, target)) {
          alreadyClonedFiles++; remembered.add(target.absolute);
        }
      } catch { /* A changed or missing file is rechecked before any mutation. */ }
    }
  }
  if (apply && process.platform === 'darwin' && ledger) {
    for (const { kind, source, target } of candidates) {
      const invalid = invalidFor(kind);
      if (invalid.has(source.root) || invalid.has(target.root) || remembered.has(target.absolute)) continue;
      let replaced = false;
      try {
        const result = await cloneLegacyFile(source.absolute, target.absolute, target.sha256);
        if (result.replaced) {
          replaced = true;
          filesDeduplicated++; clonedLogicalBytes += target.info.size;
          newlyCloned.push({ kind, source, target, record: { sha256: target.sha256, source: relative(archive, source.absolute),
            sourceIdentity: fileIdentity(await lstat(source.absolute, { bigint: true })),
            targetIdentity: fileIdentity(await lstat(target.absolute, { bigint: true })) } });
        }
        else skipped.push({ path: relative(archive, target.absolute), reason: result.skipped });
      } catch (error) {
        invalid.add(source.root); invalid.add(target.root);
        skipped.push({ path: relative(archive, target.absolute), inputVerified: false, reason: error.message });
        if (replaced || error.mutated) postVerificationFailures.push({ path: relative(archive, target.absolute),
          phase: 'clone-replacement', reason: error.message });
      }
    }
  }
  for (const item of sources) {
    try { await verifySourceManifest(item.root, item.manifest, item.manifestSHA256); }
    catch (error) {
      invalidRoots.add(item.root);
      skipped.push({ path: item.root, inputVerified: false, reason: error.message });
      postVerificationFailures.push({ path: item.root, phase: 'source-manifest', reason: error.message });
    }
  }
  // Per-file atomic replacement leaves signed directories and framework links
  // untouched. Recheck the entire signed bundle, including unmodified entries.
  for (const item of verifiedApps) {
    try {
      await signature(item.app);
      requireInput(JSON.stringify(await bundleIdentity(item.app)) === JSON.stringify(item.identity)
        && sha(await regularBytes(item.buildRecord, 65536)) === item.recordSHA256, 'legacy-build-changed');
    } catch (error) {
      invalidApps.add(item.app);
      skipped.push({ path: item.app, inputVerified: false, reason: error.message });
      postVerificationFailures.push({ path: item.app, phase: 'signed-build', reason: error.message });
    }
  }
  for (const item of verifiedGit) {
    try { requireInput((await gitObjects(item.sourceRoot)).treeSHA256 === item.treeSHA256, 'git-tree-changed'); }
    catch (error) {
      invalidGit.add(item.root);
      skipped.push({ path: item.root, inputVerified: false, reason: error.message });
      postVerificationFailures.push({ path: item.root, phase: 'git-tree', reason: error.message });
    }
  }
  let ledgerChanged = false;
  for (const { kind, source, target, record } of newlyCloned) {
    const invalid = invalidFor(kind);
    if (invalid.has(source.root) || invalid.has(target.root)) continue;
    try {
      requireInput(record.sourceIdentity === fileIdentity(await lstat(source.absolute, { bigint: true }))
        && record.targetIdentity === fileIdentity(await lstat(target.absolute, { bigint: true })),
      'clone-identity-changed-after-verification');
      ledger.files[relative(archive, target.absolute)] = record; ledgerChanged = true;
    } catch (error) {
      invalid.add(source.root); invalid.add(target.root);
      skipped.push({ path: relative(archive, target.absolute), inputVerified: false, reason: error.message });
      postVerificationFailures.push({ path: relative(archive, target.absolute), phase: 'clone-ledger-identity', reason: error.message });
    }
  }
  if (ledgerChanged) await saveCloneLedger(archive, ledger);
  return { mode: apply ? 'apply' : 'preview', available: process.platform === 'darwin',
    ...(process.platform !== 'darwin' && { unavailableReason: 'Independent APFS clone deduplication requires macOS; no files were changed.' }),
    candidateFiles: candidates.length, candidateLogicalBytes: candidates.reduce((total, { target }) => total + target.info.size, 0),
    minimumCloneBytes, skippedSmallFiles, skippedSmallLogicalBytes,
    filesDeduplicated, alreadyClonedFiles, clonedLogicalBytes, reclaimedBytes: null, postVerificationFailures,
    allocationNotice: 'Logical clone bytes are not reclaimed disk bytes. Measure volume free space separately; APFS files can share extents.',
    sourceRootsVerified: sources.filter(item => !invalidRoots.has(item.root)).length,
    unverifiedSourceRoots: invalidRoots.size, appsVerified: verifiedApps.filter(item => !invalidApps.has(item.app)).length,
    unverifiedApps: invalidApps.size, gitRootsVerified: verifiedGit.filter(item => !invalidGit.has(item.root)).length,
    unverifiedGitRoots: invalidGit.size, gitInspectionLimits: { entries: 20000, fileBytes: 2 * 1024 ** 3, treeBytes: 4 * 1024 ** 3 }, skipped };
}
