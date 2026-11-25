import assert from 'node:assert/strict';
import { content } from './support/picture-coverage-cases.mjs';
import { runScriptJourney, scriptAuthoringSteps } from './support/script-authoring-steps.mjs';
import { structureFixture } from './support/script-structure-cases.mjs';

const command = 'script-duration-gesture';

async function scrub(session) {
  assert.ok((await session.command('capabilities')).semanticGestureCommands.includes(command),
    'The native Script duration gesture is discoverable');
  const ui = scriptAuthoringSteps(session);
  await ui.openScript();
  const input = structureFixture();
  input.title = 'Synthetic Script duration gesture';
  Object.assign(input.entries[0], { ownedDurationMs: 1000, coverageDurationMs: 1000 });
  assert.deepEqual(await session.command('import-json', { text: JSON.stringify(input) }), { dispatched: true, projectChanged: true });
  const before = await ui.saved(project => project.title === input.title);
  await ui.selectTab('Script');

  const duration = node => node.type === 'UIButton' && node.label === 'Edit owned duration' && node.hittable;
  async function gesture(phase, fields = {}) {
    const nodes = await session.waitFor(nodes => nodes.filter(duration).length === 1);
    return session.command(command, { target: nodes.find(duration).path, phase, ...fields });
  }
  async function unchanged() {
    assert.deepEqual((await session.command('loaded-project')).project, before);
    assert.deepEqual((await session.command('persisted-projects')).find(project => project.id === before.id), before);
  }
  const dispatch = async (phase, fields) => assert.deepEqual(await gesture(phase, fields), { dispatched: true });
  const display = (title, value = '') => session.waitFor(nodes => nodes.some(node => duration(node) && node.title === title && node.value === value));

  await display('1.0s');
  await assert.rejects(gesture('end', { translation: -20 }), /no active script duration gesture/i);
  await dispatch('begin');
  await assert.rejects(gesture('begin'), /active script duration gesture/i);
  await assert.rejects(gesture('change', { translation: true }), /invalid script duration sample/i);
  await dispatch('change', { translation: -20 });
  await display('1.4s', '1.4s, preview; release to apply');
  await unchanged();
  await dispatch('cancel');
  await display('1.0s');
  await unchanged();

  await dispatch('begin');
  await dispatch('end', { translation: 0 });
  await display('1.0s');
  await unchanged();
  await dispatch('begin');
  await dispatch('end', { translation: -20 });
  const saved = await ui.saved(project => project.id === before.id && project.revision > before.revision);
  assert.equal(saved.revision, before.revision + 1);
  const expected = content(before);
  Object.assign(expected.entries[0], { ownedDurationMs: 1400, coverageDurationMs: 1400 });
  assert.deepEqual(content(saved), expected);
  await display('1.4s');
  assert.deepEqual((await session.command('loaded-project')).project, saved);
  await assert.rejects(gesture('end', { translation: -20 }), /no active script duration gesture/i);
  assert.deepEqual((await session.command('persisted-projects')).find(project => project.id === saved.id), saved);
}

await runScriptJourney({ journey: 'AUT-J03', workflows: { 'hold-and-drag': scrub }, cases: [{
  group: 'hold-and-drag', id: 'script-duration-preview-cancel-apply',
  oracles: ['The native duration pill previews without saving, cancels cleanly, and commits one exact revision on release.'],
}] });
