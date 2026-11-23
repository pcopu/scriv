import assert from 'node:assert/strict';
import { ScrivSession } from '../../../cli/scriv.mjs';
import { waitForSavedProject } from '../support/saved-projects.mjs';
import { stableContent } from './support/audio-library-fixtures.mjs';
import { audioLibrarySteps, sortedProjects } from './support/audio-library-steps.mjs';
import { packageFixtureToken, packageImageFixture, validatePackageImageFixture } from './support/package-image-fixture.mjs';

assert.ok(process.env.SCRIV_E2E_APP, 'Requires an isolated Catalyst automation bundle');
validatePackageImageFixture();
const session = await ScrivSession.launch(process.env.SCRIV_E2E_APP);
const ui = audioLibrarySteps(session);
const card = node => node.label === 'Picture actions for Foreground';
const confirmation = id => node => node.identifier === 'picture-removal-' + id;
const action = { scope: 'storyboard-remove-placement', action: 'Remove placement…', cueID: 'foreground' };
const decodedFiles = evidence => evidence.assets.map(({ assetID, sha256, byteCount, width, height, decoded }) =>
  ({ assetID, sha256, byteCount, width, height, decoded }));
let step = 'open a package with two independently verified picture assets';

try {
  const capabilities = await session.command('capabilities');
  assert.equal(capabilities.cloudIsolation.network, 'disabled');
  await ui.tab('Script');
  await session.command('key', { input: 's', modifiers: ['command'] });
  const sample = await waitForSavedProject(session, project => project.title === 'YAM MAN');
  const staged = await session.command('stage-package-fixture', { fixture: packageFixtureToken });
  const before = { ...packageImageFixture(), id: staged.projectID };
  assert.deepEqual((await ui.openProject(before)).project, before);
  await ui.tab('Storyboard');
  await session.command('end-editing');
  const assets = await session.command('local-image-evidence');
  const saved = async () => sortedProjects(await session.command('persisted-projects'));
  const original = await saved();

  step = 'open Remove placement from the exact mounted Storyboard card';
  const target = (await ui.reveal(card)).path;
  const menu = await session.command('menu', { target });
  assert.equal(menu.primary[0].children.filter(item => item.title === action.action && !item.disabled).length, 1);
  await assert.rejects(session.command('menu-action', { ...action, target, cueID: 'background' }), /outside the supported/);
  await assert.rejects(session.command('menu-action', { ...action, target, action: 'Import image…' }), /outside the supported/);
  async function openRemoval() {
    const path = (await ui.reveal(card)).path;
    assert.deepEqual(await session.command('menu-action', { ...action, target: path }),
      { dispatched: true, coverage: 'semantic-menu-action' });
    await session.waitFor(nodes => nodes.some(confirmation('confirm')) && nodes.some(confirmation('cancel'))
      && nodes.some(node => node.text === 'Remove this image placement?'));
  }
  await openRemoval();
  assert.ok(capabilities.semanticMenuActionScopes.includes(action.scope));
  assert.deepEqual(await saved(), original);
  await ui.activate(confirmation('cancel'));
  await session.waitFor(nodes => nodes.some(node => card(node) && node.hittable));
  assert.deepEqual(await saved(), original);

  step = 'confirm removal and preserve the script and both picture files';
  await openRemoval();
  await ui.activate(confirmation('confirm'));
  const after = await waitForSavedProject(session, project => project.id === before.id && project.revision > before.revision);
  assert.equal(after.revision, before.revision + 1);
  assert.deepEqual(stableContent(after), stableContent({ ...before, cues: before.cues.slice(0, 1) }));
  await session.waitFor(nodes => nodes.every(node => !card(node) && !confirmation('confirm')(node)));
  const afterEvidence = await session.command('local-image-evidence');
  assert.equal(afterEvidence.projectID, before.id);
  assert.deepEqual(decodedFiles(afterEvidence), decodedFiles(assets));
  assert.equal(afterEvidence.assets.find(asset => asset.assetID === before.cues[1].imageId).visiblePreviewCount, 0);
  assert.deepEqual(await saved(), sortedProjects([sample, after]));
  console.log('PASS: Storyboard removal confirmation, cancellation and retained script and picture files');
} catch (cause) {
  throw new Error(`Native placement removal failed while trying to ${step}`, { cause });
} finally {
  await session.close();
}
