import assert from 'node:assert/strict';
import { scriptAuthoringSteps, byID, focusedEditors, lines } from './script-authoring-steps.mjs';
import { structureFixture, sceneTitle } from './script-structure-cases.mjs';

const copy = value => structuredClone(value);
const content = project => { const value = copy(project); delete value.revision; delete value.modifiedAt; return value; };
const sorted = projects => [...projects].sort((a, b) => a.id.localeCompare(b.id));
const sceneButtons = (nodes, title) => nodes.filter(node => /UIButton$/.test(node.type)
  && node.title === `${title} ⌄` && node.enabled && node.hittable);

export async function createNavigateReopen(session) {
  const step = scriptAuthoringSteps(session);
  const capabilities = await session.command('capabilities');
  for (const command of ['menu', 'menu-action', 'import-json', 'loaded-project', 'persisted-projects', 'presented-alerts']) {
    assert.ok(capabilities.commands.includes(command), `Matching app provides ${command}`);
  }
  // Fail closed on an older app rather than treating a rejected dispatch as a skip.
  assert.ok(capabilities.semanticMenuActionScopes?.includes('script-scenes'),
    'Requires reviewed script-scenes scope in matching automation bundle');
  const startup = await step.openScript();
  const originalPackages = await session.command('persisted-projects');
  assert.deepEqual(originalPackages, [startup], 'Only synthetic startup content exists');
  const fixture = structureFixture();
  assert.deepEqual(await session.command('import-json', { text: JSON.stringify(fixture) }),
    { dispatched: true, projectChanged: true });
  await step.selectTab('Script');
  let current = await step.saved(project => project.title === fixture.title && project.id !== startup.id);
  assert.equal(current.revision, 0);
  assert.deepEqual(current, { ...fixture, id: current.id, createdAt: current.createdAt, modifiedAt: current.modifiedAt },
    'Production import preserves every fixture content field');
  assert.notEqual(current.id, fixture.id);
  assert.deepEqual((await session.command('loaded-project')).project, current);
  const imported = copy(current);

  async function packagesUnchanged(expected) {
    assert.deepEqual(sorted(await session.command('persisted-projects')), sorted(expected));
  }
  async function savedMutation(previous, expected, predicate, revisionDelta = 1) {
    await step.workspaceCommand('s');
    const project = await step.saved(project => project.id === previous.id
      && project.revision >= previous.revision + revisionDelta && predicate(project));
    assert.equal(project.revision, previous.revision + revisionDelta, 'Exactly the expected number of accepted mutations');
    assert.deepEqual(content(project), content(expected), 'Complete saved content equals explicit mutation oracle');
    assert.deepEqual((await session.command('loaded-project')).project, project, 'Loaded model equals complete saved package');
    await packagesUnchanged([...originalPackages, project]);
    return project;
  }
  async function sceneAction(selectedTitle, action, project) {
    const nodes = await session.waitFor(nodes => focusedEditors(nodes).length === 0 && sceneButtons(nodes, selectedTitle).length === 1);
    const button = sceneButtons(nodes, selectedTitle)[0];
    const observed = await session.command('menu', { target: button.path });
    assert.deepEqual(observed.secondary, []); assert.deepEqual(observed.context, []);
    assert.equal(observed.primary.length, 1);
    const menu = observed.primary[0];
    assert.equal(menu.type, 'menu'); assert.equal(menu.title, '');
    const titles = [...project.scenes].sort((a, b) => a.order - b.order).map(scene => scene.title);
    assert.deepEqual(menu.children.map(item => item.title), [...titles, 'New scene', 'Rename scene…', 'Delete scene…']);
    for (const item of menu.children) {
      assert.equal(item.type, 'action'); assert.equal(item.hidden, false); assert.equal(item.disabled, false);
      assert.equal(item.state, item.title === selectedTitle ? 'on' : 'off');
    }
    assert.equal(menu.children.filter(item => item.title === action).length, 1);
    assert.deepEqual(await session.command('menu-action', { target: button.path, scope: 'script-scenes', action }),
      { dispatched: true, coverage: 'semantic-menu-action' });
  }
  async function selected(title, visibleEntries) {
    await session.waitFor(nodes => sceneButtons(nodes, title).length === 1
      && lines(nodes).length === visibleEntries.length
      && visibleEntries.every(entry => byID(nodes, `script-line-${entry.id}`).some(node => node.text === entry.text)));
  }
  async function selectScene(title, fromTitle, project) {
    const beforeLoaded = await session.command('loaded-project');
    const beforePackages = await session.command('persisted-projects');
    await sceneAction(fromTitle, title, project);
    const scene = project.scenes.find(scene => scene.title === title);
    assert.ok(scene);
    await selected(title, project.entries.filter(entry => entry.sceneId === scene.id));
    assert.deepEqual(await session.command('loaded-project'), beforeLoaded, 'Navigation preserves model and exact Date witnesses');
    await packagesUnchanged(beforePackages);
  }

  await selected(imported.scenes[0].title, imported.entries);
  // Unsupported destructive/alert routes must reject before any presentation or
  // mutation. These are scope checks, never substitutes for Cancel coverage.
  const guardLoaded = await session.command('loaded-project');
  const guardPackages = await session.command('persisted-projects');
  const guardNodes = await session.command('snapshot');
  const guardTarget = sceneButtons(guardNodes, imported.scenes[0].title)[0].path;
  for (const request of [
    { action: 'Rename scene…' }, { action: 'Delete scene…' },
    { action: 'New scene', unexpected: true },
    { action: 'New scene', target: 'script-zoom' },
  ]) {
    await assert.rejects(session.command('menu-action', { target: guardTarget, scope: 'script-scenes', ...request }),
      /outside the supported isolated scope/, 'Scene scope refuses unsupported action, payload and owning control');
    assert.deepEqual(await session.command('presented-alerts'), [], 'Rejected action does not open an alert');
    assert.deepEqual(await session.command('loaded-project'), guardLoaded);
    await packagesUnchanged(guardPackages);
  }
  await sceneAction(imported.scenes[0].title, 'New scene', current);
  const created = await step.saved(project => project.id === current.id && project.scenes.length === 2);
  const fresh = created.scenes.find(scene => scene.id !== imported.scenes[0].id);
  assert.ok(fresh); assert.match(fresh.id, /^[0-9a-f-]{36}$/i);
  assert.deepEqual(fresh, { id: fresh.id, title: sceneTitle, order: 5 });
  const expectedCreated = { ...copy(imported), scenes: [...copy(imported.scenes), copy(fresh)] };
  current = await savedMutation(current, expectedCreated, project => project.scenes.some(scene => scene.id === fresh.id));
  await selected(sceneTitle, []);
  await step.workspaceHistory();
  current = await savedMutation(current, imported, project => project.scenes.length === 1);
  await selected(imported.scenes[0].title, imported.entries);
  await step.workspaceHistory(true);
  current = await savedMutation(current, expectedCreated, project => project.scenes.length === 2);
  // History restores content, not navigation; explicitly select the restored scene.
  await selectScene(sceneTitle, imported.scenes[0].title, current);
  console.log('PASS: AUT-J03/create-navigate-reopen/create-scene-undo-redo');

  const beforeDirection = current;
  await step.activate('Add direction');
  let nodes = await session.waitFor(nodes => focusedEditors(nodes).length === 1);
  const editor = focusedEditors(nodes)[0];
  const entryID = editor.identifier.slice('script-editor-'.length);
  assert.ok(entryID && !current.entries.some(entry => entry.id === entryID));
  await step.reveal(editor, nodes);
  await step.waitEditor(editor.identifier, 'Direction', 0, 'Direction'.length);
  const authoredText = 'A lantern flickers beside the gate.';
  await session.command('text', { target: editor.identifier, text: authoredText });
  await step.waitEditor(editor.identifier, authoredText, authoredText.length);
  await step.finishEditor();
  await selected(sceneTitle, [{ id: entryID, text: authoredText }]);
  const expectedDirection = { id: entryID, sceneId: fresh.id, order: 0,
    kind: 'direction', text: authoredText, ownedDurationMs: 0, coverageDurationMs: 3000,
    color: 'purple', words: [], characterLinks: [] };
  current = await savedMutation(beforeDirection,
    { ...copy(beforeDirection), entries: [...copy(beforeDirection.entries), expectedDirection] },
    project => project.entries.find(entry => entry.id === entryID)?.text === authoredText, 2);
  await selectScene(imported.scenes[0].title, sceneTitle, current);
  await selectScene(sceneTitle, imported.scenes[0].title, current);
  console.log('PASS: AUT-J03/create-navigate-reopen/add-direction-switch-scenes');

  const finalLoaded = await session.command('loaded-project');
  const finalPackages = await session.command('persisted-projects');
  async function open(project) {
    const header = await session.waitFor(nodes => byID(nodes, 'workspace-project').some(node => node.enabled && node.hittable));
    await session.command('activate', { target: byID(header, 'workspace-project')[0].path });
    const searchNodes = await session.waitFor(nodes => nodes.some(node => node.placeholder === 'Find a project' && node.hittable));
    const search = searchNodes.find(node => node.placeholder === 'Find a project' && node.hittable);
    await session.command('text', { target: search.path, text: project.title });
    await session.waitFor(nodes => nodes.some(node => node.text === `${project.title} · ${project.scenes.length} scene${project.scenes.length === 1 ? '' : 's'}`));
    await step.activate('Open project');
    await session.waitFor(nodes => byID(nodes, 'workspace-project').some(node => node.title === project.title && node.hittable));
    const loaded = await session.command('loaded-project');
    assert.deepEqual(loaded.project, project);
    return loaded;
  }
  await open(startup);
  assert.deepEqual(await open(current), finalLoaded, 'Different-document reopen retains full project and exact Date witnesses');
  await packagesUnchanged(finalPackages);
  await step.selectTab('Script');
  // Production document open chooses the first scene; verify before selecting.
  await selected(imported.scenes[0].title, imported.entries);
  await selectScene(sceneTitle, imported.scenes[0].title, current);
  console.log('PASS: AUT-J03/create-navigate-reopen/save-browser-reopen');
}
