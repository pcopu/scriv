import assert from 'node:assert/strict';
import { ScrivSession } from '../../../cli/scriv.mjs';
import { waitForSavedProject } from '../support/saved-projects.mjs';

const app = process.env.SCRIV_E2E_APP;
assert.ok(app, 'Set SCRIV_E2E_APP to a Catalyst automation build without a release update key');
const session = await ScrivSession.launch(app, { freshStartup: true });
const workspace = nodes => nodes.some(node => node.identifier === 'workspace-tabs' && node.hittable && node.enabled);
const primary = nodes => nodes.filter(node => node.identifier === 'scriv.update.primary' && node.hittable && node.enabled);
const blocked = nodes => primary(nodes).length === 1 && primary(nodes)[0].title === 'Done'
  && nodes.some(node => node.text === 'Updates are on their way.')
  && nodes.some(node => node.text === 'In-app updates are built in, but release signing is not configured yet. You can keep using Scriv. Nothing will be downloaded or installed.');
const saved = async () => (await session.command('persisted-projects')).sort((a, b) => a.id.localeCompare(b.id));

try {
  await session.waitFor(workspace);
  const project = await waitForSavedProject(session, saved => saved.title === 'YAM MAN' && saved.images.length === 3);
  const before = await saved();
  assert.deepEqual(before, [project]);
  const loaded = await session.command('loaded-project');
  assert.deepEqual(loaded.project, project);
  assert.deepEqual(await session.command('check-for-updates'), { dispatched: true });
  const initial = await session.waitFor(blocked);
  const capabilities = await session.command('capabilities');
  assert.ok(capabilities.semanticApplicationCommands.includes('check-for-updates'));
  assert.ok(capabilities.commands.includes('check-for-updates'));

  await assert.rejects(session.command('check-for-updates', { feed: 'unused' }), /The isolated update check is unavailable/);
  assert.deepEqual(await session.command('check-for-updates'), { dispatched: true });
  const repeated = await session.waitFor(blocked);
  assert.equal(primary(repeated)[0].path, primary(initial)[0].path, 'A repeated check keeps the existing sheet');
  assert.ok(!repeated.some(node => node.identifier === 'scriv.update.secondary' && node.enabled && node.hittable));
  await session.command('activate', { target: primary(repeated)[0].path });
  await session.waitFor(nodes => workspace(nodes) && !nodes.some(node => node.identifier === 'scriv.update.primary'));
  assert.deepEqual(await saved(), before);
  assert.deepEqual(await session.command('loaded-project'), loaded);

  assert.deepEqual(await session.command('check-for-updates'), { dispatched: true });
  const reopened = await session.waitFor(blocked);
  await session.command('activate', { target: primary(reopened)[0].path });
  await session.waitFor(nodes => workspace(nodes) && !nodes.some(node => node.identifier === 'scriv.update.primary'));
  assert.deepEqual(await saved(), before);
  assert.deepEqual(await session.command('loaded-project'), loaded);
  console.log('PASS: Scriv update menu checks signing, focuses one blocked sheet, and closes without touching saved projects');
} finally {
  await session.close();
}
