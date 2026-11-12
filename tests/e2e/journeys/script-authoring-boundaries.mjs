import assert from 'node:assert/strict';
import { scriptAuthoringSteps, runScriptJourney, byID, readyTabs, lines } from './support/script-authoring-steps.mjs';
import { boundaryCases } from './support/script-authoring-cases.mjs';

// AUT-J03 eligibility portion only. Observe the installed context-menu builder;
// never pretend this is physical menu presentation or execution of Move actions.
function rowForEntry(nodes, entry) {
  const displays = byID(nodes, `script-line-${entry.id}`);
  if (displays.length !== 1 || displays[0].text !== entry.text) return;
  const rows = nodes.filter(node => /(?:^|\.)ScriptEntryRow$/.test(node.type)
    && displays[0].path.startsWith(node.path + '.'));
  return rows.length === 1 ? rows[0] : undefined;
}
function actionsIn(records) {
  assert.ok(Array.isArray(records), 'The menu response contains an explicit context array');
  return records.flatMap(record => {
    assert.equal(typeof record.title, 'string', 'Menu titles come from the native menu elements');
    if (record.type === 'menu') return actionsIn(record.children);
    assert.equal(record.type, 'action', 'The required line menu has no unresolved/deferred elements');
    assert.equal(typeof record.disabled, 'boolean', 'Disabled is an observed UIAction attribute');
    assert.equal(typeof record.hidden, 'boolean', 'Hidden is an observed UIAction attribute');
    assert.ok(['off', 'on', 'mixed'].includes(record.state), 'State is an observed UIAction state');
    return [record];
  });
}
async function sceneEndEligibility(session) {
  const step = scriptAuthoringSteps(session);
  assert.ok((await session.command('capabilities')).commands.includes('menu'), 'Matching app advertises menu observation');
  await session.waitFor(readyTabs);
  // Flush startup so a delayed sample save cannot be mistaken for New.
  await step.workspaceCommand('s');
  await step.saved(project => typeof project.id === 'string');
  const originalProjects = await session.command('persisted-projects');
  const originalIDs = new Set(originalProjects.map(project => project.id));
  await step.workspaceCommand('n');
  await session.waitFor(readyTabs);
  await step.workspaceCommand('s');
  const created = await step.saved(project => !originalIDs.has(project.id));
  assert.equal(created.scenes.length, 1, 'The actual new-project template has exactly one scene');
  assert.equal(created.entries.length, 2, 'The actual new-project template has exactly two entries');
  assert.ok(created.entries.every(entry => entry.sceneId === created.scenes[0].id), 'Both entries belong to that scene');
  assert.ok(created.entries.every(entry => Number.isFinite(entry.order)), 'Saved scene orders are numeric');
  const entries = [...created.entries].sort((a, b) => a.order - b.order);
  const [first, last] = entries;
  assert.notEqual(first.id, last.id, 'The scene has distinct first and last identities');
  assert.ok(first.order < last.order, 'Saved scene order unambiguously identifies the ends');
  assert.deepEqual(entries.map(entry => entry.text), ['Describe the opening moment.', 'Your first line.'],
    'New uses the real blank template rather than the previous project');
  async function boundaryActions(entry) {
    const nodes = await session.waitFor(nodes => lines(nodes).length === 2 && entries.every(candidate => rowForEntry(nodes, candidate)));
    // Resolve the mounted row after every tab change; never cache a native path.
    const menu = await session.command('menu', { target: rowForEntry(nodes, entry).path });
    assert.ok(Array.isArray(menu.context),
      'Matching app must expose the mounted ScriptEntryRow context builder; no controller/model fallback');
    assert.equal(menu.context.length, 1, 'The mounted row supplies exactly one real context menu');
    assert.equal(menu.context[0].type, 'menu');
    const actions = actionsIn(menu.context);
    const action = title => {
      const matches = actions.filter(candidate => candidate.title === title);
      assert.equal(matches.length, 1, `The real line menu contains exactly one ${title} action`);
      assert.equal(matches[0].hidden, false, `${title} is offered rather than hidden`);
      return matches[0];
    };
    return { up: action('Move up'), down: action('Move down') };
  }
  for (let pass = 0; pass < boundaryCases.length; pass++) {
    if (pass > 0) await step.selectTab('Storyboard', { force: true });
    await step.selectTab('Script', { force: true });
    const firstMenu = await boundaryActions(first);
    const lastMenu = await boundaryActions(last);
    assert.equal(firstMenu.up.disabled, true, 'First line cannot Move up past the scene start (baseline 1)');
    assert.equal(firstMenu.down.disabled, false, 'First line can Move down within the scene (baseline 2)');
    assert.equal(lastMenu.up.disabled, false, 'Last line can Move up within the scene (baseline 3)');
    assert.equal(lastMenu.down.disabled, true, 'Last line cannot Move down past the scene end (baseline 4)');
    await step.workspaceCommand('s');
    const saved = await step.saved(project => project.id === created.id);
    for (const field of ['entries', 'scenes', 'cues', 'characters']) {
      assert.deepEqual(saved[field], created[field], `Menu observation and navigation preserve saved ${field}`);
    }
    const projects = await session.command('persisted-projects');
    assert.equal(projects.length, originalProjects.length + 1, 'Exactly one new project was created');
    for (const original of originalProjects) assert.deepEqual(projects.find(project => project.id === original.id), original,
      'Menu observation and tab navigation preserve every original saved project');
    console.log(`PASS: AUT-J03/scene-end-eligibility/${boundaryCases[pass].id}`);
  }
}
await runScriptJourney({ journey: 'AUT-J03', workflows: { 'scene-end-eligibility': sceneEndEligibility }, cases: boundaryCases,
  excluded: ['physical context-menu presentation/dismissal', 'Move action execution', 'scene/speaker/deletion changes', 'relaunch/reopen'] });
