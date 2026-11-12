import assert from 'node:assert/strict';
import { ScrivSession } from '../../cli/scriv.mjs';
import { waitForSavedProject } from './support/saved-projects.mjs';

assert.ok(process.env.SCRIV_E2E_APP, 'Set SCRIV_E2E_APP to an automation-enabled Catalyst bundle');
const session = await ScrivSession.launch(process.env.SCRIV_E2E_APP);
const buttons = (nodes, title) => nodes.filter(node => node.enabled && node.hittable && (node.title === title || node.label === title));
async function click(title) {
  const nodes = await session.waitFor(nodes => buttons(nodes, title).length === 1);
  await session.command('activate', { target: buttons(nodes, title)[0].path });
}
async function workspaceReady() {
  return session.waitFor(nodes => nodes.some(node => node.identifier === 'workspace-tabs' && node.enabled && node.hittable));
}
try {
  await workspaceReady();
  await session.command('key', { input: 's', modifiers: ['command'] });
  const original = await waitForSavedProject(session, project => project.entries.length > 0);
  assert.ok(original.scenes.some(scene => scene.id === 'scene-farm'), 'The saved startup fixture is the original farm sample');
  const sampleNodes = await session.command('snapshot');
  const seek = sampleNodes.filter(node => node.identifier === 'scene-playback-position');
  assert.equal(seek.length, 1, 'One actual scene duration control');
  assert.equal(seek[0].slider.maximum, 56300, 'Real scene duration is exactly the frozen sample 56,300 ms');
  // Both this persisted sample and each persisted New template pass the actual
  // ProjectRepository.saveLocked validator before publication. No JS validator.
  const known = new Set([original.id]);
  for (let pass = 0; pass < 2; pass++) {
    await session.command('activate', { target: 'workspace-project' });
    await session.waitFor(nodes => nodes.some(node => node.placeholder === 'Find a project' && node.hittable));
    await click('New project');
    const created = await waitForSavedProject(session, project => !known.has(project.id));
    known.add(created.id);
    assert.equal(created.title, 'Untitled');
    assert.deepEqual(created.entries.map(entry => entry.text), ['Describe the opening moment.', 'Your first line.'], 'New project starts with the blank template, not the previous script');
    assert.equal(created.characters.length, 0, 'New project does not copy character profiles');
    assert.equal(created.cues.length, 1, 'New project contains only the template cue');
    assert.equal(created.cues[0].label, '01A');
    const nodes = await session.command('snapshot');
    if (nodes.some(node => node.placeholder === 'Find a project')) await click('Close Projects');
    await workspaceReady();
    await session.command('key', { input: 's', modifiers: ['command'] });
    await waitForSavedProject(session, project => project.id === created.id);
    const retained = (await session.command('persisted-projects')).find(project => project.id === original.id);
    assert.deepEqual(retained.entries, original.entries, 'Creating a project preserves the original saved script');
    assert.deepEqual(retained.characters, original.characters, 'Creating a project preserves original character profiles');
  }
  const projects = await session.command('persisted-projects');
  assert.equal(projects.length, 3, 'Exactly one distinct saved project is created per action');
  console.log('PASS: actual project creation, repeat navigation, save and preservation of prior projects');
} finally { await session.close(); }
