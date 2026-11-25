import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { scriptAuthoringSteps, focusedEditors } from './script-authoring-steps.mjs';
import { lineDurationSteps } from './line-duration-steps.mjs';

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
  }, { key: 'timing-only-change',
    sequence: ['Edit direction owned duration', 'Script history', 'Current revision', 'Close'],
    assertions: ['read-only comparison shows old and new time and coverage, and original script text',
      'review leaves the loaded model and saved packages unchanged'],
    sources: ['apps/catalyst/ScrivUIKit/Projects/HistoryController.swift::changeCard'],
  }, { key: 'attached-image-change',
    sequence: ['Import local image', 'Script history', 'Current revision', 'Close'],
    assertions: ['the image version and its source-relative placement appear in the change cards',
      'review leaves the loaded model and saved packages unchanged'],
    sources: ['apps/mac/Sources/ScrivApp/Views/ProjectHistoryPresentation.swift::fields/imageLabel/anchorLabel'],
  }, { key: 'script-change-with-unchanged-image', group: 'change-cards',
    sequence: ['Edit the pictured direction', 'Script history', 'Current revision', 'Close'],
    assertions: ['the comparison shows distinct read-only text and the same attached image',
      'review leaves the saved project and local image bytes unchanged'],
    sources: ['apps/catalyst/ScrivUIKit/Projects/HistoryController.swift::changeCard'],
  }, { key: 'expand-all-change-cards', group: 'change-cards',
    sequence: ['Import a local project with ten directions', 'Script history', 'Show more changes', 'Close'],
    assertions: ['the first page has eight cards', 'the final read-only direction appears after expansion',
      'review leaves every saved project unchanged'],
    sources: ['apps/catalyst/ScrivUIKit/Projects/HistoryController.swift::renderDetail'],
  }],
  excluded: ['Explicit revision selection is exercised in the native cloud project journey.',
    'Cloud history, account/provider access, journal corruption/recovery, process restart and crash durability.'],
};
const originalText = 'History baseline lantern.';
const editedText = 'History edited compass.';
const sorted = projects => [...projects].sort((a, b) => a.id.localeCompare(b.id));
const header = (nodes, title) => nodes.some(node => node.identifier === 'workspace-project' && node.title === title && node.hittable);

