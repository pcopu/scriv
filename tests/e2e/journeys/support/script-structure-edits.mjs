import assert from 'node:assert/strict';
import { audioLibrarySteps, sortedProjects } from './audio-library-steps.mjs';
import { scriptAuthoringSteps, lines } from './script-authoring-steps.mjs';

const originalScene = 'EXT. GARDEN — DAY';
const secondScene = 'INT. SHED — NIGHT';
const entryActions = 'script-entry-actions';
const first = { id: 'first-direction', sceneId: 'garden', order: 0, kind: 'direction',
  text: 'A lantern hangs from the gate.', ownedDurationMs: 1000, coverageDurationMs: 1000,
  color: 'purple', words: [], characterLinks: [] };
const second = { ...first, id: 'second-direction', order: 10, coverageDurationMs: 2000, text: 'The gate opens.' };
const third = { ...first, id: 'third-direction', order: 20, text: 'The path is clear.' };
const survivor = { ...first, id: 'surviving-direction', sceneId: 'shed', text: 'A window is shut.' };
const entries = [first, second, third, survivor];
const cues = entries.map((entry, index) => ({
  id: 'picture-' + entry.id, sceneId: entry.sceneId, label: 'Picture ' + (index + 1), prompt: '',
  startMs: index === 3 ? 0 : index * 1000, endMs: index === 3 ? 1000 : (index + 1) * 1000,
  startAnchor: { entryId: entry.id, offsetMs: 0 }, authoredDurationMs: 1000,
}));
const fixture = { schemaVersion: 1, id: 'script-editing-input', title: 'Script structural edit fixture',
  createdAt: 1700000000000, modifiedAt: 1700000000000, revision: 0,
  scenes: [{ id: 'garden', title: originalScene, order: 0 }, { id: 'shed', title: secondScene, order: 1 }],
  entries, cues, characters: [], images: [], audioAssets: [], audioClips: [], audioVolume: 1 };
const { id: entryID } = first;
const dispatched = { dispatched: true, coverage: 'semantic-menu-action' };
const content = ({ revision, modifiedAt, ...rest }) => rest;

