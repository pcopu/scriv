import assert from 'node:assert/strict';
import { constants } from 'node:fs';
import { access, lstat, open, readFile, readdir, realpath } from 'node:fs/promises';
import { join } from 'node:path';
import { ScrivSession } from '../../../cli/scriv.mjs';
import { inspectOwnedWorkspace } from '../../../cli/owned-workspace.mjs';
import { waitForSavedProject } from '../support/saved-projects.mjs';
import { characterCatalogSteps } from './support/character-catalog-steps.mjs';
import { fixture } from './support/generation-review-fixture.mjs';
import { sortedProjects } from './support/generation-review-steps.mjs';

assert.ok(process.env.SCRIV_E2E_APP, 'Requires an isolated Catalyst automation bundle');
let session = await ScrivSession.launch(process.env.SCRIV_E2E_APP, { persistent: true });
const root = session.root;
const input = structuredClone(fixture);
input.title = 'Synthetic recovery at launch';
const biography = 'An accepted edit survives a cold start.';
const journal = join(root, 'PendingProjectSaves');
const pending = async () => (await readdir(journal)).filter(name => name.endsWith('.json'));
const saved = async () => sortedProjects(await session.command('persisted-projects'));
let step = 'save two isolated packages';

async function waitForAlert(prefix) {
  const deadline = Date.now() + 15000;
  do {
    const alerts = await session.command('presented-alerts');
    if (alerts.some(alert => alert.message.startsWith(prefix) && alert.viewAttachedToWindow
        && !alert.beingPresented && !alert.beingDismissed)) return;
    await new Promise(resolve => setTimeout(resolve, 50));
  } while (Date.now() < deadline);
  throw new Error('Expected save or recovery error did not finish presenting');
}

