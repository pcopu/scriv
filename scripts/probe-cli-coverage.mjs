#!/usr/bin/env node
// Optional actual-app smoke probe. Never imported by the ordinary E2E suite.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { createReadStream, realpathSync } from 'node:fs';
import { mkdir, lstat, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { ScrivSession } from '../cli/scriv.mjs';
import { captureProfile } from '../cli/coverage-profile.mjs';
export { captureProfile } from '../cli/coverage-profile.mjs';

const MAX_BYTES = 16 * 1024 * 1024;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const help = `Usage: node scripts/probe-cli-coverage.mjs --app /path/ScrivCoverage.app --output /path/NEW-directory
Requires the optional --automation --coverage build. Launches an isolated app,
selects workspace tabs 1 then 0 once each, and exports two cumulative profiles
via bounded stdio chunks. No app-container contents are read. Output must not exist.
Coverage is observed during the sequence, NOT causal: polling, transport and
background execution overlap; snapshots are not globally atomic. No counter reset.
This optional smoke probe is not a regression-suite coverage/retirement claim.
After success, manually use compatible tools and the EXACT instrumented executable:
  llvm-profdata merge -sparse OUTPUT/before.profraw -o OUTPUT/before.profdata
  llvm-profdata merge -sparse OUTPUT/after.profraw -o OUTPUT/after.profdata
  llvm-cov export APP/Contents/MacOS/Scriv -instr-profile=OUTPUT/before.profdata > OUTPUT/before.json
  llvm-cov export APP/Contents/MacOS/Scriv -instr-profile=OUTPUT/after.profdata > OUTPUT/after.json
Index separately; never merge these cumulative snapshots together. Compare counts
for matching source regions, not raw bytes or just covered-line sets. Tool version
compatibility must be verified; these commands are NOT run by this script.`;

async function fileHash(path) {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(path)) hash.update(chunk);
  return hash.digest('hex');
}


export async function collectSequence(session, diagnostic = () => {}) {
  const commands = [];
  let phase = 'setup';
  const command = async (name, parameters = {}) => {
    const record = { ordinal: commands.length + 1, command: name, phase, status: 'pending' };
    commands.push(record);
    try { const result = await session.command(name, parameters); record.status = 'completed'; return result; }
    catch (error) { record.status = 'failed-or-uncertain'; throw error; }
  };
  diagnostic('setup', 'capabilities');
  const capability = await command('capabilities');
  assert.match(capability.runID, UUID);
  const sessionID = capability.sessionID ?? capability.runID;
  assert.match(sessionID, UUID);
  assert.equal(capability.coverage?.schemaVersion, 1);
  assert.equal(capability.coverage?.format, 'llvm-profraw');
  assert.equal(capability.coverage?.cumulative, true);
  assert.equal(capability.coverage?.maximumSnapshotBytes, MAX_BYTES);
  for (const name of ['coverage-snapshot', 'coverage-read', 'coverage-release']) assert.ok(capability.commands.includes(name));
  async function ready(index) {
    const deadline = Date.now() + 15000;
    do {
      const nodes = await command('snapshot');
      if (nodes.some(node => node.identifier === 'workspace-tabs' && node.enabled === true && node.hittable === true
        && Array.isArray(node.segments) && node.segments.length >= 2 && (index === undefined || node.selected === index))) return;
      await new Promise(resolve => setTimeout(resolve, 50));
    } while (Date.now() < deadline);
    throw new Error('Workspace tab postcondition timed out; no action retry');
  }
  diagnostic('setup', 'snapshot');
  await ready();
  phase = 'before-export';
  const before = await captureProfile(command, sessionID, diagnostic, 'before-snapshot', capability.runID);
  phase = 'sequence';
  diagnostic('select1', 'select');
  await command('select', { target: 'workspace-tabs', index: 1 });
  diagnostic('select1', 'snapshot'); await ready(1);
  diagnostic('select0', 'select');
  await command('select', { target: 'workspace-tabs', index: 0 });
  diagnostic('select0', 'snapshot'); await ready(0);
  phase = 'after-export';
  const after = await captureProfile(command, sessionID, diagnostic, 'after-snapshot', capability.runID);
  return { before, after, manifest: {
    schemaVersion: 1, probe: 'workspace-tabs-1-then-0', runID: sessionID, workspaceID: capability.runID,
    attribution: 'observed-during-sequence-not-causal', cumulative: true, counterReset: false,
    limitations: ['Transport, polling, capture and background work overlap the window.',
      'Snapshots are not globally atomic; inconsistent deltas are ambiguous.',
      'Session launch capability handshake precedes the recorded local ordinals.',
      'Local ordinals are not protocol request IDs. No raw parameters or UI data are retained.',
      'Only instrumented app/Core code is measured; execution does not establish assertions or retirement.'],
    sequence: [{ name: 'select-workspace-tab-1', command: 'select', index: 1 },
      { name: 'select-workspace-tab-0', command: 'select', index: 0 }], commands,
    profiles: Object.fromEntries([['before', before], ['after', after]].map(([name, p]) =>
      [name, { file: `${name}.profraw`, byteCount: p.byteCount, sha256: p.sha256 }])),
  } };
}