export async function moveAndDeleteStructure(session) {
  const caps = await session.command('capabilities');
  assert.ok(caps.semanticMenuActionScopes.includes('script-entries'), 'The selected entry exposes scoped structural menu actions');
  const step = scriptAuthoringSteps(session), ui = audioLibrarySteps(session);
  const startup = await step.openScript();
  assert.deepEqual(await session.command('import-json', { text: JSON.stringify(fixture) }),
    { dispatched: true, projectChanged: true });
  await step.selectTab('Script');
  let current = await step.saved(project => project.title === fixture.title);
  const original = current;
  assert.deepEqual(current, { ...fixture, id: current.id, createdAt: current.createdAt, modifiedAt: current.modifiedAt });

  async function assertUnchanged(witness) {
    assert.deepEqual(await session.command('loaded-project'), witness);
    assert.deepEqual(sortedProjects(await session.command('persisted-projects')), sortedProjects([startup, current]));
  }
  async function savedEdit(expected) {
    await step.workspaceCommand('s');
    const revision = current.revision + 1;
    const next = await step.saved(project => project.id === current.id && project.revision >= revision);
    assert.equal(next.revision, revision);
    assert.deepEqual(content(next), content(expected));
    current = next;
    assert.deepEqual((await session.command('loaded-project')).project, current);
    assert.deepEqual(sortedProjects(await session.command('persisted-projects')), sortedProjects([startup, current]));
  }
  const entryAction = (action, fields = {}) => session.command('menu-action', {
    target: entryActions, scope: 'script-entries', entryID, action, ...fields,
  });
  async function assertEntryMenu(disabled) {
    const menu = await session.command('menu', { target: entryActions });
    assert.deepEqual(menu.secondary, []); assert.deepEqual(menu.context, []);
    assert.equal(menu.primary.length, 1);
    assert.deepEqual(menu.primary[0].children.map(({ title, disabled }) => [title, disabled]),
      ['Move up', 'Move down', 'Delete entry'].map(title => [title, title === disabled]));
  }
  async function verifyVisibleOrder(ids) {
    await session.waitFor(nodes => {
      const visible = lines(nodes).slice().sort((a, b) => a.frame.y - b.frame.y);
      return visible.length === ids.length && visible.every((node, index) => node.identifier === 'script-line-' + ids[index]);
    });
  }
  await verifyVisibleOrder([first.id, second.id, third.id]);
  const witness = await session.command('loaded-project');
  await assertEntryMenu('Move up');
  for (const [action, fields] of [
    ['Move up', {}], ['Move down', { entryID: second.id }], ['Move down', { unexpected: true }],
    ['Move down', { target: 'script-zoom' }], ['Edit text', {}],
  ]) await assert.rejects(entryAction(action, fields), /Entry menu action is outside the supported isolated scope/);
  await assertUnchanged(witness);

  const moved = { ...original, entries: [{ ...first, order: 15 }, second, third, survivor],
    cues: [{ ...cues[0], startMs: 1000, endMs: 2000 }, { ...cues[1], startMs: 0, endMs: 1000 }, ...cues.slice(2)] };
  assert.deepEqual(await entryAction('Move down'), dispatched);
  await savedEdit(moved);
  await verifyVisibleOrder([second.id, first.id, third.id]);
  await assertEntryMenu(null);
  assert.deepEqual(await entryAction('Move up'), dispatched);
  await savedEdit({ ...original, entries: [{ ...first, order: 9 }, second, third, survivor] });
  await verifyVisibleOrder([first.id, second.id, third.id]);
  assert.deepEqual(await entryAction('Move down'), dispatched);
  await savedEdit(moved);

  async function confirms(title, action) {
    const controls = await session.waitFor(nodes => nodes.some(node => node.text === title)
      && nodes.some(node => node.identifier === 'script-delete-confirm' && node.hittable && node.enabled)
      && nodes.some(node => node.identifier === 'script-delete-cancel' && node.hittable && node.enabled));
    assert.equal(controls.find(node => node.identifier === 'script-delete-confirm').title, 'Delete');
    await ui.activate(node => node.identifier === 'script-delete-' + action);
    await session.waitFor(nodes => !nodes.some(node => node.identifier === 'script-delete-confirm')
      && nodes.some(node => node.identifier === 'workspace-tabs' && node.hittable));
  }
  const movedWitness = await session.command('loaded-project');
  assert.deepEqual(await entryAction('Delete entry'), dispatched);
  await confirms('Delete this entry?', 'cancel');
  await assertUnchanged(movedWitness);
  assert.deepEqual(await entryAction('Delete entry'), dispatched);
  await confirms('Delete this entry?', 'confirm');
  const removedEntry = { ...moved,
    entries: [{ ...second, coverageDurationMs: 1000 }, third, survivor],
    cues: [{ ...cues[1], startMs: 0, endMs: 1000 }, { ...cues[2], startMs: 1000, endMs: 2000 }, cues[3]] };
  await savedEdit(removedEntry);
  await verifyVisibleOrder([second.id, third.id]);

  async function deleteScene(sceneID) {
    const button = await ui.reveal(node => node.type === 'UIButton' && node.title === originalScene + ' ⌄');
    return session.command('menu-action', { target: button.path, scope: 'script-scenes', sceneID, action: 'Delete scene…' });
  }
  const sceneWitness = await session.command('loaded-project');
  await assert.rejects(deleteScene('shed'), /Scene menu action is outside the supported isolated scope/);
  assert.deepEqual(await deleteScene('garden'), dispatched);
  await confirms('Delete this scene?', 'cancel');
  await assertUnchanged(sceneWitness);
  assert.deepEqual(await deleteScene('garden'), dispatched);
  await confirms('Delete this scene?', 'confirm');
  const deleted = { ...removedEntry, scenes: [original.scenes[1]], entries: [survivor], cues: [cues[3]] };
  await savedEdit(deleted);
  await verifyVisibleOrder([survivor.id]);
  await step.workspaceHistory();
  await savedEdit(removedEntry);
  await step.workspaceHistory(true);
  await savedEdit(deleted);
  assert.deepEqual(await session.command('presented-alerts'), []);

  // One representable step between the surviving neighbors leaves no order
  // value for the moved entry. Only that scene should be renumbered.
  const crowded = { ...fixture, id: 'script-crowded-input', title: 'Script crowded ordering fixture',
    entries: [first, { ...second, order: 1 }, { ...third, order: 1 + Number.EPSILON }, survivor] };
  assert.deepEqual(await session.command('import-json', { text: JSON.stringify(crowded) }),
    { dispatched: true, projectChanged: true });
  await step.selectTab('Script');
  const beforeCrowdedMove = await step.saved(project => project.title === crowded.title);
  assert.deepEqual(beforeCrowdedMove, { ...crowded, id: beforeCrowdedMove.id,
    createdAt: beforeCrowdedMove.createdAt, modifiedAt: beforeCrowdedMove.modifiedAt });
  await verifyVisibleOrder([first.id, second.id, third.id]);
  assert.deepEqual(await entryAction('Move down'), dispatched);
  await step.workspaceCommand('s');
  const normalized = await step.saved(project => project.id === beforeCrowdedMove.id && project.revision > 0);
  assert.equal(normalized.revision, 1);
  assert.deepEqual(content(normalized), { ...content(beforeCrowdedMove),
    entries: [{ ...first, order: 1 }, { ...second, order: 0 }, { ...third, order: 2 }, survivor], cues: moved.cues });
  await verifyVisibleOrder([second.id, first.id, third.id]);
  assert.deepEqual((await session.command('loaded-project')).project, normalized);
  assert.deepEqual(sortedProjects(await session.command('persisted-projects')), sortedProjects([startup, current, normalized]));
}
