import assert from 'node:assert/strict';
import { ScrivSession } from '../../../cli/scriv.mjs';
import { historyReviewManifest, runHistoryReview, runHistoryChangeCards } from './support/project-history-steps.mjs';

const args = process.argv.slice(2);
const cases = { 'review-and-restore': runHistoryReview, 'change-cards': runHistoryChangeCards };
const list = args.length === 1 && args[0] === '--list-cases';
assert.ok(!args.length || list || args.length === 2 && args[0] === '--group' && Object.hasOwn(cases, args[1]), 'Choose one listed group');
if (list) {
  const path = 'apps/catalyst/ScrivUIKit/Projects/HistoryController.swift';
  console.log(JSON.stringify({ ...historyReviewManifest, groups: Object.keys(cases), defaultGroups: ['review-and-restore'],
    groupActions: { 'change-cards': [
      { id: 'history-expand-changes', command: 'activate', trigger: 'Show more changes', condition: 'revision-has-more-than-eight-changes',
        entryPoint: { path, start: 173, end: 173, sha256: 'faf3cadb2a1f55f63850b3c6c5f247d6cfe428d127c6d7f4b19d626392a51198' },
        branch: { path, start: 174, end: 175, sha256: 'ecf17c61e3580c1d26d84cec7039f6c1f54c5dbf515de8a81dd87ef332380807' } },
      { id: 'history-open-current-change', command: 'activate', trigger: 'Current revision', condition: 'changed-script-retains-its-attached-image',
        entryPoint: { path, start: 301, end: 301, sha256: '04387fddcea4967836834f9b3e3086d8d39d49acb2c79adb38e79d66af56b4a2' },
        branch: { path, start: 228, end: 231, sha256: 'aff591f5f7ecdf4d9d18900263a5783658e79e33637156c72110e85519e731ed' } },
    ] },
  }, null, 2));
} else {
  assert.ok(process.env.SCRIV_E2E_APP, 'Set SCRIV_E2E_APP to a verified automation-enabled Catalyst bundle');
  const session = await ScrivSession.launch(process.env.SCRIV_E2E_APP);
  try { await cases[args[1] ?? 'review-and-restore'](session); }
  finally { await session.close(); }
}
