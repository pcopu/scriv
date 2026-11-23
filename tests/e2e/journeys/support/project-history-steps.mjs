import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { scriptAuthoringSteps, focusedEditors } from './script-authoring-steps.mjs';

export const historyReviewManifest = {
  journey: 'IJ-03', portion: 'local-history-review-and-restore', nativeVerified: false,
  cases: [{ key: 'edit-save-review-close-reopen',
    sequence: ['import synthetic local project', 'edit through focused UITextView', 'Command-S',
      'Script history', 'inspect default prior revision', 'expand/collapse entry Technical details',
      'Revision preview', 'Changes', 'verify disclosure survives tab switch', 'Close',
      'repeat review', 'browser switch-away/reopen', 'review persisted prior revision'],
    assertions: ['prior text differs from working text', 'preview is read-only',
      'selected prior entry Technical details match every saved entry field',
      'Technical details collapse removes payload and a fresh History sheet resets disclosure',
      'loaded model and date bits remain exactly unchanged', 'all saved packages remain exactly unchanged',
      'history preview survives production project reopen'],
    sources: ['apps/catalyst/ScrivUIKit/Script/ScriptScreenController.swift::viewDidLoad',
      'apps/catalyst/ScrivUIKit/Projects/HistoryController.swift::viewDidLoad/choose/renderSnapshot/changeCard/toggleTechnical',
      'apps/mac/Sources/ScrivApp/Views/ProjectHistoryPresentation.swift::localChanges',
      'apps/mac/Sources/ScrivApp/Services/WorkspaceStore.swift::change/queueSave',
      'apps/mac/Sources/ScrivCore/ProjectRepository.swift::save'],
  }, { key: 'cancel-restore-undo-redo-reopen',
    sequence: ['Cancel restore', 'Restore as a new revision', 'Undo', 'Redo', 'browser reopen'],
    assertions: ['cancel preserves exact loaded and persisted state', 'restore creates a new revision with the previewed content',
      'undo and redo restore their respective contents', 'reopen preserves the result and unrelated packages'],
    sources: ['apps/catalyst/ScrivUIKit/Projects/HistoryController.swift::confirmRestore',
      'apps/mac/Sources/ScrivApp/Services/WorkspaceStore.swift::restoreHistory/restoreContent'],
  }],
  excluded: ['Explicit revision selection is exercised in the native cloud project journey.',
    'Cloud history, account/provider access, journal corruption/recovery, process restart and crash durability.'],
};
const originalText = 'History baseline lantern.';
const editedText = 'History edited compass.';
const sorted = projects => [...projects].sort((a, b) => a.id.localeCompare(b.id));
const header = (nodes, title) => nodes.some(node => node.identifier === 'workspace-project' && node.title === title && node.hittable);

