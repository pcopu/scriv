import assert from 'node:assert/strict';
import { additionalTests } from './json-additional-cases.mjs';

// Reuse reconciled frozen source payloads, not their weaker saved-file oracle.
// The imported project becomes the baseline ONLY after import resets identity.
export const roundtripCases = additionalTests.filter(test => ['additional/3', 'additional/4'].includes(test.key))
  .map((test, index) => ({ ...test, key: `loaded/${index + 1}` }));
assert.deepEqual(roundtripCases.map(test => test.assertionLines), [[89], [44]]);
for (const test of roundtripCases) {
  const input = test.makePositive();
  assert.deepEqual(JSON.parse(test.serializePositive(input)), input);
  assert.equal(input.cloudProjectId, undefined, 'No cloud or account operations');
  assert.deepEqual(input.images, [], 'No image bytes or external assets');
}
