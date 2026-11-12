import assert from 'node:assert/strict';
import { anchoredFixture, authoredPayload, serialized } from './json-model-cases.mjs';

// Input data only. These are three previously absent accepted states in IJ-02,
// not new executables, copies of Swift validators, or replayed edit operations.
// Frozen source reconciliation and remaining method gaps are in the sibling
// json-validation-oracle-reconciliation.md. None authorizes legacy retirement.
const prefix = 'apps/mac/Tests/ScrivCoreTests/';
const cueID = prefix + 'CueAnchoringTests.swift::0012';
const characterID = prefix + 'CharacterMentionTests.swift::0014';

function dormantCueFixture() {
  const project = anchoredFixture();
  // Frozen state at CueAnchoringTests line 131, AFTER anchoring/reordering.
  // Only note's order changes on move; the stored entry array stays [a,b,c,d,note].
  project.entries.push({ id: 'note', sceneId: 's', order: 4, kind: 'direction',
    text: 'Keep watching', ownedDurationMs: 0, coverageDurationMs: 1500,
    color: 'purple', words: [] });
  project.cues[1] = { id: 'child', sceneId: 's', label: 'Child', startMs: 4000,
    endMs: 4000, prompt: '', startAnchor: { entryId: 'note', offsetMs: 0 },
    authoredDurationMs: 1500 };
  return project;
}

function characterFixture(withAnnotations) {
  // Frozen CharacterMentionTests entry()/randy defaults. These literal word
  // endpoints come from the frozen source fixture, never the running app.
  const project = {
    schemaVersion: 1, id: 'synthetic-character-compatibility', title: 'Untitled',
    createdAt: 1700000000000, modifiedAt: 1700000000000, revision: 0,
    scenes: [{ id: 'scene', title: 'Untitled scene', order: 0 }],
    entries: [{ id: 'line', sceneId: 'scene', order: 0, kind: 'dialogue',
      text: 'Randy waits.', ownedDurationMs: 3000, coverageDurationMs: 0,
      color: 'purple', words: [
        { id: 'word-one', text: 'Randy', startMs: 0, endMs: 1363 },
        { id: 'word-two', text: 'waits.', startMs: 1363, endMs: 3000 },
      ] }],
    characters: [{ id: 'randy', name: 'Randy', aliases: ['Rand'], biography: '', appearance: '', color: 'blue' }],
    images: [], cues: [], audioAssets: [], audioClips: [], audioVolume: 1,
  };
  if (withAnnotations) {
    project.entries[0].characterLinks = [
      { id: 'confirmed-link', characterId: 'randy', location: 0, length: 5, text: 'Randy', isConfirmed: true },
      // Codable nil is omitted, not a string, a null annotation, or an empty list.
      { id: 'explicit-unlink', location: 6, length: 5, text: 'waits', isConfirmed: true },
    ];
  }
  return project;
}

