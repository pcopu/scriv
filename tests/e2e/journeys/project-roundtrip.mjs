import assert from 'node:assert/strict';
import { roundtripCases } from './support/project-roundtrip-cases.mjs';
import { runProjectRoundtripCase } from './support/project-roundtrip-steps.mjs';

const args = process.argv.slice(2);
assert.ok(args.every(arg => arg === '--list-cases'), 'Unknown argument');
if (args.includes('--list-cases')) {
  console.log(JSON.stringify({ journey: 'IJ-02', portion: 'loaded-project-roundtrip', nativeVerified: false,
    cases: roundtripCases.map(({ key, id, assertionLines }) => ({ key, id, assertionLines,
      observation: 'actual loaded Swift model before save and after browser switch-away/reopen',
      isolation: 'fresh-app-per-roundtrip' })),
  }, null, 2));
} else {
  assert.ok(process.env.SCRIV_E2E_APP, 'Set SCRIV_E2E_APP to a verified automation-enabled Catalyst bundle');
  const roots = new Set();
  for (const test of roundtripCases) await runProjectRoundtripCase(process.env.SCRIV_E2E_APP, test, roots);
  assert.equal(roots.size, roundtripCases.length);
}