async function main(args, diagnostic) {
  if (args.length === 1 && args[0] === '--help') { console.log(help); return; }
  assert.equal(args.length, 4, help);
  const options = {};
  for (let i = 0; i < args.length; i += 2) {
    assert.ok(['--app', '--output'].includes(args[i]) && !Object.hasOwn(options, args[i]), help);
    options[args[i]] = args[i + 1];
  }
  assert.ok(options['--app'] && options['--output'], help);
  const app = resolve(options['--app']), output = resolve(options['--output']);
  await mkdir(output, { mode: 0o700 }); // Exclusive, no recursive directory creation.
  const owned = await lstat(output);
  assert.ok(owned.isDirectory() && !owned.isSymbolicLink() && (owned.mode & 0o077) === 0);
  const write = async (name, data) => {
    const current = await lstat(output);
    assert.ok(current.dev === owned.dev && current.ino === owned.ino && current.uid === owned.uid
      && current.isDirectory() && !current.isSymbolicLink() && (current.mode & 0o077) === 0);
    await writeFile(join(output, name), data, { flag: 'wx', mode: 0o600 });
  };
  const executableSHA256 = await fileHash(join(app, 'Contents/MacOS/Scriv'));
  const probeSourceSHA256 = await fileHash(fileURLToPath(import.meta.url));
  const session = await ScrivSession.launch(app);
  let closeAttempted = false, primaryFailure = false;
  try {
    const { before, after, manifest } = await collectSequence(session, diagnostic);
    diagnostic('write', 'verify-executable');
    const executableSHA256After = await fileHash(join(app, 'Contents/MacOS/Scriv'));
    assert.equal(executableSHA256After, executableSHA256);
    manifest.executableSHA256After = executableSHA256After;
    manifest.executableUnchanged = true;
    manifest.executableSHA256 = executableSHA256;
    manifest.probeSourceSHA256 = probeSourceSHA256;
    manifest.applicationSourceSHA256 = null; // Not inferred from an unrelated checkout.
    diagnostic('write', 'close-owned-app');
    closeAttempted = true;
    await session.close();
    diagnostic('write', 'write-output');
    await write('before.profraw', before.buffer); await write('after.profraw', after.buffer);
    await write('manifest.json', JSON.stringify(manifest, null, 2) + '\n');
    console.log('Exported before.profraw, after.profraw and manifest.json. LLVM decoding remains unverified; see --help.');
  } catch (error) {
    primaryFailure = true;
    throw error;
  } finally {
    if (!closeAttempted) {
      closeAttempted = true;
      try { await session.close(); }
      catch (error) { if (!primaryFailure) throw error; }
    }
  }
}
// Node resolves module URLs through symlinks, while argv may retain /tmp.
// Compare canonical paths so a direct invocation never silently skips main.
let invokedDirectly = false;
try {
  invokedDirectly = Boolean(process.argv[1])
    && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url));
} catch { /* An importing host may have no filesystem argv entry. */ }
if (invokedDirectly) {
  let stage = 'setup', command = 'none';
  const diagnostic = (nextStage, nextCommand) => { stage = nextStage; command = nextCommand; };
  main(process.argv.slice(2), diagnostic).catch(() => {
    // Only our fixed labels, never exception messages, assertion diffs or paths.
    console.error(`Coverage probe failed: stage=${stage} command=${command}. No retry; partial output is not a completed observation.`);
    process.exitCode = 1;
  });
}
