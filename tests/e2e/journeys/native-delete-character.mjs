import assert from 'node:assert/strict';
import { ScrivSession } from '../../../cli/scriv.mjs';
import { waitForSavedProject } from '../support/saved-projects.mjs';
import { stableContent } from './support/audio-library-fixtures.mjs';
import { audioLibrarySteps, sortedProjects } from './support/audio-library-steps.mjs';
import { packageImageFixture } from './support/package-image-fixture.mjs';

assert.ok(process.env.SCRIV_E2E_APP, 'Requires an isolated Catalyst automation bundle');
const session = await ScrivSession.launch(process.env.SCRIV_E2E_APP);
const ui = audioLibrarySteps(session);
const input = packageImageFixture();
const person = (id, name) => ({ id, name, color: 'blue', aliases: [], appearance: '', biography: '' });
input.title = 'Synthetic character removal';
input.characters = [person('first-person', 'First'), person('second-person', 'Second')];
input.entries[0].characterId = 'first-person';
input.entries[0].characterLinks = [{ id: 'known-link', characterId: 'first-person', location: 0, length: 5, text: 'First', isConfirmed: true }];
input.entries[1].characterLinks = [];
input.entries[1].characterId = 'second-person';
const [image, excludedImage] = input.images;
const region = { x: 0.1, y: 0.1, width: 0.3, height: 0.3 };
image.characterIds = ['first-person', 'second-person'];
image.characterAnalysis = { imageSHA256: image.sha256, imageVersion: image.version, providerID: 'fixture', completedAt: input.createdAt,
  manualCharacterIDs: ['first-person', 'second-person'], excludedCharacterIDs: [], annotations: [
    { id: 'first-face', characterID: 'first-person', region, portraitRegion: region, kind: 'face', confidence: 1, reason: '', decision: 'confirmed' },
  ] };
excludedImage.characterAnalysis = { imageSHA256: excludedImage.sha256, imageVersion: excludedImage.version, providerID: 'fixture',
  completedAt: input.createdAt, manualCharacterIDs: [], excludedCharacterIDs: ['first-person'], annotations: [] };
const byID = id => node => node.identifier === id;
const menuButton = node => node.label === 'Character actions';
const action = { scope: 'character-delete', action: 'Delete character…', characterID: 'first-person' };
let step = 'load an isolated script with a linked speaker and reviewed image tags';

try {
  const capabilities = await session.command('capabilities');
  assert.equal(capabilities.cloudIsolation.network, 'disabled');
  await ui.tab('Script');
  await session.command('key', { input: 's', modifiers: ['command'] });
  const sample = await waitForSavedProject(session, project => project.title === 'YAM MAN');
  assert.deepEqual(await session.command('import-json', { text: JSON.stringify(input) }), { dispatched: true, projectChanged: true });
  const before = await waitForSavedProject(session, project => project.title === input.title);
  assert.deepEqual(before.entries[0].characterLinks, input.entries[0].characterLinks);
  assert.deepEqual(before.images, input.images);
  await ui.tab('Characters');
  await ui.activate(byID('character-ribbon-first-person'));
  await session.command('end-editing');
  const saved = async () => sortedProjects(await session.command('persisted-projects'));
  const original = await saved();

  step = 'open Delete character from the selected profile and cancel';
  const target = (await ui.reveal(menuButton)).path;
  const menu = await session.command('menu', { target });
  assert.equal(menu.primary[0].children.filter(item => item.title === action.action && !item.disabled).length, 1);
  await assert.rejects(session.command('menu-action', { ...action, target, characterID: 'second-person' }), /outside the supported/);
  async function openDeletion() {
    const path = (await ui.reveal(menuButton)).path;
    assert.deepEqual(await session.command('menu-action', { ...action, target: path }),
      { dispatched: true, coverage: 'semantic-menu-action' });
    await session.waitFor(nodes => nodes.some(byID('character-delete-confirm'))
      && nodes.some(byID('character-delete-cancel')) && nodes.some(node => node.text === 'Delete First?'));
  }
  await openDeletion();
  assert.ok(capabilities.semanticMenuActionScopes.includes(action.scope));
  assert.deepEqual(await saved(), original);
  await ui.activate(byID('character-delete-cancel'));
  await session.waitFor(nodes => nodes.some(node => menuButton(node) && node.hittable));
  assert.deepEqual(await saved(), original);

  step = 'confirm deletion and preserve wording, timing and the review candidate';
  await openDeletion();
  await ui.activate(byID('character-delete-confirm'));
  const after = await waitForSavedProject(session, project => project.id === before.id && project.revision > before.revision);
  assert.equal(after.revision, before.revision + 1);
  const expected = structuredClone(before);
  expected.characters.shift();
  delete expected.entries[0].characterId;
  delete expected.entries[0].characterLinks[0].characterId;
  expected.images[0].characterIds = ['second-person'];
  const analysis = expected.images[0].characterAnalysis;
  analysis.manualCharacterIDs = ['second-person'];
  expected.images[1].characterAnalysis.excludedCharacterIDs = [];
  delete analysis.annotations[0].characterID;
  analysis.annotations[0].decision = 'needsReview';
  assert.deepEqual(stableContent(after), stableContent(expected));
  assert.deepEqual(await saved(), sortedProjects([sample, after]));
  await session.waitFor(nodes => nodes.some(byID('character-ribbon-second-person'))
    && !nodes.some(byID('character-ribbon-first-person')));
  console.log('PASS: Character deletion confirmation, cancellation, unlinking and retained script and image metadata');
} catch (cause) {
  throw new Error(`Native character deletion failed while trying to ${step}`, { cause });
} finally {
  await session.close();
}
