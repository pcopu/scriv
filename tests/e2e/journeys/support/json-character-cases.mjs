import assert from 'node:assert/strict';
// Exact serialized-input fixtures; not a character-range validator.
const frozenID = 'apps/mac/Tests/ScrivCoreTests/CharacterMentionTests.swift::0013';
const expectedError = 'Character links must preserve exact, non-overlapping script ranges and refer to existing characters.';
const link = (location = 0, length = 5, text = 'Randy') => ({
  id: 'confirmed-link', characterId: 'randy', location, length, text, isConfirmed: true,
});
const words = {
  'Randy waits.': [
    { id: 'word-one', text: 'Randy', startMs: 0, endMs: 1363 },
    { id: 'word-two', text: 'waits.', startMs: 1363, endMs: 3000 },
  ],
  '🙂 Randy': [
    { id: 'word-one', text: '🙂', startMs: 0, endMs: 500 },
    { id: 'word-two', text: 'Randy', startMs: 500, endMs: 3000 },
  ],
  'e\u0301': [{ id: 'word-one', text: 'e\u0301', startMs: 0, endMs: 3000 }],
};
function model(name, text, annotation) {
  // Required project/timing fields supply a valid container around the exact
  // frozen entry/link fixtures. Fixed IDs and dates are synthetic only; normal
  // JSON import replaces the project identity and dates before installation.
  return {
    schemaVersion: 1, id: 'synthetic-character-links', title: `Character links: ${name}`,
    createdAt: 0, modifiedAt: 0, revision: 0,
    scenes: [{ id: 'scene', title: 'Untitled scene', order: 0 }],
    entries: [{ id: 'line', sceneId: 'scene', order: 0, kind: 'dialogue', text,
      ownedDurationMs: 3000, coverageDurationMs: 0, color: 'purple',
      words: structuredClone(words[text]), characterLinks: [annotation] }],
    characters: [{ id: 'randy', name: 'Randy', aliases: ['Rand'], biography: '', appearance: '', color: 'blue' }],
    images: [], cues: [], audioAssets: [], audioClips: [], audioVolume: 1,
  };
}
const cases = [
  { name: 'missing character', text: 'Randy waits.', annotation: link(),
    invalidate(project) { project.characters = []; },
    expected: { text: 'Randy waits.', characterIDs: [], links: [link()] } },
  { name: 'stale source text', text: 'Randy waits.', annotation: link(),
    invalidate(project) { project.entries[0].characterLinks[0].text = 'Jason'; },
    expected: { text: 'Randy waits.', characterIDs: ['randy'], links: [{ ...link(), text: 'Jason' }] } },
  { name: 'duplicate overlapping link', text: 'Randy waits.', annotation: link(),
    invalidate(project) { project.entries[0].characterLinks.push(structuredClone(project.entries[0].characterLinks[0])); },
    expected: { text: 'Randy waits.', characterIDs: ['randy'], links: [link(), link()] } },
  { name: 'split Unicode surrogate', text: '🙂 Randy', annotation: link(3),
    invalidate(project) { project.entries[0].characterLinks = [link(1, 1, 'x')]; },
    expected: { text: '🙂 Randy', characterIDs: ['randy'], links: [link(1, 1, 'x')] } },
  { name: 'Int.max range', text: '🙂 Randy', annotation: link(3),
    invalidate(project) {
      project.entries[0].characterLinks = [link('__INT_MAX_LOCATION__', '__INT_MAX_LENGTH__')];
    },
    expected: { text: '🙂 Randy', characterIDs: ['randy'], links: [link('__INT_MAX_LOCATION__', '__INT_MAX_LENGTH__')] },
    rawIntMax: true },
  { name: 'canonical-equivalent source mismatch', text: 'e\u0301', annotation: link(0, 2, 'e\u0301'),
    invalidate(project) { project.entries[0].characterLinks[0].text = '\u00e9'; },
    expected: { text: 'e\u0301', characterIDs: ['randy'], links: [link(0, 2, '\u00e9')] } },
];
const sourceFields = project => ({ text: project.entries[0].text,
  characterIDs: project.characters.map(character => character.id), links: project.entries[0].characterLinks });
const stableFields = ({ id, createdAt, modifiedAt, cloudProjectId, ...fields }) => fields;
const sorted = projects => [...projects].sort((left, right) => left.id.localeCompare(right.id));

function rawJSON(project, fixture) {
  let text = JSON.stringify(project);
  if (fixture.rawIntMax) {
    // Swift's 64-bit Int.max must survive the outer CLI JSON envelope as raw
    // nested JSON digits. A JavaScript Number would round it before decoding,
    // testing a decoder error instead of the production link range validation.
    const location = '"location":"__INT_MAX_LOCATION__"';
    const length = '"length":"__INT_MAX_LENGTH__"';
    assert.equal(text.split(location).length, 2);
    assert.equal(text.split(length).length, 2);
    text = text.replace(location, '"location":9223372036854775807')
      .replace(length, '"length":9223372036854775807');
    assert.equal(text.match(/9223372036854775807/g)?.length, 2);
    assert.ok(!text.includes('__INT_MAX_'));
    assert.ok(text.includes('"location":9223372036854775807,"length":9223372036854775807'));
  }
  assert.ok(Buffer.byteLength(text, 'utf8') <= 64 * 1024, 'Fixture stays inside the semantic import byte limit');
  return text;
}

assert.equal(cases.length, 6, 'All six frozen rejection assertions have separate fresh sessions');
// Fixture checks only, not a parallel implementation of CharacterMentions.
assert.deepEqual([...cases[3].text].map(character => character.codePointAt(0)), [0x1f642, 32, 82, 97, 110, 100, 121]);
assert.equal(cases[3].text.length, 8, 'Emoji occupies two UTF-16 code units');
assert.deepEqual([...cases[5].text].map(character => character.codePointAt(0)), [0x65, 0x301]);
assert.equal(cases[5].expected.links[0].text, '\u00e9');
assert.notEqual(cases[5].text, cases[5].expected.links[0].text, 'Canonical equivalence is not exact source text');

export { cases as characterCases, frozenID, expectedError, model, sourceFields, stableFields, rawJSON };