function historyFixture(title, milliseconds = 0) {
  return { schemaVersion: 1, id: 'history-input', title,
    createdAt: 1700000000000, modifiedAt: 1700000000000, revision: 0,
    scenes: [{ id: 'history-scene', title: 'Synthetic room', order: 0 }],
    entries: [{ id: 'history-line', sceneId: 'history-scene', order: 0, kind: 'direction',
      text: originalText, ownedDurationMs: milliseconds, coverageDurationMs: milliseconds, color: 'purple', words: [], characterLinks: [] }],
    cues: [], characters: [], images: [], audioAssets: [], audioClips: [], audioVolume: 1 };
}

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
  const fixture = historyFixture(title);
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

  const duration = lineDurationSteps(session);
  await duration.open(redone, 'history-line', '0.000');
  await duration.input('1.250');
  await duration.button('Apply');
  await duration.closed();
  const timed = await step.saved(project => project.id === redone.id && project.revision > redone.revision);
  assert.equal(timed.revision, redone.revision + 1);
  assert.deepEqual(timed.entries, [{ ...redone.entries[0], ownedDurationMs: 1250, coverageDurationMs: 1250 }]);
  const timedModel = await session.command('loaded-project');
  assert.deepEqual(timedModel.project, timed);
  await duration.collapseLayers();
  await step.activate('Script history');
  const currentRow = nodes => nodes.find(node => node.type === 'HistoryEventCell' && node.hittable
    && nodes.some(child => child.path.startsWith(node.path + '.') && child.text === 'Current revision'));
  const history = await session.waitFor(nodes => !!currentRow(nodes));
  assert.deepEqual(await session.command('activate', { target: currentRow(history).path }), { dispatched: true });
  const changes = await session.waitFor(nodes => nodes.some(node => node.text === 'Owned time')
    && nodes.some(node => node.text === 'Script · unchanged'));
  const label = changes.find(node => node.text === 'Script · unchanged');
  const labels = changes.filter(node => node.windowPath === label.windowPath);
  for (const value of ['0.0 s', '1.250 s', 'Coverage', '0.0–0.0 s', '0.0–1.250 s']) {
    assert.ok(labels.some(node => node.text === value), 'History shows ' + value);
  }
  const parent = label.path.slice(0, label.path.lastIndexOf('.'));
  assert.ok(labels.some(node => node.path.startsWith(parent + '.') && node.type === 'ScriptTextView'
    && node.text === originalText && node.editable === false));
  await step.activate('Close');
  await waitForWorkspace();
  assert.deepEqual(await session.command('loaded-project'), timedModel);
  assert.deepEqual(sorted(await session.command('persisted-projects')), sorted([other, timed]));
  console.log('PASS: native timing-only history preserves the script and shows both exact duration and coverage changes');

  assert.deepEqual(await session.command('import-local-image', { fixture: 'coral' }, 30_000),
    { dispatched: true, imported: true, cleanupVerified: true });
  const pictured = await step.saved(project => project.id === timed.id && project.images.length === 1);
  const [asset] = pictured.images;
  assert.equal(pictured.revision, timed.revision + 1);
  assert.deepEqual(pictured.entries, timed.entries);
  assert.equal(pictured.cues.length, 1);
  assert.equal(pictured.cues[0].imageId, asset.id);
  assert.deepEqual(pictured.cues[0].startAnchor, { entryId: 'history-line', offsetMs: 0 });
  const picturedModel = await session.command('loaded-project');
  assert.deepEqual(picturedModel.project, pictured);
  await step.activate('Script history');
  const versionHistory = await session.waitFor(nodes => !!currentRow(nodes));
  assert.deepEqual(await session.command('activate', { target: currentRow(versionHistory).path }), { dispatched: true });
  const imageFields = ['Image version 1', 'Imported image', 'Visible characters', 'File', asset.fileName];
  const placementFields = ['Image', `Version ${asset.version} · ${asset.fileName}`, 'Script anchor', 'Script-relative · 0.0 s offset'];
  await session.waitFor(nodes => [...imageFields, ...placementFields].every(text => nodes.some(node => node.text === text)));
  await step.activate('Close');
  await waitForWorkspace();
  assert.deepEqual(await session.command('loaded-project'), picturedModel);
  assert.deepEqual(sorted(await session.command('persisted-projects')), sorted([other, pictured]));
  console.log('PASS: native image history shows the saved version and anchored placement without editing either');
}


