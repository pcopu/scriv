import assert from 'node:assert/strict';
import { ScrivSession } from '../../cli/scriv.mjs';

// This is a first actual-app smoke scenario, not replacement coverage for the
// legacy suite. Missing native builds are a failure, never a passing skip.
const app = process.env.SCRIV_E2E_APP;
assert.ok(app, 'Set SCRIV_E2E_APP to an automation-enabled Catalyst bundle');
const session = await ScrivSession.launch(app);
try {
  const capabilities = await session.command('capabilities');
  assert.equal(capabilities.driver, 'UIKit controls');
  const initial = await session.waitFor(nodes => nodes.some(node => node.identifier === 'workspace-tabs' && node.enabled && node.hittable));
  const tabs = initial.find(node => node.identifier === 'workspace-tabs');
  assert.ok(tabs.segments.length >= 3);
  for (let index = 0; index < tabs.segments.length; index++) {
    await session.command('select', { target: 'workspace-tabs', index });
    await session.waitFor(nodes => nodes.some(node => node.identifier === 'workspace-tabs' && node.selected === index));
  }
  await assert.rejects(session.command('activate', { target: 'does-not-exist' }), /exactly one/);
  await assert.rejects(session.command('select', { target: 'workspace-tabs', index: -1 }), /Invalid segment/);
  console.log('PASS: actual UIKit tab navigation and invalid-target rejection');
} finally { await session.close(); }
