import assert from 'node:assert/strict';
import { ScrivSession } from '../../cli/scriv.mjs';
assert.ok(process.env.SCRIV_E2E_APP, 'Set SCRIV_E2E_APP to an automation-enabled Catalyst bundle');
const session = await ScrivSession.launch(process.env.SCRIV_E2E_APP);
const buttons = (nodes, title) => nodes.filter(node => node.enabled && node.hittable && (node.title === title || node.label === title));
async function click(title) {
  const nodes = await session.waitFor(nodes => buttons(nodes, title).length === 1);
  await session.command('activate', { target: buttons(nodes, title)[0].path });
}
try {
  await session.waitFor(nodes => nodes.some(node => node.identifier === 'workspace-project' && node.enabled && node.hittable));
  for (let repeat = 0; repeat < 2; repeat++) {
    await session.command('activate', { target: 'workspace-project' });
    let nodes = await session.waitFor(nodes => nodes.some(node => node.placeholder === 'Find a project'));
    const search = nodes.find(node => node.placeholder === 'Find a project');
    await session.command('text', { target: search.path, text: 'no-such-synthetic-project-7c891' });
    await session.waitFor(nodes => nodes.some(node => node.text === 'No matching projects'));
    // The CLI must respect modal routing rather than activating covered controls.
    await assert.rejects(session.command('select', { target: 'workspace-tabs', index: 1 }), /active presentation|disabled|exactly one/);
    await click('Clear search');
    await session.waitFor(nodes => nodes.some(node => node.placeholder === 'Find a project' && node.text === ''));
    await click('Close Projects');
    await session.waitFor(nodes => nodes.some(node => node.identifier === 'workspace-project' && node.enabled && node.hittable) && !nodes.some(node => node.placeholder === 'Find a project'));
  }
  console.log('PASS: actual project browser search, clear, close/reopen, and modal routing');
} finally { await session.close(); }