export async function runHistoryReview(session) {
  const step = scriptAuthoringSteps(session);
  const capabilities = await session.command('capabilities');
  for (const command of ['import-json', 'loaded-project', 'persisted-projects', 'snapshot', 'activate', 'select', 'text', 'key', 'scroll', 'presented-alerts']) {
    assert.ok(capabilities.commands.includes(command), `Native app exposes ${command}`);
  }
  await session.waitFor(nodes => header(nodes, 'YAM MAN'));
  await step.workspaceCommand('s');
  const other = await step.saved(project => project.title === 'YAM MAN');
  const title = `History review ${randomUUID()}`;
  const fixture = { schemaVersion: 1, id: 'history-input', title,
    createdAt: 1700000000000, modifiedAt: 1700000000000, revision: 0,
    scenes: [{ id: 'history-scene', title: 'Synthetic room', order: 0 }],
    entries: [{ id: 'history-line', sceneId: 'history-scene', order: 0, kind: 'direction',
      text: originalText, ownedDurationMs: 0, coverageDurationMs: 0, color: 'purple', words: [], characterLinks: [] }],
    cues: [], characters: [], images: [], audioAssets: [], audioClips: [], audioVolume: 1 };
  assert.deepEqual(await session.command('import-json', { text: JSON.stringify(fixture) }),
    { dispatched: true, projectChanged: true });
  await session.waitFor(nodes => header(nodes, title));
  await step.selectTab('Script');
  await step.workspaceCommand('s');
  const before = await step.saved(project => project.title === title);
  assert.equal(before.entries[0].text, originalText);
  assert.equal(before.cloudProjectId, undefined);
  await step.key('\r', ['command']);
  await session.waitFor(nodes => focusedEditors(nodes).length === 1
    && focusedEditors(nodes)[0].identifier === 'script-editor-history-line');
  const nodes = await session.command('snapshot');
  await step.reveal(focusedEditors(nodes)[0], nodes);
  await session.command('text', { target: 'script-editor-history-line', text: editedText });
  await step.finishEditor();
  await step.workspaceCommand('s');
  const edited = await step.saved(project => project.id === before.id && project.entries[0]?.text === editedText);
  assert.equal(edited.revision, before.revision + 1, 'One actual text replacement produces exactly one revision');
  const loaded = await session.command('loaded-project');
  assert.deepEqual(loaded.project, edited);
  const packages = sorted(await session.command('persisted-projects'));
  assert.equal(packages.length, 2);
  assert.deepEqual(packages.find(project => project.id === other.id), other);

  async function unchanged({ modal = false } = {}) {
    // The loaded-model observer intentionally excludes HistoryController.
    // Keep that boundary intact; compare its complete witness after dismissal.
    if (!modal) assert.deepEqual(await session.command('loaded-project'), loaded, 'Review leaves every loaded field and exact date bits untouched');
    assert.deepEqual(sorted(await session.command('persisted-projects')), packages, 'Review writes no project changes');
    assert.deepEqual(await session.command('presented-alerts'), []);
  }
  async function reviewAndClose() {
    await step.activate('Script history');
    const historyNodes = await session.waitFor(nodes => nodes.some(node => node.title === 'Restore revision…' && node.enabled && node.hittable)
      && nodes.some(node => node.text === `Revision ${before.revision}`));
    const source = historyNodes.filter(node => node.segments?.join('|') === 'This Mac|Cloud');
    assert.equal(source.length, 1); assert.equal(source[0].selected, 0, 'Only local history is inspected');
    async function tab(index) {
      const nodes = await session.waitFor(nodes => nodes.some(node => node.segments?.join('|') === 'Changes|Revision preview' && node.hittable));
      const tabs = nodes.filter(node => node.segments?.join('|') === 'Changes|Revision preview');
      assert.equal(tabs.length, 1);
      await session.command('select', { target: tabs[0].path, index });
      await session.waitFor(nodes => nodes.some(node => node.segments?.join('|') === 'Changes|Revision preview' && node.selected === index));
    }
    // The label and disclosure must share the selected entry's change-card
    // content stack. Never use a background editor or a table revision label
    // as proof of the detail selection, nor activate an arbitrary disclosure.
    function entryCard(nodes) {
      const headings = nodes.filter(node => node.text === 'Direction text');
      assert.equal(headings.length, 1, 'The prior revision has exactly one direction change card');
      const rowPath = headings[0].path.slice(0, headings[0].path.lastIndexOf('.'));
      const contentPath = rowPath.slice(0, rowPath.lastIndexOf('.'));
      const children = nodes.filter(node => node.path.startsWith(contentPath + '.'));
      assert.ok(children.some(node => node.text === 'Added'), 'Prior import is an added entry, not the working edit');
      assert.ok(children.some(node => node.text === originalText && node.editable === false),
        'Readable After content is the original read-only entry in this card');
      assert.ok(!children.some(node => node.text?.includes(editedText)), 'Working text never appears in the prior entry card');
      const buttons = children.filter(node => node.title === 'Technical details' && node.enabled);
      assert.equal(buttons.length, 1, 'Resolve exactly the entry card disclosure');
      return { children, button: buttons[0] };
    }
    const payloadPrefix = `Item: ${before.entries[0].id}\n\nBefore\n`;
    const payloads = nodes => entryCard(nodes).children.filter(node => node.text?.startsWith(payloadPrefix));
    function assertTechnical(nodes, expanded) {
      const matches = payloads(nodes);
      assert.equal(matches.length, expanded ? 1 : 0, 'Disclosure adds/removes the entry payload');
      if (!expanded) return;
      assert.equal(matches[0].editable, false, 'Technical payload is read-only');
      const prefix = payloadPrefix + 'Not present\n\nAfter\n';
      assert.ok(matches[0].text.startsWith(prefix), 'The selected prior import has no Before entry');
      assert.deepEqual(JSON.parse(matches[0].text.slice(prefix.length)), before.entries[0],
        'Technical After JSON equals every field of the saved prior entry');
    }
    async function toggleTechnical(expanded) {
      const nodes = await session.command('snapshot');
      await step.reveal(entryCard(nodes).button, nodes);
      const visible = await session.waitFor(nodes => entryCard(nodes).button.hittable);
      await session.command('activate', { target: entryCard(visible).button.path });
      const updated = await session.waitFor(nodes => payloads(nodes).length === (expanded ? 1 : 0));
      assertTechnical(updated, expanded);
      await unchanged({ modal: true });
    }
    assertTechnical(historyNodes, false);
    await toggleTechnical(true);
    await toggleTechnical(false);
    await toggleTechnical(true);
    // Unlike originalText (also present in added-entry change cards), this
    // summary exists only in renderSnapshot. Segment state alone cannot prove
    // the installed valueChanged callback rebuilt the detail content.
    const summary = '1 scene · 1 entry · 0 characters · 0 image cues · 0 local audio clips';
    assert.ok(!historyNodes.some(node => node.text === summary), 'Initial Changes has no snapshot summary');
    await tab(1);
    const previewNodes = await session.waitFor(nodes => nodes.filter(node => node.text === summary).length === 1
      && nodes.some(node => node.text === originalText && node.editable === false));
    const summaryNode = previewNodes.find(node => node.text === summary);
    const detailPath = summaryNode.path.slice(0, summaryNode.path.lastIndexOf('.'));
    const detailNodes = previewNodes.filter(node => node.path.startsWith(detailPath + '.'));
    assert.ok(detailNodes.some(node => node.text === title), 'Snapshot title belongs to the summary detail subtree');
    assert.ok(detailNodes.some(node => node.text === 'Synthetic room'), 'Snapshot scene belongs to the summary detail subtree');
    assert.ok(detailNodes.some(node => node.text === originalText && node.editable === false),
      'The original read-only entry is inside the rebuilt snapshot detail subtree');
    assert.ok(!detailNodes.some(node => node.text === editedText), 'Prior snapshot detail shows original text, never current working text');
    assert.ok(previewNodes.some(node => node.text === 'Read-only preview'));
    await unchanged({ modal: true });
    await tab(0);
    const changesAgain = await session.waitFor(nodes => !nodes.some(node => node.text === summary));
    assertTechnical(changesAgain, true);
    await toggleTechnical(false);
    // Close expanded so the next sheet's initial absence proves reset.
    await toggleTechnical(true);
    await unchanged({ modal: true });
    await step.activate('Close');
    await session.waitFor(nodes => header(nodes, title));
    await unchanged();
  }
  await reviewAndClose();
  await reviewAndClose();

  async function open(project) {
    const nodes = await session.waitFor(nodes => nodes.some(node => node.identifier === 'workspace-project' && node.hittable));
    await session.command('activate', { target: nodes.find(node => node.identifier === 'workspace-project' && node.hittable).path });
    const browser = await session.waitFor(nodes => nodes.some(node => node.placeholder === 'Find a project' && node.hittable));
    await session.command('text', { target: browser.find(node => node.placeholder === 'Find a project' && node.hittable).path, text: project.title });
    await session.waitFor(nodes => nodes.some(node => node.text === `${project.title} · ${project.scenes.length} scene${project.scenes.length === 1 ? '' : 's'}`));
    await step.activate('Open project');
    await session.waitFor(nodes => header(nodes, project.title));
    assert.deepEqual((await session.command('loaded-project')).project, project);
  }
  await open(other);
  await open(edited);
  await unchanged();
  await step.selectTab('Script');
  await reviewAndClose();
  console.log('PASS: IJ-03 local-history-read-only-review: edit/save, exact prior Technical details and disclosure toggles, prior preview, repeated Close, exact model/package preservation and persisted-history reopen');

  const waitForWorkspace = () => session.waitFor(nodes => header(nodes, title)
    && !nodes.some(node => node.title === 'Restore revision…' || node.identifier === 'history-restore-confirm'));
  await step.activate('Script history');
  await activateHistoryRestore(session, 'cancel');
  await session.waitFor(nodes => nodes.some(node => node.title === 'Restore revision…' && node.enabled && node.hittable));
  await unchanged({ modal: true });
  await step.activate('Close');
  await waitForWorkspace();
  await unchanged();
  await step.activate('Script history');
  await activateHistoryRestore(session, 'confirm');
  await waitForWorkspace();
  const restored = await step.saved(project => project.id === edited.id && project.revision > edited.revision);
  assert.deepEqual({ ...restored, modifiedAt: before.modifiedAt, revision: before.revision }, before);
  assert.equal(restored.revision, edited.revision + 1);
  assert.deepEqual((await session.command('loaded-project')).project, restored);

  await step.workspaceHistory();
  const undone = await step.saved(project => project.id === edited.id && project.revision > restored.revision);
  assert.deepEqual({ ...undone, modifiedAt: edited.modifiedAt, revision: edited.revision }, edited);
  await step.workspaceHistory(true);
  const redone = await step.saved(project => project.id === edited.id && project.revision > undone.revision);
  assert.deepEqual({ ...redone, modifiedAt: restored.modifiedAt, revision: restored.revision }, restored);
  await open(other);
  await open(redone);
  assert.deepEqual(sorted(await session.command('persisted-projects')), sorted([other, redone]));
  console.log('PASS: native local history restore creates a new revision, supports undo and redo, and survives reopen');
}

export async function activateHistoryRestore(session, decision) {
  await scriptAuthoringSteps(session).activate('Restore revision…');
  const ready = (node, action) => node.identifier === 'history-restore-' + action && node.enabled && node.hittable;
  const nodes = await session.waitFor(nodes => nodes.some(node => ready(node, 'cancel'))
    && nodes.some(node => ready(node, 'confirm')), 5000).catch(async error => {
    const alert = (await session.command('presented-alerts')).find(item => item.title === 'Restore the previewed revision?');
    if (alert) throw new Error('History shows the native alert with no CLI Restore confirmation control', { cause: error });
    throw error;
  });
  assert.ok(nodes.some(node => node.text === 'Restore the previewed revision?'));
  const target = nodes.find(node => ready(node, decision));
  assert.equal(target.title, decision === 'cancel' ? 'Cancel' : 'Restore as a new revision');
  assert.deepEqual(await session.command('activate', { target: target.path }), { dispatched: true });
}
