import assert from 'node:assert/strict';
import { modelCases, anchoredFixture, sampleFixture, serialized, authoredPayload } from './support/json-model-cases.mjs';
import { characterCases, frozenID, expectedError, model, sourceFields, stableFields, rawJSON } from './support/json-character-cases.mjs';
import { additionalTests } from './support/json-additional-cases.mjs';
import { projectValidationExtensionTests } from './support/json-project-validation-extension.mjs';
import { validationAcceptanceTests } from './support/json-validation-acceptance-cases.mjs';
import { runJSONValidationCase } from './support/json-validation-steps.mjs';

// IJ-02 JSON validation portion. One table and shared real-app steps, not a
// subprocess wrapper around the old slices. Fountain's verified portion is
// unchanged. Invalid-alert cases MUST remain isolated until real dismissal is
// supported. Public-controller state is not pixel or physical-input evidence.
const modelTests = modelCases.map((fixture, index) => ({
  group: 'model', key: `model/${index + 1}`, id: fixture.id, name: fixture.name,
  error: fixture.error,
  makePositive: sample => fixture.fixture === 'sample' ? sampleFixture(sample) : anchoredFixture(),
  serializePositive: serialized,
  verifyPositive(accepted, positive) {
    assert.equal(accepted.revision, 0);
    assert.ok(!accepted.cloudProjectId);
    assert.deepEqual(authoredPayload(accepted), authoredPayload(positive), 'Real decoding and save preserve every fixture payload field');
  },
  acceptedVisible: (nodes, accepted) => nodes.some(node => node.identifier === 'workspace-project'
    && node.title === accepted.title && node.label === accepted.title + ', Projects' && node.hittable),
  invalidate: fixture.mutate,
  verifyInvalid: (invalid, positive) => assert.notDeepEqual(invalid, positive, 'Exact frozen invalid mutation is present in document input'),
  serializeInvalid: serialized,
}));
const characterTests = characterCases.map((fixture, index) => ({
  group: 'character-links', key: `character-links/${index + 1}`, id: frozenID, name: fixture.name,
  error: expectedError,
  makePositive() {
    const positive = model(fixture.name, fixture.text, fixture.annotation);
    assert.deepEqual(sourceFields(positive), { text: fixture.text, characterIDs: ['randy'], links: [fixture.annotation] });
    return positive;
  },
  serializePositive: JSON.stringify,
  verifyPositive(accepted, positive) {
    assert.equal(accepted.cloudProjectId, undefined, 'Imported fixture remains local');
    assert.ok(Number.isFinite(accepted.createdAt) && accepted.createdAt > 0);
    assert.equal(accepted.modifiedAt, accepted.createdAt);
    assert.deepEqual(stableFields(accepted), stableFields(positive), 'Every saved field other than import-reset metadata is preserved');
  },
  acceptedVisible: (nodes, accepted, positive) => nodes.some(node => node.identifier === 'workspace-project' && node.title === positive.title)
    && nodes.some(node => node.identifier === 'script-line-line' && node.text === fixture.text)
    && nodes.some(node => node.identifier === 'workspace-tabs' && node.enabled && node.hittable),
  invalidate: fixture.invalidate,
  verifyInvalid: invalid => assert.deepEqual(sourceFields(invalid), fixture.expected, `${fixture.name}: exact frozen invalid input`),
  serializeInvalid: invalid => rawJSON(invalid, fixture),
}));

// Portable authorship checks retain the old model slice's explicit check mode.
// No decoder/validator is simulated and no production pass is inferred.
assert.equal(modelCases.length, 8);
assert.deepEqual([...new Set(modelCases.map(test => test.id))], [
  'apps/mac/Tests/ScrivCoreTests/TimingTests.swift::0010',
  'apps/mac/Tests/ScrivCoreTests/CueAnchoringTests.swift::0006',
  'apps/mac/Tests/ScrivCoreTests/CueAnchoringTests.swift::0013',
]);
const anchor = anchoredFixture();
assert.deepEqual(JSON.parse(serialized(anchor)), anchor);
for (const test of modelCases.filter(test => test.fixture !== 'sample')) {
  const invalid = anchoredFixture(); test.mutate(invalid);
  assert.notDeepEqual(invalid, anchor);
  assert.deepEqual(JSON.parse(serialized(invalid)), invalid);
}
// Check each exact character input and lossless raw Int.max assembly even in
// --list-cases mode; never parse the raw Int.max back through a JS Number.
for (const test of characterTests) {
  const positive = test.makePositive();
  const invalid = structuredClone(positive); test.invalidate(invalid);
  test.verifyInvalid(invalid);
  test.serializeInvalid(invalid);
}

const args = process.argv.slice(2);
const groups = ['model', 'character-links', 'additional', 'project-validation-extension', 'compatibility'];
let selectedGroups = groups;
if (args.includes('--group')) {
  const group = args[args.indexOf('--group') + 1];
  assert.ok(groups.includes(group), '--group must identify a listed validation group');
  selectedGroups = [group];
}
assert.ok(args.every((arg, index) => arg === '--list-cases' || arg === '--group'
  || (args[index - 1] === '--group' && groups.includes(arg))), 'Unknown argument');
const selected = [...modelTests, ...characterTests, ...additionalTests, ...projectValidationExtensionTests, ...validationAcceptanceTests].filter(test => selectedGroups.includes(test.group));
assert.equal(new Set(selected.map(test => test.key)).size, selected.length);
if (args.includes('--list-cases')) {
  console.log(JSON.stringify({ journey: 'IJ-02', portion: 'json-validation', nativeVerified: false,
    observation: 'public-controller-presentation-state',
    loadedStateOracle: 'complete-project-and-date-reference-bits',
    cases: selected.map(({ group, key, id, name, error, acceptanceOnly, assertionLines,
      successfulValidationLines, contextualAssertionLines, coverage, retirementAllowed, inputBytes }) => ({
      group, key, id, name, error, assertionLines, successfulValidationLines, contextualAssertionLines,
      coverage, retirementAllowed, inputBytes, acceptanceOnly: !!acceptanceOnly,
      isolation: acceptanceOnly ? 'fresh-app-per-accepted-document' : 'fresh-app-per-invalid-document',
    })),
  }, null, 2));
} else {
  assert.ok(process.env.SCRIV_E2E_APP, 'Set SCRIV_E2E_APP to a verified automation-enabled Catalyst bundle');
  const roots = new Set();
  for (const test of selected) await runJSONValidationCase(process.env.SCRIV_E2E_APP, test, roots);
  assert.equal(roots.size, selected.length, 'Every selected document case used a unique isolated app run');
  console.log(`PASS: IJ-02 JSON validation, ${selected.length} isolated cases; no pixel, picker, native bridge or alert-dismissal coverage`);
}