export async function runHistoryChangeCards(session) {
  const step = scriptAuthoringSteps(session);
  await session.waitFor(nodes => header(nodes, 'YAM MAN'));
  await step.workspaceCommand('s');
  const other = await step.saved(project => project.title === 'YAM MAN');
  const title = `History change cards ${randomUUID()}`;
  const fixture = historyFixture(title, 1250);
  assert.deepEqual(await session.command('import-json', { text: JSON.stringify(fixture) }), { dispatched: true, projectChanged: true });
  await session.waitFor(nodes => header(nodes, title));
  await step.selectTab('Script');
  const imported = await step.saved(project => project.title === title);
  assert.deepEqual(await session.command('import-local-image', { fixture: 'coral' }, 30_000),
    { dispatched: true, imported: true, cleanupVerified: true });
  const pictured = await step.saved(project => project.id === imported.id && project.images.length === 1);
  assert.equal(pictured.revision, imported.revision + 1);
  assert.deepEqual(pictured.entries, imported.entries);
  assert.equal(pictured.cues.length, 1);
  assert.equal(pictured.cues[0].imageId, pictured.images[0].id);
  async function compareCurrentTo(previous) {
    await step.activate('Script history');
    const currentRow = nodes => nodes.find(node => node.type === 'HistoryEventCell' && node.hittable
      && nodes.some(child => child.path.startsWith(node.path + '.') && child.text === 'Current revision'));
    const history = await session.waitFor(nodes => currentRow(nodes)
      && nodes.some(node => node.text === `Revision ${previous.revision}`));
    assert.deepEqual(await session.command('activate', { target: currentRow(history).path }), { dispatched: true });
  }

  const sourceAssets = (await session.command('local-image-evidence')).assets;
  const revisedText = 'History direction with the attached image unchanged.';
  await step.key('\r', ['command']);
  await session.waitFor(nodes => focusedEditors(nodes).some(node => node.identifier === 'script-editor-history-line'));
  await session.command('text', { target: 'script-editor-history-line', text: revisedText });
  await step.finishEditor();
  const revised = await step.saved(project => project.id === pictured.id && project.entries[0]?.text === revisedText);
  assert.equal(revised.revision, pictured.revision + 1);
  assert.deepEqual(revised.entries, [{ ...pictured.entries[0], text: revisedText }]);
  assert.deepEqual(revised.cues, pictured.cues);
  assert.deepEqual(revised.images, pictured.images);
  const revisedModel = await session.command('loaded-project');
  assert.deepEqual(revisedModel.project, revised);
  await compareCurrentTo(pictured);
  const unchangedImageMessage = 'This image was not changed in this revision.';
  const picturedChanges = await session.waitFor(nodes => nodes.some(node => node.text === unchangedImageMessage));
  const [imageMessage] = picturedChanges.filter(node => node.text === unchangedImageMessage);
  const cardPath = imageMessage.path.split('.').slice(0, -3).join('.');
  const card = picturedChanges.filter(node => node.windowPath === imageMessage.windowPath && node.path.startsWith(cardPath + '.'));
  assert.ok(card.some(node => node.text === `${pictured.cues[0].label || 'Image'} · unchanged`));
  assert.ok(card.some(node => node.type === 'ProjectCoverView'), 'The same change card includes the unchanged image cover');
  for (const text of [originalText, revisedText]) {
    assert.ok(card.some(node => node.type === 'ScriptTextView' && node.editable === false && node.text === text),
      'The same card shows each exact read-only direction');
  }
  await step.activate('Close');
  await session.waitFor(nodes => header(nodes, title) && !nodes.some(node => node.title === 'Restore revision…'));
  assert.deepEqual(await session.command('loaded-project'), revisedModel);
  assert.deepEqual(sorted(await session.command('persisted-projects')), sorted([other, revised]));
  const evidenceFields = assets => assets.map(({ assetID, sha256, byteCount, width, height, decoded }) =>
    ({ assetID, sha256, byteCount, width, height, decoded }));
  assert.deepEqual(evidenceFields((await session.command('local-image-evidence')).assets), evidenceFields(sourceAssets));
  console.log('PASS: native history compares edited script while preserving its attached image');

  const longer = { ...fixture, title: title + ' expanded', entries: Array.from({ length: 10 }, (_, index) => ({
    ...fixture.entries[0], id: 'long-history-line-' + index, order: index, text: 'History comparison direction ' + index,
  })) };
  assert.deepEqual(await session.command('import-json', { text: JSON.stringify(longer) }), { dispatched: true, projectChanged: true });
  await session.waitFor(nodes => header(nodes, longer.title));
  const longProject = await step.saved(project => project.title === longer.title);
  assert.deepEqual(longProject.entries, longer.entries);
  const longModel = await session.command('loaded-project');
  await step.activate('Script history');
  const isMore = node => node.type === 'UIButton' && /^Show \d+ more changes?$/.test(node.title ?? '');
  const firstPage = await session.waitFor(nodes => nodes.some(isMore));
  const more = firstPage.find(isMore);
  const changesPath = more.path.slice(0, more.path.lastIndexOf('.')) + '.';
  const inChanges = node => node.windowPath === more.windowPath && node.path.startsWith(changesPath);
  const finalDirection = node => inChanges(node) && node.type === 'ScriptTextView' && node.editable === false
    && node.text === longer.entries.at(-1).text;
  assert.equal(firstPage.filter(node => inChanges(node) && node.title === 'Technical details').length, 8);
  assert.ok(!firstPage.some(finalDirection));
  await step.reveal(more, firstPage);
  await step.activate(more.title);
  const allChanges = await session.waitFor(nodes => nodes.some(finalDirection));
  assert.ok(!allChanges.some(node => inChanges(node) && isMore(node)));
  await step.activate('Close');
  await session.waitFor(nodes => header(nodes, longer.title) && !nodes.some(node => node.title === 'Restore revision…'));
  assert.deepEqual(await session.command('loaded-project'), longModel);
  assert.deepEqual(sorted(await session.command('persisted-projects')), sorted([other, revised, longProject]));
  console.log('PASS: native history expands the complete local revision without changing it');
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
