import assert from 'node:assert/strict';
import { ScrivSession } from '../../../cli/scriv.mjs';
import { waitForSavedProject } from '../support/saved-projects.mjs';
import { audioLibrarySteps } from './support/audio-library-steps.mjs';

const app = process.env.SCRIV_E2E_APP;
assert.ok(app, 'Requires an isolated Catalyst automation bundle');
const session = await ScrivSession.launch(app, { freshStartup: true });
const ui = audioLibrarySteps(session);
const byID = id => node => node.identifier === id;
const idle = nodes => nodes.some(node => node.identifier === 'codex-connection-status' && node.text === 'Not connected')
  && nodes.every(node => !['codex-account-status', 'codex-cancel-check', 'codex-model'].includes(node.identifier));
const popup = nodes => nodes.some(node => node.identifier === 'codex-done' && node.hittable && node.enabled) && idle(nodes);

async function openPopup() {
  const menuButton = await ui.reveal(node => node.label === 'Workspace actions');
  const menu = await session.command('menu', { target: menuButton.path });
  assert.ok(menu.primary[0].children.some(group => group.children?.some(action => action.title === 'Codex…' && !action.disabled)));
  assert.deepEqual(await session.command('menu-action', {
    target: menuButton.path, scope: 'workspace-panels', action: 'Codex…',
  }), { dispatched: true, coverage: 'semantic-menu-action' });
  await session.waitFor(popup);
}

try {
  const caps = await session.command('capabilities');
  assert.equal(caps.cloudIsolation.network, 'disabled');
  const project = await waitForSavedProject(session, saved => saved.title === 'YAM MAN' && saved.images.length === 3);
  const saved = [project];
  const loaded = await session.command('loaded-project');
  assert.deepEqual(loaded.project, project);
  await openPopup();
  await ui.activate(byID('codex-done'));
  await session.waitFor(nodes => !nodes.some(byID('codex-done'))
    && nodes.some(node => node.identifier === 'workspace-tabs' && node.hittable && node.enabled));
  assert.deepEqual(await session.command('loaded-project'), loaded);

  await openPopup();
  await ui.activate(byID('codex-advanced'));
  await session.waitFor(nodes => !nodes.some(byID('codex-done')) && nodes.some(byID('codex-settings')) && idle(nodes));
  for (const pane of ['scriv.settings.general', 'scriv.settings.codex']) {
    const hittable = node => node.identifier === pane && node.hittable;
    const nodes = await session.waitFor(nodes => nodes.filter(hittable).length === 1);
    await session.command('activate', { target: nodes.find(hittable).path });
  }
  await session.waitFor(nodes => nodes.some(byID('codex-settings')) && idle(nodes));
  assert.deepEqual(await session.command('persisted-projects'), saved);
  assert.deepEqual(await session.command('loaded-project'), loaded);
  console.log('PASS: the workspace Codex popup closes or hands off to disconnected Codex Settings');
} finally {
  await session.close();
}
