import assert from 'node:assert/strict';
import { acceptedDocuments, rejectedDocuments, checkInputs } from './support/model-document-cases.mjs';
import { runModelDocument } from './support/model-document-steps.mjs';
checkInputs();
const args = process.argv.slice(2);
assert.ok(args.length === 0 || args.length === 1 && args[0] === '--list-cases', 'Only --list-cases is supported');
const tests = [...acceptedDocuments, ...rejectedDocuments];
if (args.length) {
  console.log(JSON.stringify({ journey: 'IJ-02', status: 'prepared-not-run', nativeVerified: false,
    cases: tests.map(test => ({ key: test.key, route: test.mutate ? 'accepted-counterpart-then-reject' : 'import-save-browser-reopen',
      error: test.mutate ? test.error ?? 'nonempty-stable-public-decoder-error; localized wording not fixed' : undefined,
      inputBytes: Buffer.byteLength(JSON.stringify(test.make())) })) }, null, 2));
} else {
  assert.ok(process.env.SCRIV_E2E_APP, 'A matching automation-enabled Catalyst bundle is required; no fallback');
  const roots = new Set();
  for (const test of tests) await runModelDocument(test, roots);
  assert.equal(roots.size, tests.length);
}
