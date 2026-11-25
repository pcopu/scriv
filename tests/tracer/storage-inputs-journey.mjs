/** Public storage CLI fixtures only; no application execution or APFS simulation. */
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash, randomBytes } from 'node:crypto';
import { cp, lstat, mkdir, readFile, rm, symlink, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const absent = async path => lstat(path).then(() => false, error => {
  if (error.code === 'ENOENT') return true;
  throw error;
});

export async function runStorageInputsJourney({ run, output, journey }) {
  const base = join(output, 'storage-inputs'), archive = join(base, 'archive'), source = join(base, 'source');
  await mkdir(base, { mode: 0o700 });
  await mkdir(archive, { mode: 0o700 });
  await mkdir(join(source, 'design'), { recursive: true, mode: 0o700 });
  const contents = new Map([
    ['design/synthetic-image.png', randomBytes(96 * 1024)],
    ['run.sh', Buffer.from('#!/bin/sh\nprintf "synthetic source fixture\\n"\n')],
  ]);
  for (const [path, bytes] of contents) await writeFile(join(source, path), bytes,
    { flag: 'wx', mode: path.endsWith('.sh') ? 0o700 : 0o600 });
  const sourceBytes = [...contents.values()].reduce((total, bytes) => total + bytes.length, 0);
  const manifestBytes = Buffer.from(JSON.stringify({ schemaVersion: 1, kind: 'scriv-exported-source',
    baseCommit: 'a'.repeat(40), deletedTrackedPaths: [],
    files: [...contents].map(([path, bytes]) => ({ path, sha256: sha(bytes) })) }, null, 2) + '\n');
  const manifest = join(base, 'sources.json'), manifestSHA256 = sha(manifestBytes);
  await writeFile(manifest, manifestBytes, { flag: 'wx', mode: 0o600 });
  const command = (mode, args = [], expected = 0) => run(['app', '--', 'test', 'storage', mode, ...args], expected);
  const init = (path, budget) => JSON.parse(command('init', ['--archive', path, '--budget-bytes', String(budget),
    '--run-reserve-bytes', '4096', '--min-free-bytes', '0', '--keep-reports', '1']).stdout);
  const sourceArgs = ['--archive', archive, '--source', source, '--manifest', manifest, '--manifest-sha256', manifestSHA256];
  let shared;

  await journey('share complete pinned source once and preserve independent original bytes', async () => {
    init(archive, 8 * 1024 * 1024);
    shared = JSON.parse(command('source', sourceArgs).stdout);
    assert.equal(shared.created, true);
    assert.equal(shared.sourceBytes, sourceBytes);
    assert.equal(shared.manifestSHA256, manifestSHA256);
    assert.equal(shared.root, join(archive, 'shared', 'sources', manifestSHA256, 'source'));
    assert.deepEqual(await readFile(shared.manifest), manifestBytes);
    assert.doesNotThrow(() => JSON.parse(run(['--root', shared.root, 'report', '--json']).stdout),
      'The returned shared source is a usable public Tracer root');
    const identities = new Map();
    for (const [path, bytes] of contents) {
      const retained = join(shared.root, path), original = await lstat(join(source, path)), copy = await lstat(retained);
      assert.deepEqual(await readFile(retained), bytes);
      assert.equal(copy.nlink, 1);
      assert.notEqual(`${copy.dev}:${copy.ino}`, `${original.dev}:${original.ino}`);
      assert.equal(copy.mode & 0o777, original.mode & 0o777);
      identities.set(path, `${copy.dev}:${copy.ino}`);
    }
    const reused = JSON.parse(command('source', sourceArgs).stdout);
    assert.deepEqual(reused, { ...shared, created: false });
    for (const [path, expected] of identities) {
      const info = await lstat(join(shared.root, path));
      assert.equal(`${info.dev}:${info.ino}`, expected, 'Reuse does not replace previously verified input files');
    }
    const target = join(shared.root, 'run.sh');
    await writeFile(target, 'changed shared copy\n');
    assert.deepEqual(await readFile(join(source, 'run.sh')), contents.get('run.sh'));
    command('source', sourceArgs, 2);
    assert.equal(await readFile(target, 'utf8'), 'changed shared copy\n', 'A stale shared copy is retained for inspection');
    await writeFile(target, contents.get('run.sh'));
  });

  await journey('refuse stale hashes and symlinked source without replacing shared inputs', async () => {
    const sourceFile = join(source, 'run.sh'), retained = join(shared.root, 'run.sh');
    const before = await readFile(retained);
    await writeFile(sourceFile, 'changed original source\n');
    command('source', sourceArgs, 2);
    assert.deepEqual(await readFile(retained), before);
    await writeFile(sourceFile, contents.get('run.sh'));
    command('source', [...sourceArgs.slice(0, -1), '0'.repeat(64)], 2);
    assert.equal(await absent(join(archive, 'shared', 'sources', '0'.repeat(64))), true);
    const linked = join(base, 'source-link');
    await symlink(source, linked);
    command('source', ['--archive', archive, '--source', linked, '--manifest', manifest, '--manifest-sha256', manifestSHA256], 2);
    assert.deepEqual(await readFile(retained), before);
    await rm(linked);
  });

  await journey('reject an oversized new shared input while allowing verified reuse', async () => {
    const small = join(base, 'small-archive'); await mkdir(small, { mode: 0o700 });
    init(small, 64 * 1024);
    command('source', ['--archive', small, '--source', source, '--manifest', manifest, '--manifest-sha256', manifestSHA256], 2);
    assert.equal(await absent(join(small, 'shared', 'sources', manifestSHA256)), true);
    const policyPath = join(archive, 'scriv-storage-policy.json');
    const policy = await readFile(policyPath), data = JSON.parse(policy);
    data.budgetBytes = 4096; data.runReserveBytes = 4096;
    await writeFile(policyPath, JSON.stringify(data) + '\n');
    try {
      assert.equal(JSON.parse(command('audit', ['--archive', archive]).stdout).budget.allowed, false);
      assert.equal(JSON.parse(command('source', sourceArgs).stdout).created, false);
    } finally { await writeFile(policyPath, policy); }
  });

  await journey('retain archived source paths and report unavailable APFS measurement honestly', async () => {
    const legacy = join(archive, 'legacy-source'), legacyManifest = join(archive, 'legacy-sources.json');
    await cp(source, legacy, { recursive: true, errorOnExist: true, force: false });
    await writeFile(legacyManifest, manifestBytes, { flag: 'wx', mode: 0o600 });
    const inputs = join(archive, 'registered-inputs.json');
    const descriptors = [
      { root: shared.root, manifest: shared.manifest, manifestSHA256 },
      { root: legacy, manifest: legacyManifest, manifestSHA256 },
      { root: legacy, manifest: legacyManifest, manifestSHA256 },
    ];
    await writeFile(inputs, JSON.stringify({ version: 1, kind: 'scriv-coverage-storage-inputs', sourceRoots: descriptors, apps: [] }) + '\n',
      { flag: 'wx', mode: 0o600 });
    const args = ['--archive', archive, '--inputs', inputs];
    // This registered-source fixture has no native runs, so no importer is invoked.
    const preview = JSON.parse(command('clean', args).stdout);
    assert.equal(preview.inputs.minimumCloneBytes, 16 * 1024);
    assert.equal(preview.inputs.candidateFiles, 1);
    assert.equal(preview.inputs.candidateLogicalBytes, contents.get('design/synthetic-image.png').length);
    assert.equal(preview.inputs.skippedSmallFiles, 1);
    assert.equal(preview.inputs.sourceRootsVerified, 2);
    const applied = JSON.parse(command('clean', [...args, '--apply']).stdout);
    assert.equal(applied.inputs.reclaimedBytes, null);
    for (const [path, bytes] of contents) {
      assert.deepEqual(await readFile(join(legacy, path)), bytes);
      assert.deepEqual(await readFile(join(shared.root, path)), bytes);
      assert.equal((await lstat(join(legacy, path))).nlink, 1);
    }
    const audit = JSON.parse(command('audit', ['--archive', archive]).stdout);
    assert.equal(audit.inventory.byCategory.design.logicalBytes, 2 * contents.get('design/synthetic-image.png').length);
    if (process.platform !== 'darwin') {
      assert.equal(applied.inputs.available, false);
      assert.equal(applied.inputs.filesDeduplicated, 0);
      assert.equal(audit.physical.status, 'unavailable');
      assert.equal(audit.physical.usedBytes, null);
      assert.equal(audit.physical.freeBytes, null);
    }
    const repeated = JSON.parse(command('clean', [...args, '--apply']).stdout);
    if (applied.inputs.filesDeduplicated) {
      assert.equal(repeated.inputs.filesDeduplicated, 0);
      assert.equal(repeated.inputs.alreadyClonedFiles, applied.inputs.filesDeduplicated);
    }
    await writeFile(inputs, JSON.stringify({ version: 1, kind: 'scriv-coverage-storage-inputs',
      sourceRoots: [{ root: source, manifest, manifestSHA256 }], apps: [] }) + '\n');
    const outside = JSON.parse(command('clean', [...args, '--apply']).stdout);
    assert.equal(outside.inputs.unverifiedSourceRoots, 1);
    assert.equal(outside.inputs.filesDeduplicated, 0);
    assert.equal(outside.inputs.skipped[0].inputVerified, false);
    for (const [path, bytes] of contents) assert.deepEqual(await readFile(join(source, path)), bytes);
  });

  await journey('inspect registered real Git object files while preserving repository metadata', async () => {
    const legacy = join(archive, 'legacy-source'), legacyManifest = join(archive, 'legacy-sources.json');
    const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith('GIT_')));
    const git = (root, args, input) => {
      const result = spawnSync('git', ['-C', root, ...args], { input, env, encoding: 'utf8', timeout: 30000, maxBuffer: 65536 });
      assert.ifError(result.error); assert.equal(result.status, 0, result.stderr); return result.stdout.trim();
    };
    git(legacy, ['-c', 'core.sharedRepository=0', 'init', '--template=', '-q']);
    const first = git(shared.root, ['hash-object', '-w', '--stdin'], contents.get('design/synthetic-image.png'));
    assert.match(first, /^(?:[a-f0-9]{40}|[a-f0-9]{64})$/);
    assert.equal(git(legacy, ['hash-object', '-w', '--stdin'], contents.get('design/synthetic-image.png')), first);
    const preserved = [];
    for (const root of [shared.root, legacy]) for (const name of ['config', 'HEAD']) {
      const path = join(root, '.git', name); preserved.push([path, await readFile(path)]);
    }
    const inputs = join(archive, 'git-inputs.json');
    await writeFile(inputs, JSON.stringify({ version: 1, kind: 'scriv-coverage-storage-inputs', sourceRoots: [
      { root: shared.root, manifest: shared.manifest, manifestSHA256, gitObjects: true },
      { root: legacy, manifest: legacyManifest, manifestSHA256, gitObjects: true },
    ], apps: [] }) + '\n', { flag: 'wx', mode: 0o600 });
    const args = ['--archive', archive, '--inputs', inputs];
    const preview = JSON.parse(command('clean', args).stdout);
    assert.equal(preview.inputs.gitRootsVerified, 2);
    assert.equal(preview.inputs.unverifiedGitRoots, 0);
    assert.equal(preview.inputs.candidateFiles, 2, 'Both the design asset and real loose Git object are duplicate large files');
    const applied = JSON.parse(command('clean', [...args, '--apply']).stdout);
    assert.equal(applied.inputs.gitRootsVerified, 2);
    for (const [path, bytes] of preserved) assert.deepEqual(await readFile(path), bytes);
    for (const root of [shared.root, legacy]) {
      assert.equal(git(root, ['cat-file', '-s', first]), String(contents.get('design/synthetic-image.png').length));
      assert.equal(await absent(join(root, '.git', 'index')), true, 'No index, commit, ref or configuration is rewritten');
    }
    if (process.platform !== 'darwin') assert.equal(applied.inputs.filesDeduplicated, 0);
  });

  await journey('discover guarded build-work cleanup without starting a native build', async () => {
    const builder = fileURLToPath(new URL('../../scripts/rebuild-catalyst-cli.py', import.meta.url));
    const help = spawnSync('python3', [builder, '--help'], { encoding: 'utf8', timeout: 30000, maxBuffer: 65536 });
    assert.ifError(help.error); assert.equal(help.status, 0, help.stderr);
    assert.match(help.stdout, /--discard-work-after-build/);
    const unused = join(base, 'unused-native-input');
    const rejected = spawnSync('python3', [builder, '--discard-work-after-build', '--sparkle-framework', unused,
      '--template', unused, '--output', unused, '--work', unused, '--identity', 'synthetic-unused-fixture', '--version', '1', '--build', '1'],
    { encoding: 'utf8', timeout: 30000, maxBuffer: 65536 });
    assert.ifError(rejected.error); assert.equal(rejected.status, 2);
    assert.match(rejected.stderr, /--discard-work-after-build requires a verified coverage build record/);
    assert.equal(await absent(unused), true);
  });

  await journey('run the real Scriv CLI from its verified shared source inside the managed archive', async () => {
    const repository = fileURLToPath(new URL('../../', import.meta.url));
    const fixture = join(base, 'current-cli-source'); await mkdir(fixture, { mode: 0o700 });
    // Copy the current real front door and its dependencies, without an app or
    // replacement implementation. The denied native selector never launches.
    for (const path of ['cli', 'scripts', 'tests/e2e', 'tracer.json']) {
      await cp(join(repository, path), join(fixture, path), { recursive: true, dereference: false });
    }
    const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith('GIT_')));
    const spawn = (executable, args) => {
      const result = spawnSync(executable, args, { cwd: fixture, env, encoding: 'utf8', timeout: 30000, maxBuffer: 1024 * 1024 });
      assert.ifError(result.error); assert.equal(result.status, 0, result.stderr); return result;
    };
    spawn('git', ['-c', 'core.sharedRepository=0', 'init', '--template=', '-q']);
    spawn('git', ['add', '.']);
    spawn('git', ['-c', 'core.hooksPath=/dev/null', '-c', 'commit.gpgsign=false', '-c', 'user.name=Synthetic Fixture',
      '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'Owned current CLI fixture']);
    const currentManifest = join(base, 'current-cli-sources.json');
    const exported = JSON.parse(spawn(process.execPath, ['scripts/export-cli-source-manifest.mjs', '--output', currentManifest]).stdout);
    const sharedCLI = JSON.parse(command('source', ['--archive', archive, '--source', fixture,
      '--manifest', currentManifest, '--manifest-sha256', exported.manifestSHA256]).stdout);
    const nested = (args, expected = 0, root = sharedCLI.root) => run(['--root', root, 'app', '--', ...args], expected);
    const auditArgs = ['test', 'storage', 'audit', '--archive', archive];
    assert.equal(JSON.parse(nested(auditArgs).stdout).archive, archive);
    const runs = join(archive, 'runs'); await mkdir(runs, { mode: 0o700 });
    const blocked = nested(['test', '--scenario', 'character-aliases', '--source-manifest', sharedCLI.manifest,
      '--source-manifest-sha256', sharedCLI.manifestSHA256, '--output-dir', runs], 2);
    const match = /evidence: (.+)\n?$/.exec(blocked.stdout); assert.ok(match);
    const receiptPath = match[1].trim(), receipt = JSON.parse(await readFile(receiptPath));
    assert.equal(receipt.status, 'not-run'); assert.equal(receipt.blocker, 'selected-scenarios-blocked');
    assert.equal(receipt.app, null); assert.equal(receipt.fullSuitePassed, false);
    assert.equal(receipt.scenarios[0].startedAt, undefined);
    const storagePath = receiptPath.slice(0, -'evidence.json'.length) + 'storage.json';
    const storage = JSON.parse(await readFile(storagePath));
    assert.equal(storage.cleanup.status, 'partial'); assert.equal(storage.cleanup.skippedRuns, 1);
    assert.equal(await absent(join(archive, 'storage', 'archive.lock')), true);

    const retained = await readFile(sharedCLI.manifest);
    await writeFile(sharedCLI.manifest, Buffer.concat([retained, Buffer.from('\n')]));
    try { assert.match(nested(auditArgs, 2).stderr, /shared-source-layout-manifest-mismatch/); }
    finally { await writeFile(sharedCLI.manifest, retained); }
    assert.equal(JSON.parse(nested(auditArgs).stdout).archive, archive);
    const unmanaged = join(archive, 'unmanaged-current-cli');
    await cp(fixture, unmanaged, { recursive: true, dereference: false });
    assert.match(nested(auditArgs, 2, unmanaged).stderr, /nested-repository-is-not-verified-shared-source/);
    assert.deepEqual(await readFile(sharedCLI.manifest), retained);
  });
  await rm(base, { recursive: true }); // Only this journey's explicitly synthetic owned fixtures.
}
