import assert from 'node:assert/strict';
import { ScrivSession } from '../../cli/scriv.mjs';
import { runTransportClockJourney, transportClockCases } from './support/transport-clock-journey.mjs';

assert.ok(process.argv.slice(2).every(arg => arg === '--list-cases'), 'Unknown argument');
if (process.argv.includes('--list-cases')) {
  console.log(JSON.stringify(transportClockCases, null, 2));
  process.exit(0);
}

// Real app acceptance candidates. Keep source/native suites until every original
// invariant is mapped and verified, including layout, keyboard and render cost.
assert.ok(process.env.SCRIV_E2E_APP, 'Set SCRIV_E2E_APP to an automation-enabled Catalyst bundle');
const session = await ScrivSession.launch(process.env.SCRIV_E2E_APP);
const byID = (nodes, id) => nodes.filter(node => node.identifier === id);
const byLabel = (nodes, label) => nodes.filter(node => node.label === label && node.enabled === true && node.hittable);
try {
  let nodes = await session.waitFor(nodes => byID(nodes, 'workspace-tabs').some(node => node.enabled && node.hittable));
  const tabs = byID(nodes, 'workspace-tabs')[0];
  const window = nodes.find(node => node.path === '0');
  assert.equal(window.appearance, 'light');
  assert.ok(Math.abs(tabs.frame.x + tabs.frame.width / 2 - (window.frame.x + window.frame.width / 2)) <= 2, 'Tabs remain centered on the workspace');
  assert.ok(tabs.frame.height >= 46 && tabs.frame.height <= 50, 'Native segment height stays within approved bounds');
  for (let index = 0; index < tabs.segments.length; index++) {
    await session.command('select', { target: 'workspace-tabs', index });
    nodes = await session.waitFor(nodes => byID(nodes, 'workspace-tabs').some(node => node.selected === index));
    assert.equal(byID(nodes, 'workspace-playback-transport').length, 1, 'Exactly one footer transport per tab');
    assert.equal(byID(nodes, 'scene-playback-position').length, 1, 'No duplicate scene seek controls');
    const seek = byID(nodes, 'scene-playback-position')[0];
    assert.ok(seek.enabled && seek.slider.maximum > 0, 'Synthetic scene is playable');
    const midpoint = Math.floor(seek.slider.maximum / 2);
    await session.command('slider', { target: seek.identifier, value: midpoint });
    await session.waitFor(nodes => byID(nodes, seek.identifier).some(node => Math.abs(node.slider.value - midpoint) < 2));
    await assert.rejects(session.command('slider', { target: seek.identifier, value: -1 }), /within its range/);
    await session.command('slider', { target: seek.identifier, value: 0 });
    nodes = await session.command('snapshot');
    const play = byLabel(nodes, 'Play scene');
    assert.equal(play.length, 1);
    await session.command('activate', { target: play[0].path });
    nodes = await session.waitFor(nodes => byLabel(nodes, 'Pause scene').length === 1 && byID(nodes, seek.identifier).some(node => node.slider.value > 50));
    await session.command('activate', { target: byLabel(nodes, 'Pause scene')[0].path });
    nodes = await session.waitFor(nodes => byLabel(nodes, 'Play scene').length === 1);
    const paused = byID(nodes, seek.identifier)[0].slider.value;
    await new Promise(resolve => setTimeout(resolve, 150));
    nodes = await session.command('snapshot');
    assert.ok(Math.abs(byID(nodes, seek.identifier)[0].slider.value - paused) < 2, 'Pause stops the real scene clock');
  }
  await runTransportClockJourney(session);
  console.log('PASS: actual UIKit header geometry, one transport per tab, seek, play, pause, running forward/backward seek, resume and natural end');
} finally { await session.close(); }
