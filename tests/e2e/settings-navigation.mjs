import assert from 'node:assert/strict';
import { ScrivSession } from '../../cli/scriv.mjs';
assert.ok(process.env.SCRIV_E2E_APP, 'Set SCRIV_E2E_APP to an automation-enabled Catalyst bundle');
const session = await ScrivSession.launch(process.env.SCRIV_E2E_APP);
async function choose(id) {
  const nodes = await session.waitFor(nodes => nodes.filter(node => node.identifier === id && node.hittable).length === 1);
  await session.command('activate', { target: nodes.find(node => node.identifier === id && node.hittable).path });
}
async function switchNode() {
  const matches = nodes => {
    const pane = nodes.find(node => node.identifier === 'scriv.settings.general' && node.hittable);
    return nodes.filter(node => pane && node.windowPath === pane.windowPath && node.type === 'UISwitch' && node.hittable && node.enabled);
  };
  const nodes = await session.waitFor(nodes => matches(nodes).length === 1);
  return matches(nodes)[0];
}
try {
  await session.waitFor(nodes => nodes.some(node => node.identifier === 'workspace-tabs' && node.enabled && node.hittable));
  await session.command('key', { input: ',', modifiers: ['command'] });
  await choose('scriv.settings.general');
  let follow = await switchNode();
  const original = follow.isOn;
  await session.command('toggle', { target: follow.path, value: !original });
  await session.waitFor(nodes => nodes.some(node => node.type === 'UISwitch' && node.windowPath === follow.windowPath && node.isOn === !original));
  for (let repeat = 0; repeat < 2; repeat++) {
    await choose('scriv.settings.codex');
    const nodes = await session.waitFor(nodes => nodes.some(node => node.identifier === 'codex-settings')
      && nodes.some(node => node.identifier === 'codex-connection-status'));
    const status = nodes.find(node => node.identifier === 'codex-connection-status');
    assert.equal(status.text?.startsWith('Connected'), false, 'Opening Codex settings must not connect or sign in');
    // No Connect/Start/Sign in/Sign out action is taken in this UI-only scenario.
    await choose('scriv.settings.account');
    await session.waitFor(nodes => nodes.some(node => node.text === 'Write locally, or sign in'));
    await choose('scriv.settings.general');
    follow = await switchNode();
    assert.equal(follow.isOn, !original, 'Follow playback preference survives pane changes');
    await session.command('key', { input: ',', modifiers: ['command'] });
    await switchNode();
  }
  await session.command('toggle', { target: follow.path, value: original });
  assert.equal((await switchNode()).isOn, original);
  console.log('PASS: actual separate Settings scene, menu shortcut, pane navigation and isolated preference toggle without connection');
} finally { await session.close(); }
