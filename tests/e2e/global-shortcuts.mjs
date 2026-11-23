import assert from 'node:assert/strict';
import { ScrivSession } from '../../cli/scriv.mjs';
assert.ok(process.env.SCRIV_E2E_APP, 'Set SCRIV_E2E_APP to an automation-enabled Catalyst bundle');
const session = await ScrivSession.launch(process.env.SCRIV_E2E_APP);
const key = (input, modifiers = []) => session.command('key', { input, modifiers });
const control = (nodes, name) => nodes.filter(node => node.label === name && node.enabled && node.hittable);
try {
  await session.waitFor(nodes => nodes.some(node => node.identifier === 'workspace-tabs' && node.enabled && node.hittable));
  for (let repeat = 0; repeat < 2; repeat++) {
    await key('f', ['command']);
    await session.waitFor(nodes => nodes.some(node => node.placeholder === 'Find in script' && node.firstResponder));
    const commands = await session.command('keys');
    assert.equal(commands.some(command => command.responderType === 'ScrivUIKitApplication' && command.input === ' '), false,
      'Global playback shortcut is not offered while typing');
    await key('Escape');
    await session.waitFor(nodes => !nodes.some(node => node.placeholder === 'Find in script'));
  }
  for (let repeat = 0; repeat < 3; repeat++) {
    await session.command('slider', { target: 'scene-playback-position', value: 0 });
    await key(' ');
    await session.waitFor(nodes => control(nodes, 'Pause scene').length === 1 && nodes.some(node => node.identifier === 'scene-playback-position' && node.slider.value > 50));
    await key(' ');
    const nodes = await session.waitFor(nodes => control(nodes, 'Play scene').length === 1);
    const paused = nodes.find(node => node.identifier === 'scene-playback-position').slider.value;
    await new Promise(resolve => setTimeout(resolve, 100));
    assert.ok(Math.abs((await session.command('snapshot')).find(node => node.identifier === 'scene-playback-position').slider.value - paused) < 2);
    // Pausing intentionally restores the script caret. Space now belongs to
    // typing, so finish that native editor before the next playback stroke.
    await session.waitFor(nodes => nodes.some(node => node.identifier.startsWith('script-editor-') && node.firstResponder));
    assert.equal((await session.command('keys')).some(command => command.responderType === 'ScrivUIKitApplication' && command.input === ' '), false);
    await key('Escape');
    await session.waitFor(nodes => !nodes.some(node => node.identifier.startsWith('script-editor-') && node.firstResponder));
  }
  async function assertPlaybackLabel(label) {
    const snapshot = await session.waitFor(nodes => control(nodes, label).length === 1);
    const [button] = control(snapshot, label);
    const items = await session.command('accessibility-snapshot');
    assert.ok(items.length > 0 && items.length <= 1024);
    assert.equal(new Set(items.map(item => item.path)).size, items.length);
    const descriptions = items.filter(item => item.path === button.path);
    assert.deepEqual(descriptions.map(({ type, label }) => ({ type, label })), [{ type: button.type, label }]);
  }
  await assertPlaybackLabel('Play scene');
  await key(' ');
  await assertPlaybackLabel('Pause scene');
  await key(' ');
  await session.waitFor(nodes => control(nodes, 'Play scene').length === 1);
  console.log('PASS: global synthetic strokes use native policy/gate, open Find unfocused, respect text focus, and repeatedly play/pause');
} finally { await session.close(); }