const definitions = [
  { key: 'compatibility/dormant-cue', id: cueID,
    name: 'zero-owned terminal source retains a dormant anchored cue',
    assertionLines: [], successfulValidationLines: [131], contextualAssertionLines: [128, 129],
    coverage: 'Exact already-authored state reaches the frozen successful validator call; no anchor, reorder, activeCue or later insert operation is executed',
    makePositive: dormantCueFixture,
    verify(accepted) {
      assert.deepEqual(accepted.cues[1], { id: 'child', sceneId: 's', label: 'Child',
        startMs: 4000, endMs: 4000, prompt: '', startAnchor: { entryId: 'note', offsetMs: 0 }, authoredDurationMs: 1500 });
      assert.deepEqual(accepted.entries.map(entry => [entry.id, entry.order, entry.ownedDurationMs]),
        [['a', 0, 1000], ['b', 1, 1000], ['c', 2, 1000], ['d', 3, 1000], ['note', 4, 0]]);
      assert.equal(accepted.entries[4].coverageDurationMs, 1500);
    } },
  { key: 'compatibility/legacy-links', id: characterID,
    name: 'legacy character links remain absent after document decoding',
    assertionLines: [147], successfulValidationLines: [], contextualAssertionLines: [],
    coverage: 'Exact legacy entry decodes with characterLinks absent inside an added valid project container',
    makePositive: () => characterFixture(false),
    verify(accepted) {
      assert.equal(Object.hasOwn(accepted.entries[0], 'characterLinks'), false,
        'Missing legacy links must remain nil, not bootstrap into proposals or an empty array');
      assert.equal(accepted.entries[0].text, 'Randy waits.');
    } },
  { key: 'compatibility/confirmed-unlink', id: characterID,
    name: 'confirmed character and explicit unlink retain exact source ranges',
    assertionLines: [], successfulValidationLines: [], contextualAssertionLines: [152],
    coverage: 'Exact local-roundtrip authored payload reaches import and save; import-reset envelope prevents whole-project roundtrip credit; cloud application is not executed',
    makePositive: () => characterFixture(true),
    verify(accepted) {
      assert.deepEqual(accepted.entries[0].characterLinks, [
        { id: 'confirmed-link', characterId: 'randy', location: 0, length: 5, text: 'Randy', isConfirmed: true },
        { id: 'explicit-unlink', location: 6, length: 5, text: 'waits', isConfirmed: true },
      ]);
      assert.equal(Object.hasOwn(accepted.entries[0].characterLinks[1], 'characterId'), false);
      assert.equal(accepted.entries[0].text, 'Randy waits.');
    } },
];

export const validationAcceptanceTests = definitions.map(fixture => ({
  ...fixture, group: 'compatibility', acceptanceOnly: true, retirementAllowed: false,
  serializePositive: serialized,
  verifyPositive(accepted, positive) {
    assert.equal(accepted.revision, 0);
    assert.equal(Object.hasOwn(accepted, 'cloudProjectId'), false);
    assert.ok(Number.isFinite(accepted.createdAt) && accepted.createdAt > 0);
    assert.equal(accepted.modifiedAt, accepted.createdAt);
    assert.deepEqual(authoredPayload(accepted), authoredPayload(positive),
      'Every authored field survives the actual decoder, validator, install and save without normalization');
    fixture.verify(accepted);
  },
  acceptedVisible: (nodes, accepted) => nodes.some(node => node.identifier === 'workspace-project'
    && node.title === accepted.title && node.label === accepted.title + ', Projects' && node.hittable)
    && nodes.some(node => node.identifier === 'workspace-tabs' && node.enabled && node.hittable),
}));

// Portable input checks only. Never invoke verifyPositive with a fabricated app
// result and never infer validation, saving, native UI, or a passing journey.
assert.deepEqual(validationAcceptanceTests.map(test => [test.key, test.id]), [
  ['compatibility/dormant-cue', cueID],
  ['compatibility/legacy-links', characterID],
  ['compatibility/confirmed-unlink', characterID],
]);
for (const test of validationAcceptanceTests) {
  const input = test.makePositive();
  const text = test.serializePositive(input);
  assert.deepEqual(JSON.parse(text), input, 'Strict JSON preserves the synthetic input');
  assert.equal(Object.hasOwn(input, 'cloudProjectId'), false);
  assert.deepEqual(input.images, []);
  assert.deepEqual(input.audioAssets, []);
  assert.deepEqual(input.audioClips, []);
  test.inputBytes = { encoding: 'UTF-8', limit: 65536, positive: Buffer.byteLength(text, 'utf8') };
}
assert.equal(Object.hasOwn(characterFixture(false).entries[0], 'characterLinks'), false);
assert.deepEqual(characterFixture(true).entries[0].characterLinks.map(link => [link.location, link.length, link.text]),
  [[0, 5, 'Randy'], [6, 5, 'waits']]);
