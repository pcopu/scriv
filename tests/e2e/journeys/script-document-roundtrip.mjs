import assert from 'node:assert/strict';
import { ScrivSession } from '../../../cli/scriv.mjs';
import { runDocumentRoundtrip, documentStepOrder } from './support/script-document-roundtrip-steps.mjs';
import { excluded } from './support/script-document-roundtrip-cases.mjs';

// One real isolated process and coherent document workflow. --list-cases is
// authorship inventory only and never a passing native result.
const args = process.argv.slice(2);
assert.ok(args.length === 0 || args.length === 1 && args[0] === '--list-cases', 'Only --list-cases is supported');
if (args.length) {
  console.log(JSON.stringify({ journey: 'IJ-02', companion: 'AUT-J01', nativeVerified: false,
    status: 'not-run', scenarios: [{ id: 'script-document-roundtrip', steps: documentStepOrder }], excluded }, null, 2));
} else {
  assert.ok(process.env.SCRIV_E2E_APP, 'A matching automation-enabled Catalyst bundle is required; no fallback driver');
  // WITNESS launch begin
  const session = await ScrivSession.launch(process.env.SCRIV_E2E_APP);
  assert.equal(typeof session.root, 'string');
  assert.match(session.root, /ScrivVerification-CLI-[0-9a-f-]{36}$/i);
  // WITNESS launch end
  let result;
  try { result = await runDocumentRoundtrip(session); } finally { await session.close(); }
  // WITNESS close begin
  assert.equal(result.status, 'passed');
  assert.deepEqual(result.phases, documentStepOrder);
  // WITNESS close end
  console.log(JSON.stringify({ journey: 'IJ-02', scenario: 'script-document-roundtrip', ...result,
    inputRoute: 'ScrivSession public semantic import/export and mounted UIKit controls', excluded }));
}
