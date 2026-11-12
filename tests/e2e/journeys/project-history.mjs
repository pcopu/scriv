import assert from 'node:assert/strict';
import { ScrivSession } from '../../../cli/scriv.mjs';
import { historyReviewManifest, runHistoryReview } from './support/project-history-steps.mjs';

const args = process.argv.slice(2);
assert.ok(args.every(arg => arg === '--list-cases'), 'Unknown argument');
if (args.includes('--list-cases')) {
  console.log(JSON.stringify(historyReviewManifest, null, 2));
} else {
  assert.ok(process.env.SCRIV_E2E_APP, 'Set SCRIV_E2E_APP to a verified automation-enabled Catalyst bundle');
  const session = await ScrivSession.launch(process.env.SCRIV_E2E_APP);
  try { await runHistoryReview(session); }
  finally { await session.close(); }
}
