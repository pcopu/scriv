import assert from 'node:assert/strict';
import { ScrivSession } from '../../../cli/scriv.mjs';
import { waitForSavedProject } from '../support/saved-projects.mjs';
import { audioLibrarySteps } from './support/audio-library-steps.mjs';
import { nativeFixtureEmail, startNativeCloudFixture } from './support/native-cloud-fixture.mjs';
import { activateHistoryRestore } from './support/project-history-steps.mjs';
import { scriptAuthoringSteps, byID } from './support/script-authoring-steps.mjs';

assert.ok(process.env.SCRIV_E2E_APP, 'Requires a signed Catalyst automation build');
const fixture = await startNativeCloudFixture();
const message = 'Keep this discussion when the script is restored.';
const ready = node => node.enabled && node.hittable;
const isProject = node => node.identifier === 'workspace-project';
const byItemID = (a, b) => a.id.localeCompare(b.id);
// Cloud snapshots rebuild keyed collections. Order and timing fields still compare exactly.
const content = ({ revision, modifiedAt, entries, characters, cues, ...rest }) => ({
  ...rest, entries: [...entries].sort(byItemID), characters: [...characters].sort(byItemID), cues: [...cues].sort(byItemID),
});
let session;
let phase = 'sign in through the isolated mailbox';
try {
  session = await ScrivSession.launch(process.env.SCRIV_E2E_APP, { cloudFixtureOrigin: fixture.origin });
  const caps = await session.command('capabilities');
  assert.equal(caps.cloudIsolation.network, 'loopback-only');
  const ui = audioLibrarySteps(session), script = scriptAuthoringSteps(session);
  const saved = predicate => waitForSavedProject(session, predicate);
  async function click(matches) {
    const targets = nodes => nodes.filter(node => ready(node) && matches(node));
    let previous, stableSince;
    const nodes = await session.waitFor(nodes => {
      const [target, other] = targets(nodes);
      const key = target && !other ? JSON.stringify([target.path, target.frame]) : undefined;
      if (!key || key !== previous) { previous = key; stableSince = Date.now(); return false; }
      return Date.now() - stableSince >= 1000;
    });
    await session.command('activate', { target: targets(nodes)[0].path });
  }
  const button = title => click(node => node.type === 'UIButton' && (node.title === title || node.label === title));
  const waitForWorkspace = () => session.waitFor(nodes => nodes.some(node => isProject(node) && ready(node))
    && !nodes.some(node => node.title === 'Close Projects' || node.title === 'Restore revision…' || node.label === 'Close discussion'));
  async function panel(scope, action) {
    const menu = await ui.reveal(node => node.label === 'Workspace actions');
    assert.deepEqual(await session.command('menu-action', { target: menu.path, scope, action }),
      { dispatched: true, coverage: 'semantic-menu-action' });
  }
  async function segment(labels, index) {
    const control = await ui.reveal(node => node.type === 'UISegmentedControl' && node.segments?.join('|') === labels);
    await session.command('select', { target: control.path, index });
  }

  await ui.tab('Script');
  await script.workspaceCommand('s');
  const original = await saved(project => project.title === 'YAM MAN');
  await click(isProject);
  await button('Sign in to Scriv…');
  const email = await ui.reveal(node => node.type === 'UITextField' && node.label === 'Email address');
  await session.command('text', { target: email.path, text: nativeFixtureEmail });
  await button('Continue with email');
  await session.waitFor(nodes => nodes.some(node => node.text === 'Check your email'));
  assert.deepEqual(await session.deliverFixtureEmailCode(await fixture.takeCode()), { delivered: true });
  await button('Sign in with code');
  await button('Close Projects');
  await waitForWorkspace();

  phase = 'save the script to the cloud and post a discussion';
  await panel('workspace-discussion', 'Discussion');
  await button('Save script to cloud');
  const seeded = await saved(project => project.id === original.id && !!project.cloudProjectId);
  const isComposer = node => node.type === 'DiscussionComposerTextView' && node.editable && node.hittable;
  const composer = (await session.waitFor(nodes => nodes.some(isComposer))).find(isComposer);
  await session.command('text', { target: composer.path, text: message });
  await button('Send message');
  const hasMessage = nodes => nodes.some(node => node.type === 'DiscussionReadOnlyTextView' && node.text === message);
  await session.waitFor(hasMessage);
  await button('Close discussion');
  await waitForWorkspace();

  phase = 'edit the linked script and find the original revision';
  const line = seeded.entries.find(entry => entry.id === 'line-01');
  assert.equal(line.kind, 'dialogue');
  await script.displayed(line.id, line.text, { finished: true });
  await script.key('\r', ['command']);
  const editorID = 'script-editor-' + line.id;
  const editors = await session.waitFor(nodes => byID(nodes, editorID).some(node => node.firstResponder && node.text === line.text));
  await script.reveal(byID(editors, editorID)[0], editors);
  const changed = line.text + ' Keep the ledger open.';
  await session.command('selection', { target: editorID, start: line.text.length, end: line.text.length });
  await session.command('type', { target: editorID, text: changed.slice(line.text.length) });
  await script.waitEditor(editorID, changed, changed.length);
  await script.finishEditor();
  const working = await saved(project => project.id === original.id && project.entries.some(entry => entry.id === line.id && entry.text === changed));
  const loadedProject = () => session.command('loaded-project');
  const loadedBefore = await loadedProject();
  assert.deepEqual(loadedBefore.project, working);

  const restoreEvent = node => node.type === 'UILabel' && /^Restore history [0-9]+$/.test(node.text ?? '');
  async function chooseOriginal() {
    await panel('workspace-panels', 'History…');
    await segment('This Mac|Cloud', 1);
    await segment('Changes|Revision preview', 1);
    const row = (nodes, title) => nodes.find(node => node.type === 'HistoryEventCell' && node.hittable
      && nodes.some(label => label.path.startsWith(node.path + '.') && label.text === title));
    const nodes = await session.waitFor(nodes => row(nodes, 'Import project') && row(nodes, 'Edit script'));
    assert.ok(!nodes.some(restoreEvent), 'No cloud restore has occurred yet');
    assert.deepEqual(await session.command('activate', { target: row(nodes, 'Import project').path }), { dispatched: true });
    await session.waitFor(nodes => nodes.some(node => node.type === 'ScriptTextView' && node.text === line.text && node.editable === false && node.hittable));
  }

  phase = 'cancel restore and verify the saved script remains unchanged';
  await chooseOriginal();
  await activateHistoryRestore(session, 'cancel');
  await button('Close');
  await waitForWorkspace();
  assert.deepEqual(await loadedProject(), loadedBefore);
  assert.deepEqual(await session.command('persisted-projects'), [working]);

  phase = 'restore as a new revision and verify the original script and discussion';
  await chooseOriginal();
  await activateHistoryRestore(session, 'confirm');
  await waitForWorkspace();
  const restored = await saved(project => project.id === working.id && project.revision > working.revision
    && project.entries.some(entry => entry.id === line.id && entry.text === line.text));
  assert.deepEqual(content(restored), content(seeded));
  assert.deepEqual((await loadedProject()).project, restored);
  await panel('workspace-panels', 'History…');
  await segment('This Mac|Cloud', 1);
  await session.waitFor(nodes => nodes.some(restoreEvent));
  await button('Close');
  await waitForWorkspace();
  await panel('workspace-discussion', 'Discussion');
  await session.waitFor(hasMessage);
  await button('Close discussion');
  await waitForWorkspace();
  assert.deepEqual((await loadedProject()).project, restored);
  assert.deepEqual(await session.command('presented-alerts'), []);
  await fixture.assertNoOutbound();
  console.log('PASS: native cloud restore creates a new revision and preserves discussion');
} catch (error) {
  throw new Error('Native cloud history restore failed during ' + phase, { cause: error });
} finally {
  try { await session?.close(); }
  finally { await fixture.close(); }
}