try {
  const first = await session.command('capabilities');
  assert.equal(first.cloudIsolation.network, 'disabled');
  await assert.rejects(session.relaunchRecoveringPendingSaves({ root: session.root }), /no arguments/);
  assert.deepEqual(await session.command('capabilities'), first);
  await inspectOwnedWorkspace(root);
  await session.waitFor(nodes => nodes.some(node => node.identifier === 'workspace-tabs' && node.hittable));
  await session.command('key', { input: 's', modifiers: ['command'] });
  const sample = await waitForSavedProject(session, project => project.title === 'YAM MAN');
  assert.deepEqual(await session.command('import-json', { text: JSON.stringify(input) }), { dispatched: true, projectChanged: true });
  const before = await waitForSavedProject(session, project => project.title === input.title);
  assert.match(before.id, /^[0-9a-f-]{36}$/i);
  const history = join(root, 'Projects', before.id + '.scriv', 'history');
  const initialHistory = (await readdir(history)).sort();
  const ui = characterCatalogSteps(session);
  await ui.openCatalog({ persist: false });
  const card = await ui.control(node => node.identifier === 'character-ribbon-mara');
  await session.command('activate', { target: card.path });
  await ui.activate('Edit');
  await ui.saveEnabled(true);
  await ui.text(ui.biographyField, biography, 'startup recovery biography');
  assert.deepEqual(await pending(), []);

  step = 'retain a real accepted save after an owned history write refusal';
  assert.equal(await realpath(history), history);
  const named = await lstat(history);
  const directory = await open(history, constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW);
  let originalMode;
  try {
    const info = await directory.stat();
    assert.ok(named.ino === info.ino && named.dev === info.dev && info.uid === process.getuid());
    assert.equal(info.mode & 0o700, 0o700);
    assert.equal(info.mode & 0o7022, 0);
    originalMode = info.mode & 0o777;
    await directory.chmod(originalMode & ~0o200);
    await assert.rejects(access(history, constants.W_OK), error => error.code === 'EACCES');
    await ui.activate('Save character');
    await session.waitFor(nodes => nodes.some(node => node.text?.includes('Save failed — accepted changes remain in local recovery')));
    await waitForAlert(`Could not save ${before.title}: `);
  } finally {
    try { if (originalMode !== undefined) await directory.chmod(originalMode); }
    finally { await directory.close(); }
  }
  assert.deepEqual(await saved(), sortedProjects([sample, before]));
  const records = await pending();
  assert.equal(records.length, 1);
  assert.match(records[0], /^[0-9a-f]{64}-\d+\.json$/);
  const recordPath = join(journal, records[0]);
  const retained = await readFile(recordPath);
  const record = JSON.parse(retained);
  const expected = structuredClone(before);
  expected.characters[0].biography = biography;
  expected.revision += 1;
  expected.modifiedAt = record.after.modifiedAt;
  assert.deepEqual(record.after, expected);
  assert.equal(record.scope.packagePath, join(root, 'Projects', before.id + '.scriv'));
  assert.equal(record.scope.server, 'local');
  const accepted = await session.command('loaded-project');

  step = 'retain an unreadable recovery record on startup';
  session = await session.relaunch();
  assert.deepEqual(await saved(), sortedProjects([sample, before]));
  assert.deepEqual(await readFile(recordPath), retained);
  assert.equal(await realpath(recordPath), recordPath);
  const pendingFile = await open(recordPath, constants.O_RDWR | constants.O_NOFOLLOW);
  try {
    const info = await pendingFile.stat();
    assert.ok(info.isFile() && info.uid === process.getuid() && info.nlink === 1);
    assert.deepEqual(await pendingFile.readFile(), retained);
    const invalidByte = Buffer.from('!');
    await pendingFile.write(invalidByte, 0, 1, 0);
    try {
      session = await session.relaunchRecoveringPendingSaves();
      await waitForAlert('Project recovery needs attention. No pending changes were discarded:');
      assert.deepEqual(await saved(), sortedProjects([sample, before]));
      assert.deepEqual((await readdir(history)).sort(), initialHistory);
      assert.deepEqual(await pending(), records);
      assert.deepEqual(await readFile(recordPath), Buffer.concat([invalidByte, retained.subarray(1)]));
    } finally {
      await pendingFile.write(retained.subarray(0, 1), 0, 1, 0);
    }
  } finally { await pendingFile.close(); }

  step = 'recover the retained package on a cold launch without using the picker';
  session = await session.relaunchRecoveringPendingSaves();
  const reopened = await session.command('capabilities');
  assert.equal(session.root, root);
  assert.equal(reopened.runID, first.runID);
  assert.notEqual(reopened.sessionID, first.sessionID);
  assert.equal(reopened.workspace.resumed, true);
  assert.equal(reopened.workspace.startupRecovery, true);
  assert.equal(reopened.cloudIsolation.network, 'disabled');
  await session.waitFor(nodes => nodes.some(node => node.identifier === 'workspace-project' && node.title === before.title && node.hittable));
  assert.deepEqual(await session.command('loaded-project'), accepted);
  assert.deepEqual(await saved(), sortedProjects([sample, expected]));
  assert.deepEqual(await pending(), []);
  const revision = String(expected.revision).padStart(12, '0') + '.json';
  const historyAfter = (await readdir(history)).sort();
  assert.deepEqual(historyAfter, [...initialHistory, revision].sort());
  assert.deepEqual(JSON.parse(await readFile(join(history, revision))).snapshot, expected);

  step = 'repeat startup recovery with an empty journal';
  session = await session.relaunchRecoveringPendingSaves();
  assert.deepEqual(await saved(), sortedProjects([sample, expected]));
  assert.deepEqual((await readdir(history)).sort(), historyAfter);
  assert.deepEqual(await pending(), []);
  assert.deepEqual(await session.command('presented-alerts'), []);
  console.log('PASS: owned startup save recovery, original revision and clean repeated launch');
} catch (cause) {
  throw new Error(`Native startup recovery failed while trying to ${step}`, { cause });
} finally {
  await session.close();
}
