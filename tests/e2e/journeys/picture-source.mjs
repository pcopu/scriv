import assert from 'node:assert/strict';
import { ScrivSession } from '../../../cli/scriv.mjs';
import { waitForSavedProject } from '../support/saved-projects.mjs';
import { stableContent } from './support/audio-library-fixtures.mjs';
import { audioLibrarySteps, sortedProjects } from './support/audio-library-steps.mjs';
import { packageFixtureToken, packageImageFixture, validatePackageImageFixture } from './support/package-image-fixture.mjs';

assert.ok(process.env.SCRIV_E2E_APP, 'Requires a Catalyst automation build');
validatePackageImageFixture();
const session = await ScrivSession.launch(process.env.SCRIV_E2E_APP);
const ui = audioLibrarySteps(session);
const ready = node => node.enabled && node.hittable;
const card = node => node.label === 'Picture actions for Foreground';
const picker = node => node.identifier === 'picture-source-entry';
const field = node => node.label === 'Offset from entry, seconds';
const button = title => node => node.title === title && node.type === 'UIButton' && ready(node);
const dispatched = { dispatched: true, coverage: 'semantic-menu-action' };
const first = 'Dialogue · First source', second = 'Dialogue · Second source';
const edit = { scope: 'storyboard-picture-source', action: 'Picture source…' };
let step = 'open a saved project with two picture sources';

async function openEditor() {
  const target = (await ui.reveal(card)).path;
  const menu = await session.command('menu', { target });
  assert.equal(menu.primary[0].children.filter(action => action.title === edit.action && !action.disabled).length, 1);
  assert.ok(menu.primary[0].children.every(action => action.title !== 'Merge with next placement'));
  assert.deepEqual(await session.command('menu-action', { target, ...edit }), dispatched);
  const nodes = await session.waitFor(nodes => nodes.some(node => picker(node) && ready(node))
    && nodes.some(button('Save source')));
  assert.equal(nodes.find(picker).title, second);
  assert.ok(nodes.some(node => node.text === 'Picture source'));
  assert.ok(nodes.some(node => field(node) && node.text === '0.000'));
}
async function closeEditor() {
  await session.waitFor(nodes => !nodes.some(picker) && nodes.some(node => card(node) && ready(node)));
}

try {
  const capability = await session.command('capabilities');
  assert.equal(capability.cloudIsolation.network, 'disabled');
  await ui.tab('Script');
  await session.command('key', { input: 's', modifiers: ['command'] });
  const sample = await waitForSavedProject(session, project => project.title === 'YAM MAN');
  const staged = await session.command('stage-package-fixture', { fixture: packageFixtureToken });
  const before = { ...packageImageFixture(), id: staged.projectID };
  const loadedBefore = await ui.openProject(before);
  assert.deepEqual(loadedBefore.project, before);
  await ui.tab('Storyboard');
  await session.command('end-editing');
  const assetsBefore = await session.command('local-image-evidence');
  const packages = async () => sortedProjects(await session.command('persisted-projects'));
  const unchanged = async () => assert.deepEqual(await packages(), sortedProjects([sample, before]));

  step = 'open the genuine Picture source menu action and cancel';
  await openEditor();
  for (const scope of [edit.scope, 'picture-source-entry']) assert.ok(capability.semanticMenuActionScopes.includes(scope));
  await ui.activate(button('Cancel'));
  await closeEditor();
  await unchanged();
  assert.deepEqual(await session.command('loaded-project'), loadedBefore);

  step = 'save an unchanged source without a new revision';
  await openEditor();
  await ui.activate(button('Save source'));
  await closeEditor();
  await unchanged();

  step = 'reject invalid offsets without changing the saved project';
  await openEditor();
  async function enterOffset(text) {
    const target = (await ui.reveal(field)).path;
    await session.command('text', { target, text });
    await session.waitFor(nodes => nodes.some(node => field(node) && node.text === text));
  }
  for (const [text, message] of [
    ['-1', 'Enter an offset inside the selected source’s owned slot.'],
    ['2.000', 'Offset must be before the source’s end; zero-owned directions use 0.'],
  ]) {
    await enterOffset(text);
    await ui.activate(button('Save source'));
    await session.waitFor(nodes => nodes.some(node => node.text === message));
    await unchanged();
  }

  step = 'select a different source and save its new offset';
  const target = (await ui.reveal(picker)).path;
  const menu = await session.command('menu', { target });
  assert.deepEqual(menu.primary[0].children.map(action => [action.title, action.state]), [[first, 'off'], [second, 'on']]);
  for (const request of [
    { target, scope: 'picture-source-entry', action: 'Missing entry' },
    { target, scope: 'picture-source-entry', action: first, entryID: 'a' },
    { target: (await ui.reveal(field)).path, scope: 'picture-source-entry', action: first },
  ]) await assert.rejects(session.command('menu-action', request), /outside the supported/);
  await unchanged();
  assert.deepEqual(await session.command('menu-action', { target, scope: 'picture-source-entry', action: first }), dispatched);
  await session.waitFor(nodes => nodes.some(node => picker(node) && node.title === first)
    && nodes.some(node => field(node) && node.text === '0.000') && nodes.some(node => node.text === 'First source'));
  await enterOffset('0.600');
  await ui.activate(button('Save source'));
  await closeEditor();
  const saved = await waitForSavedProject(session, project => project.id === before.id && project.revision === before.revision + 1);
  const [background, foreground] = before.cues;
  assert.deepEqual(stableContent(saved), stableContent({ ...before, cues: [background, {
    ...foreground, startMs: 600, endMs: 1600, startAnchor: { entryId: 'a', offsetMs: 600 },
  }] }));
  const loadedAfter = await session.command('loaded-project');
  assert.deepEqual(loadedAfter.project, saved);
  assert.equal(loadedAfter.dateReferenceTimeBits.createdAt, loadedBefore.dateReferenceTimeBits.createdAt);
  assert.deepEqual(loadedAfter.dateReferenceTimeBits.images, loadedBefore.dateReferenceTimeBits.images);
  assert.deepEqual(await session.command('local-image-evidence'), assetsBefore);
  await ui.openProject(sample);
  assert.deepEqual(await ui.openProject(saved), loadedAfter);
  assert.deepEqual(await packages(), sortedProjects([sample, saved]));
  assert.deepEqual(await session.command('presented-alerts'), []);
} catch (error) { throw new Error(`Native Picture source failed during ${step}`, { cause: error }); }
finally { await session.close(); }
