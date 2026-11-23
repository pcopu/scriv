import assert from 'node:assert/strict';
import { ScrivSession } from '../../../cli/scriv.mjs';
import { waitForSavedProject } from '../support/saved-projects.mjs';
import { audioLibrarySteps } from './support/audio-library-steps.mjs';
import { nativeFixtureEmail, startNativeCloudFixture } from './support/native-cloud-fixture.mjs';

assert.ok(process.env.SCRIV_E2E_APP, 'Requires a signed Catalyst automation build');
const fixture = await startNativeCloudFixture();
let session;
let phase = 'create the owned project and its history';
try {
  const project = await fixture.prepareHistoryPages();
  session = await ScrivSession.launch(process.env.SCRIV_E2E_APP, { cloudFixtureOrigin: fixture.origin });
  const caps = await session.command('capabilities');
  assert.equal(caps.cloudIsolation.network, 'loopback-only');
  const ui = audioLibrarySteps(session);
  const ready = node => node.enabled && node.hittable;
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
  const isWorkspace = node => node.identifier === 'workspace-project' && node.title === project.title && ready(node);
  const restoreButton = node => node.title === 'Restore revision…';
  const settled = () => session.waitFor(nodes => nodes.some(isWorkspace)
    && !nodes.some(node => node.title === 'Close Projects' || restoreButton(node)));

  phase = 'open the seeded project through Scriv Cloud';
  await click(node => node.identifier === 'workspace-project');
  await button('Sign in to Scriv…');
  const email = await ui.reveal(node => node.type === 'UITextField' && node.label === 'Email address');
  await session.command('text', { target: email.path, text: nativeFixtureEmail });
  await button('Continue with email');
  await session.waitFor(nodes => nodes.some(node => node.text === 'Check your email'));
  assert.deepEqual(await session.deliverFixtureEmailCode(await fixture.takeCode()), { delivered: true });
  await button('Sign in with code');
  await button('Scriv Cloud');
  await session.waitFor(nodes => nodes.some(node => node.text === project.title + ' · Cloud project'));
  await button('Open project');
  await settled();
  const replica = await waitForSavedProject(session, candidate => candidate.cloudProjectId === project.id);
  const loaded = await session.command('loaded-project');
  assert.deepEqual(loaded.project, replica);
  const byOrder = (a, b) => a.order - b.order;
  assert.deepEqual([...replica.entries].sort(byOrder), project.entries);
  const packages = await session.command('persisted-projects');

  phase = 'page through Cloud History and select its oldest revision';
  const menu = await ui.reveal(node => node.label === 'Workspace actions');
  assert.deepEqual(await session.command('menu-action', { target: menu.path, scope: 'workspace-panels', action: 'History…' }),
    { dispatched: true, coverage: 'semantic-menu-action' });
  async function segment(labels, index) {
    const control = await ui.reveal(node => node.type === 'UISegmentedControl' && node.segments?.join('|') === labels);
    await session.command('select', { target: control.path, index });
  }
  await segment('This Mac|Cloud', 1);
  await segment('Changes|Revision preview', 1);
  const visibleRows = await session.waitFor(nodes => nodes.some(node => node.type === 'HistoryEventCell' && node.hittable)
    && nodes.some(node => node.text === 'Send message'));
  const table = visibleRows.find(node => node.type === 'UITableView' && node.hittable
    && visibleRows.some(row => row.type === 'HistoryEventCell' && row.path.startsWith(node.path + '.')));
  assert.ok(table);
  await session.command('scroll', { target: table.path, y: Number.MAX_SAFE_INTEGER });
  const importRow = nodes => nodes.find(node => node.type === 'HistoryEventCell' && node.hittable
    && nodes.some(label => label.path.startsWith(node.path + '.') && label.text === 'Import project'));
  async function chooseImport() {
    const nodes = await session.waitFor(nodes => !!importRow(nodes));
    assert.deepEqual(await session.command('activate', { target: importRow(nodes).path }), { dispatched: true });
  }
  const summary = '1 scene · 205 entries · 0 characters · 0 image cues · 0 local audio clips';
  let detailPath;
  async function assertCompletePreview() {
    const lastDirection = project.entries.at(-1).text;
    const nodes = await session.waitFor(nodes => nodes.some(node => node.type === 'ScriptTextView' && node.text === lastDirection)
      && nodes.some(node => restoreButton(node) && ready(node)));
    const summaries = nodes.filter(node => node.text === summary);
    assert.equal(summaries.length, 1);
    detailPath = summaries[0].path.slice(0, summaries[0].path.lastIndexOf('.'));
    const rendered = nodes.filter(node => node.path.startsWith(detailPath + '.')
      && node.type === 'ScriptTextView' && node.editable === false
      && node.text?.startsWith('Historical direction ')).map(node => node.text);
    assert.deepEqual(rendered, project.entries.map(entry => entry.text), 'Read-only preview joins all pages in script order');
    const progress = await fixture.historyPageState();
    assert.deepEqual(progress.events, [
      { after: 0, count: 100, hasMore: true },
      { after: project.importSeq + 99, count: 2, hasMore: false },
    ]);
    assert.equal(progress.snapshots.length, 2);
    const [first, second] = progress.snapshots;
    assert.equal(first.after, '');
    assert.equal(first.count, 200);
    assert.ok(first.next);
    assert.deepEqual(second, { after: first.next, count: 6, next: null });
    assert.equal(progress.pending, null);
  }
  await fixture.changeHistoryPage(null);
  await chooseImport();
  await assertCompletePreview();

  for (const [fault, message, count] of [
    ['wrong-revision', 'The server returned a different history revision.', 1],
    ['different-epoch', 'Historical snapshot pages disagree.', 2],
    ['repeated-cursor', 'Historical snapshot pagination stopped advancing.', 2],
  ]) {
    phase = 'reject ' + fault + ' in the selected historical revision';
    assert.equal(await fixture.changeHistoryPage(fault), true);
    await chooseImport();
    const failed = await session.waitFor(nodes => nodes.some(node => node.text === 'Revision preview unavailable')
      && nodes.some(node => node.text === message) && nodes.some(node => restoreButton(node) && !node.enabled));
    assert.ok(!failed.some(node => node.path.startsWith(detailPath + '.') && node.type === 'ScriptTextView'
      && node.text?.startsWith('Historical direction ')),
      'An incomplete preview never exposes partial script content');
    const state = await fixture.historyPageState();
    assert.equal(state.pending, null);
    assert.equal(state.snapshots.length, count);
    assert.deepEqual(await session.command('persisted-projects'), packages);
  }

  phase = 'retry the real preview and close without editing';
  await fixture.changeHistoryPage(null);
  await chooseImport();
  await assertCompletePreview();
  await button('Close');
  await settled();
  assert.deepEqual(await session.command('loaded-project'), loaded);
  assert.deepEqual(await session.command('persisted-projects'), packages);
  assert.deepEqual(await session.command('presented-alerts'), []);
  await fixture.assertNoOutbound();
  console.log('PASS: native Cloud History joins both paged responses and recovers from three invalid preview responses');
} catch (error) {
  throw new Error('Native Cloud History pagination failed during ' + phase, { cause: error });
} finally {
  try { await session?.close(); }
  finally { await fixture.close(); }
}
