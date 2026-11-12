import { constants } from 'node:fs';
import { open, lstat, realpath } from 'node:fs/promises';
import { basename, isAbsolute, join } from 'node:path';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const fail = () => { throw new Error('owned-workspace-unavailable'); };
const same = (a, b) => a.dev === b.dev && a.ino === b.ino;
const privateDirectory = info => info.isDirectory() && !info.isSymbolicLink()
  && info.uid === BigInt(process.getuid()) && (info.mode & 0o7777n) === 0o700n;
const privateFile = info => info.isFile() && !info.isSymbolicLink() && info.nlink === 1n
  && info.uid === BigInt(process.getuid()) && (info.mode & 0o7777n) === 0o600n;

// Host-side ownership checks do not grant resume authority. The actual app
// independently validates the inherited descriptor, its lock and descendants.
export async function retainOwnedWorkspace(root, runID) {
  if (!UUID.test(runID) || typeof root !== 'string' || !isAbsolute(root)
      || basename(root) !== `ScrivVerification-CLI-${runID}` || await realpath(root) !== root) fail();
  const before = await lstat(root, { bigint: true });
  if (!privateDirectory(before)) fail();
  const handle = await open(root, constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW);
  try {
    const identity = await handle.stat({ bigint: true });
    if (!privateDirectory(identity) || !same(before, identity)) fail();
    const lease = { root, runID, handle, identity };
    lease.files = await validateOwnedWorkspace(lease);
    return lease;
  } catch (error) { await handle.close(); throw error; }
}

export async function validateOwnedWorkspace(lease) {
  const { root, runID, handle, identity } = lease;
  const files = {};
  const opened = await handle.stat({ bigint: true }), named = await lstat(root, { bigint: true });
  if (!privateDirectory(opened) || !privateDirectory(named) || !same(opened, identity)
      || !same(named, identity) || await realpath(root) !== root) fail();
  for (const name of ['.scriv-cli-persistent', '.scriv-cli-session.lock']) {
    const path = join(root, name), before = await lstat(path, { bigint: true });
    if (!privateFile(before)) fail();
    const file = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    try {
      const info = await file.stat({ bigint: true });
      if (!privateFile(info) || !same(before, info) || lease.files && !same(lease.files[name], info)) fail();
      files[name] = info;
      if (name === '.scriv-cli-persistent') {
        const expected = Buffer.from(`ScrivCLIWorkspace-v1\n${runID}\n`);
        if (info.size !== BigInt(expected.length)) fail();
        const bytes = Buffer.alloc(expected.length + 1);
        const { bytesRead } = await file.read(bytes, 0, bytes.length, 0);
        if (bytesRead !== expected.length || !bytes.subarray(0, bytesRead).equals(expected)) fail();
      } else if (info.size !== 0n) fail();
      if (!same(await lstat(path, { bigint: true }), info)) fail();
    } finally { await file.close(); }
  }
  const after = await lstat(root, { bigint: true });
  if (!same(after, identity) || !privateDirectory(after) || await realpath(root) !== root) fail();
  return files;
}

// Public read-only diagnostic for actual filesystem boundaries. It cannot
// export a lease, start an app, reset data, or authorize path-based resumption.
export async function inspectOwnedWorkspace(root) {
  const prefix = 'ScrivVerification-CLI-', name = typeof root === 'string' ? basename(root) : '';
  if (!name.startsWith(prefix)) fail();
  let lease;
  try {
    lease = await retainOwnedWorkspace(root, name.slice(prefix.length));
    return { kind: 'owned-synthetic-workspace-inspection', hostOwnership: 'valid',
      nativeDescendantsAndLock: 'not-validated', retainedProcessLease: false, resumeAuthorized: false };
  } catch { fail(); }
  finally { await lease?.handle.close(); }
}
