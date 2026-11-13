// Opt-in observation of a genuine ScrivSession. No app substitute or reset.
import { createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { lstat, realpath, readFile, writeFile, mkdir, rename } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { captureProfile } from './coverage-profile.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const hex = value => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);
const uuid = value => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value);
const fail = () => { throw new Error('coverage-session-unavailable'); };
export async function hashFile(path) {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(path)) hash.update(chunk);
  return hash.digest('hex');
}
export async function probeIdentity() {
  const files = [];
  for (const path of ['cli/scriv.mjs', 'cli/owned-workspace.mjs', 'cli/scenario-restrictions.mjs', 'cli/coverage-profile.mjs', 'cli/coverage-session.mjs', 'scripts/run-cli-e2e.mjs', 'scripts/collect-cli-coverage.mjs', 'scripts/export-cli-source-manifest.mjs', 'scripts/prepare-coverage-analysis.mjs']) files.push({ path, sha256: await hashFile(join(root, path)) });
  return { files, sha256: createHash('sha256').update(JSON.stringify(files)).digest('hex') };
}
async function privateDirectory(path) {
  const info = await lstat(path);
  if (!info.isDirectory() || info.isSymbolicLink() || (info.mode & 0o077) || info.uid !== process.getuid() || await realpath(path) !== path) fail();
  return info;
}

export async function observeSession(session, executable, capabilities) {
  const contextPath = process.env.SCRIV_E2E_COVERAGE_CONTEXT;
  if (!contextPath) return null;
  const contextInfo = await lstat(contextPath);
  if (!contextInfo.isFile() || contextInfo.isSymbolicLink() || contextInfo.size > 65536 || (contextInfo.mode & 0o077) || contextInfo.uid !== process.getuid() || await realpath(contextPath) !== contextPath) fail();
  const context = JSON.parse(await readFile(contextPath, 'utf8'));
  const directory = dirname(contextPath);
  const owner = await privateDirectory(directory);
  if (directory === root || directory.startsWith(root + '/') || context.version !== 1 || !uuid(context.invocationID)
      || !/^tests\/e2e\/(?:journeys\/)?[A-Za-z0-9_-]+\.mjs$/.test(context.scenario)
      || !hex(context.executableSHA256) || !hex(context.sourceManifestSHA256) || !hex(context.buildRecordSHA256)
      || !hex(context.probeSHA256) || !Number.isSafeInteger(context.maximumSessions) || context.maximumSessions < 1 || context.maximumSessions > 64) fail();
  const sessionID = capabilities.sessionID ?? capabilities.runID;
  if (!uuid(capabilities.runID) || !uuid(sessionID) || capabilities.coverage?.schemaVersion !== 1 || capabilities.coverage.format !== 'llvm-profraw'
      || capabilities.coverage.cumulative !== true || capabilities.coverage.maximumSnapshotBytes !== 16 * 1024 * 1024
      || !['coverage-snapshot', 'coverage-read', 'coverage-release'].every(name => capabilities.commands?.includes(name))) fail();
  if (await hashFile(executable) !== context.executableSHA256 || (await probeIdentity()).sha256 !== context.probeSHA256) fail();
  // Slots are reserved atomically across app sessions/processes. Never recycle
  // one after failure: the cap bounds all capture attempts in this invocation.
  const slots = join(directory, 'slots'), sessions = join(directory, 'sessions');
  await privateDirectory(slots); await privateDirectory(sessions);
  let slot = -1;
  for (let index = 0; index < context.maximumSessions; index++) {
    try { await writeFile(join(slots, String(index)), sessionID, { flag: 'wx', mode: 0o600 }); slot = index; break; }
    catch (error) { if (error.code !== 'EEXIST') throw error; }
  }
  if (slot < 0) throw new Error('coverage-session-limit-reached');
  const output = join(sessions, sessionID);
  await mkdir(output, { mode: 0o700 });
  const outputOwner = await privateDirectory(output);
  const ensure = async () => {
    const current = await privateDirectory(directory), currentOutput = await privateDirectory(output);
    if (current.dev !== owner.dev || current.ino !== owner.ino || currentOutput.dev !== outputOwner.dev || currentOutput.ino !== outputOwner.ino) fail();
  };
  const write = async (name, data) => { await ensure(); await writeFile(join(output, name), data, { flag: 'wx', mode: 0o600 }); };
  const commands = [];
  const record = { version: 1, kind: 'scriv-session-coverage', status: 'capturing', invocationID: context.invocationID,
    scenario: context.scenario, runID: sessionID, workspaceID: capabilities.runID, slot, startedAt: new Date().toISOString(), endedAt: null,
    executableSHA256: context.executableSHA256, executableUnchanged: false, sourceManifestSHA256: context.sourceManifestSHA256,
    buildRecordSHA256: context.buildRecordSHA256, probeSHA256: context.probeSHA256, counterMode: 'cumulative', counterReset: false,
    attribution: 'observed-during-session-not-causal', phase: 'before-profile', profiles: {}, commands,
    limitations: ['One interval per actual app session; sessions are never merged.',
      'runID identifies this process capture; workspaceID may recur across an explicitly owned cold relaunch.',
      'Initial launch and isolation handshake precede the before snapshot.',
      'Capture transport, polling and background work overlap; snapshots are not globally atomic.',
      'Ordered command names and completion states are recorded, not parameters or results; this is not a replay recipe.',
      'Expected command errors may pass scenario assertions; command completion alone does not prove assertions.',
      'Session close captures before termination; work after that snapshot is outside the interval.'] };
  const save = async () => {
    await ensure();
    await writeFile(join(output, 'session.json.tmp'), JSON.stringify(record, null, 2) + '\n', { flag: 'wx', mode: 0o600 });
    await rename(join(output, 'session.json.tmp'), join(output, 'session.json'));
  };
  const diagnostic = stage => { record.phase = stage; };
  await save();
  try {
    const before = await captureProfile(session.command.bind(session), sessionID, diagnostic, 'before-profile', capabilities.runID);
    await write('before.profraw', before.buffer);
    record.profiles.before = { file: 'before.profraw', sha256: before.sha256, byteCount: before.byteCount, transferCompletedAt: new Date().toISOString() };
    record.phase = 'scenario'; await save();
  } catch (error) { record.status = 'failed'; record.endedAt = new Date().toISOString(); await save(); throw error; }
  let finishing = null;
  return {
    record(command) {
      if (commands.length >= 32768 || typeof command !== 'string' || !/^[a-z][a-z0-9-]{0,63}$/.test(command)) throw new Error('coverage-command-limit-or-name');
      const item = { ordinal: commands.length + 1, command, status: 'pending' }; commands.push(item);
      return status => { item.status = status; };
    },
    finish() {
      finishing ??= (async () => {
        try {
          if (!commands.length || commands.some(command => command.status === 'pending')) throw new Error('coverage-incomplete-command-sequence');
          const after = await captureProfile(session.command.bind(session), sessionID, diagnostic, 'after-profile', capabilities.runID);
          await write('after.profraw', after.buffer);
          record.profiles.after = { file: 'after.profraw', sha256: after.sha256, byteCount: after.byteCount, transferCompletedAt: new Date().toISOString() };
          if (await hashFile(executable) !== context.executableSHA256 || (await probeIdentity()).sha256 !== context.probeSHA256) fail();
          record.executableUnchanged = true; record.status = 'captured'; record.phase = 'complete';
        } catch (error) { record.status = 'failed'; throw error; }
        finally { record.endedAt = new Date().toISOString(); await save(); }
      })();
      return finishing;
    },
  };
}
