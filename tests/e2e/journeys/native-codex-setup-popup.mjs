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
  await selectSettingsPane('general');
  await selectSettingsPane('codex');
  await session.waitFor(nodes => nodes.some(byID('codex-settings')) && idle(nodes));
  assert.deepEqual(await session.command('persisted-projects'), saved);
  assert.deepEqual(await session.command('loaded-project'), loaded);
  await followPlaybackInGeneralSettings();
  assert.deepEqual(await session.command('persisted-projects'), saved);
  assert.deepEqual(await session.command('loaded-project'), loaded);
  console.log('PASS: Codex Settings handoff and General playback preference preserve the active project');
} finally {
  await session.close();
}

async function selectSettingsPane(name) {
  const hittable = node => node.identifier === `scriv.settings.${name}` && node.hittable;
  const nodes = await session.waitFor(nodes => nodes.filter(hittable).length === 1);
  await session.command('activate', { target: nodes.find(hittable).path });
}

async function followPlaybackInGeneralSettings() {
  const followSwitch = async value => {
    const shown = node => node.text === 'Follow active line during playback';
    const nodes = await session.waitFor(nodes => nodes.some(shown));
    const label = nodes.find(shown);
    const row = label.path.slice(0, label.path.lastIndexOf('.'));
    const switches = nodes.filter(node => node.path.startsWith(`${row}.`) && typeof node.isOn === 'boolean');
    assert.equal(switches.length, 1);
    assert.ok(switches[0].enabled && switches[0].hittable);
    assert.equal(switches[0].isOn, value);
    return switches[0].path;
  };
  await selectSettingsPane('general');
  await session.command('toggle', { target: await followSwitch(true), value: false });
  await followSwitch(false);
  await selectSettingsPane('codex');
  await session.waitFor(nodes => nodes.some(byID('codex-settings')) && idle(nodes));
  await selectSettingsPane('general');
  await session.command('toggle', { target: await followSwitch(false), value: true });
  await followSwitch(true);
  await selectSettingsPane('codex');
  await session.waitFor(nodes => nodes.some(byID('codex-settings')) && idle(nodes));
}
