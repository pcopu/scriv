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
try {
  await session.waitFor(nodes => nodes.some(node => node.identifier === 'workspace-project' && node.enabled && node.hittable));
  for (let repeat = 0; repeat < 2; repeat++) {
    await session.command('activate', { target: 'workspace-project' });
    let nodes = await session.waitFor(nodes => nodes.some(node => node.placeholder === 'Find a project'));
    const search = nodes.find(node => node.placeholder === 'Find a project');
    await session.command('text', { target: search.path, text: 'no-such-synthetic-project-7c891' });
    await session.waitFor(nodes => nodes.some(node => node.text === 'No matching projects'));
    // The CLI must respect modal routing rather than activating covered controls.
    await assert.rejects(session.command('select', { target: 'workspace-tabs', index: 1 }), /active presentation|disabled|exactly one/);
    await click('Clear search');
    await session.waitFor(nodes => nodes.some(node => node.placeholder === 'Find a project' && node.text === ''));
    await click('Close Projects');
    await session.waitFor(nodes => nodes.some(node => node.identifier === 'workspace-project' && node.enabled && node.hittable) && !nodes.some(node => node.placeholder === 'Find a project'));
  }
  // Save only the session-owned sample, then create a distinct local project.
  await session.command('key', { input: 's', modifiers: ['command'] });
  const original = await waitForSavedProject(session, project => project.title === 'YAM MAN');
  const originalLoaded = await session.command('loaded-project');
  assert.equal(originalLoaded.project.id, original.id);
  await session.command('activate', { target: 'workspace-project' });
  await click('New project');
  const created = await waitForSavedProject(session, project => project.id !== original.id);
  assert.equal(created.title, 'Untitled');
  assert.deepEqual(created.entries.map(entry => entry.text), ['Describe the opening moment.', 'Your first line.']);
  let nodes = await session.command('snapshot');
  if (nodes.some(node => node.placeholder === 'Find a project')) await click('Close Projects');
  await session.waitFor(nodes => nodes.some(node => node.identifier === 'workspace-project' && node.title === 'Untitled' && node.hittable));
  const createdLoaded = await session.command('loaded-project');
  assert.equal(createdLoaded.project.id, created.id);

  await session.command('activate', { target: 'workspace-project' });
  for (const [source, emptyTitle] of [['Scriv Cloud', 'Your scriv cloud'], ['Team projects', 'Your team projects']]) {
    await click(source);
    nodes = await session.waitFor(nodes => nodes.some(node => node.text === emptyTitle));
    assert.ok(nodes.some(node => node.text === 'Sign in for free script storage and team access. Your local projects stay available without an account.'));
    assert.ok(nodes.some(node => node.title === 'Open project' && node.enabled === false), 'Signed-out source cannot open a local project');
    assert.ok(nodes.some(node => node.title === 'Sign in to Scriv' && node.hittable), 'Empty cloud source offers sign-in');
  }
  await click('On this Mac');
  // Leading/trailing whitespace and case folding operate on real local metadata.
  for (const [query, expected, baseline] of [['  yAm mAn  ', original, originalLoaded], ['  uNtItLeD  ', created, createdLoaded]]) {
    nodes = await session.waitFor(nodes => nodes.some(node => node.placeholder === 'Find a project' && node.hittable));
    await session.command('text', { target: nodes.find(node => node.placeholder === 'Find a project' && node.hittable).path, text: query });
    await session.waitFor(nodes => nodes.some(node => node.text === `${expected.title} · ${expected.scenes.length} scene${expected.scenes.length === 1 ? '' : 's'}`));
    await click('Open project');
    await session.waitFor(nodes => nodes.some(node => node.identifier === 'workspace-project' && node.title === expected.title && node.hittable) && !nodes.some(node => node.placeholder === 'Find a project'));
    assert.deepEqual(await session.command('loaded-project'), baseline, 'Filtered Open restores the complete saved model and exact dates');
    assert.deepEqual(await session.command('presented-alerts'), [], 'Opening owned packages presents no recovery error');
    if (expected.id === original.id) {
      await session.command('activate', { target: 'workspace-project' });
      await click('Recent');
    }
  }
  const retained = await session.command('persisted-projects');
  assert.equal(retained.length, 2, 'Filtering and opening never duplicate or delete a package');
  assert.deepEqual(retained.find(project => project.id === original.id), original, 'Original sample remains byte-model equivalent');
  assert.deepEqual(retained.find(project => project.id === created.id), created, 'Created project remains byte-model equivalent');
  const expectedPackages = [...retained].sort((left, right) => left.id.localeCompare(right.id));
  for (const test of [
    { query: 'no-such-synthetic-project-7c891', input: 'Escape', modifiers: [], action: 'closeCommand', expected: created, baseline: createdLoaded },
    { query: '  yAm mAn  ', input: '\r', modifiers: ['command'], action: 'openCommand', expected: original, baseline: originalLoaded }
  ]) {
    await session.command('activate', { target: 'workspace-project' });
    nodes = await session.waitFor(nodes => nodes.some(node => node.placeholder === 'Find a project' && node.hittable));
    await session.command('text', { target: nodes.find(node => node.placeholder === 'Find a project' && node.hittable).path, text: test.query });
    await session.waitFor(nodes => nodes.some(node => node.text === (test.input === 'Escape'
      ? 'No matching projects'
      : `${original.title} · ${original.scenes.length} scene${original.scenes.length === 1 ? '' : 's'}`)));
    const commands = await session.command('keys');
    const handler = commands.find(command => command.input === test.input
      && command.modifiers.length === test.modifiers.length
      && test.modifiers.every(modifier => command.modifiers.includes(modifier)));
    assert.ok(handler, 'The active responder chain offers the exact browser shortcut');
    assert.equal(handler.responderType, 'ProjectBrowserController', 'Public key dispatch reaches the presented browser first');
    assert.equal(handler.action, test.action);
    assert.deepEqual(await session.command('key', { input: test.input, modifiers: test.modifiers }), { dispatched: true });
    await session.waitFor(nodes => nodes.some(node => node.identifier === 'workspace-project' && node.title === test.expected.title && node.enabled && node.hittable)
      && !nodes.some(node => node.placeholder === 'Find a project'));
    assert.deepEqual(await session.command('loaded-project'), test.baseline, 'Browser keyboard cancellation/open preserves the complete expected model and exact dates');
    assert.deepEqual(await session.command('presented-alerts'), [], 'Browser shortcuts present no error or recovery alert');
    const packages = await session.command('persisted-projects');
    assert.deepEqual(packages.sort((left, right) => left.id.localeCompare(right.id)), expectedPackages,
      'Browser keyboard cancellation/open preserves exactly both complete saved packages');
  }
  console.log('PASS: actual project browser search, sources, local open/reopen, keyboard cancellation/open, model preservation, and modal routing');
} finally { await session.close(); }
