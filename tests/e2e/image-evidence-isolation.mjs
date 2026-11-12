import assert from 'node:assert/strict';
import { ScrivSession } from '../../cli/scriv.mjs';

// Tests the synthetic observer boundary, NOT image generation. No connection,
// authentication, provider request, artifact import or turn is initiated.
assert.ok(process.env.SCRIV_E2E_APP, 'Set SCRIV_E2E_APP to an automation-enabled Catalyst bundle');
const session = await ScrivSession.launch(process.env.SCRIV_E2E_APP);
try {
  const capabilities = await session.command('capabilities');
  assert.ok(capabilities.commands.includes('image-evidence'), 'Requires the newly compiled image observer');
  assert.equal(capabilities.imageEvidenceSchemaVersion, 1);
  await session.waitFor(nodes => nodes.some(node => node.identifier === 'workspace-tabs' && node.enabled && node.hittable));
  for (let repeat = 0; repeat < 2; repeat++) {
    const evidence = await session.command('image-evidence');
    assert.deepEqual(Object.keys(evidence).sort(), ['jobs', 'runID', 'schemaVersion']);
    assert.equal(evidence.schemaVersion, 1);
    assert.equal(evidence.runID, capabilities.runID);
    assert.deepEqual(evidence.jobs, [], 'Fresh isolated session has no generation jobs');
    // Unknown fields are rejected before any path or job can be selected.
    await assert.rejects(session.command('image-evidence', { path: '/not-an-input' }), /accepts no parameters/);
    await assert.rejects(session.command('image-evidence', { jobID: 'not-an-input' }), /accepts no parameters/);
  }
  console.log('PASS: isolated empty image evidence and parameter rejection; zero provider turns');
} finally { await session.close(); }
