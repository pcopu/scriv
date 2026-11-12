import assert from 'node:assert/strict';

export const identityFrozenSource = {
  commit: '4d14b29f4fb49891e850fa9a8e5742dc878603c8',
  path: 'apps/mac/Tests/ScrivCoreTests/CharacterMentionTests.swift',
  sha256: 'cb01be993cb6a0cb3d6835993cfb9e544404c83054283c8d4bc943dd8ccb10e5',
};
const word = (id, text, startMs, endMs) => ({ id, text, startMs, endMs });
const simpleWords = [word('word-randy', 'Randy', 0, 1363), word('word-waits', 'waits.', 1363, 3000)];
// null word IDs mean a new UUID, never permission to copy arbitrary metadata.
const edit = (start, end, text, expectedText) => ({ start, end, text, expectedText });
export const identityReviewCases = [
  { key: 'emoji-prefix', number: 8, lines: [88, 89, 90, 91], source: 'Randy waits.', location: 0,
    edits: [edit(0, 0, '🙂 ', '🙂 Randy waits.')], result: '🙂 Randy waits.', resultLocation: 3,
    words: [word(null, '🙂', 0, 250), word('word-randy', 'Randy', 250, 1500), word('word-waits', 'waits.', 1500, 3000)] },
  { key: 'multiple-edits-one-session', number: 9, lines: [99, 100, 101], source: 'Before Randy after.', location: 7,
    initialWords: [word('word-before', 'Before', 0, 1058), word('word-randy', 'Randy', 1058, 1941), word('word-after', 'after.', 1941, 3000)],
    edits: [edit(0, 6, 'Earlier', 'Earlier Randy after.'), edit(14, 19, 'later', 'Earlier Randy later.')],
    result: 'Earlier Randy later.', resultLocation: 8,
    words: [word(null, 'Earlier', 0, 1166), word('word-randy', 'Randy', 1166, 2000), word(null, 'later.', 2000, 3000)] },
  { key: 'replace-name-reproposes', number: 10, lines: [107, 108, 109], source: 'Randy waits.', location: 0,
    edits: [edit(0, 5, 'Jason', 'Jason waits.')], result: 'Jason waits.', resultLocation: 0, reassign: true,
    words: [word(null, 'Jason', 0, 1363), word('word-waits', 'waits.', 1363, 3000)] },
  { key: 'letter-boundary-revokes', number: 11, lines: [114], source: 'Randy waits.', location: 0,
    edits: [edit(0, 0, 'X', 'XRandy waits.')], result: 'XRandy waits.', noLinks: true,
    words: [word(null, 'XRandy', 0, 1500), word('word-waits', 'waits.', 1500, 3000)] },
  { key: 'space-boundary-preserves', number: 11, lines: [116, 117], source: 'Randy waits.', location: 0,
    edits: [edit(0, 0, ' ', ' Randy waits.')], result: ' Randy waits.', resultLocation: 1,
    words: simpleWords },
  { key: 'prefix-preserves-speaker', number: 15, lines: [161, 162, 163, 164], source: 'Randy waits.', location: 0, speaker: true,
    edits: [edit(0, 0, 'Now ', 'Now Randy waits.')], result: 'Now Randy waits.', resultLocation: 4,
    words: [word(null, 'Now', 0, 643), word('word-randy', 'Randy', 643, 1714), word('word-waits', 'waits.', 1714, 3000)] },
];
// Partial unlink behavior only: frozen ::0006's preceding correction menu is excluded.
export const identityUnlinkCompanion = {
  key: 'companion-saved-unlink-suffix', source: 'Randy waits.', location: 0, unlink: true,
  edits: [edit(12, 12, ' Still.', 'Randy waits. Still.')], result: 'Randy waits. Still.', resultLocation: 0,
  words: [word('word-randy', 'Randy', 0, 882), word('word-waits', 'waits.', 882, 1941), word(null, 'Still.', 1941, 3000)],
};
export function identityReviewInput(test) {
  return {
    schemaVersion: 1, id: 'identity-review-input', title: 'Identity review',
    createdAt: 1700000000000, modifiedAt: 1700000000000, revision: 0,
    scenes: [{ id: 'identity-scene', title: 'Identity', order: 0 }],
    entries: [{ id: 'identity-line', sceneId: 'identity-scene', order: 0, kind: 'dialogue', text: test.source,
      ...(test.speaker ? { characterId: 'randy' } : {}), ownedDurationMs: 3000, coverageDurationMs: 0, color: 'purple',
      words: structuredClone(test.initialWords ?? simpleWords),
      characterLinks: [{ id: 'identity-proposal', characterId: 'randy', location: test.location, length: 5, text: 'Randy', isConfirmed: false }] },
    { id: 'untouched-line', sceneId: 'identity-scene', order: 1, kind: 'direction', text: 'Unrelated source.',
      ownedDurationMs: 3000, coverageDurationMs: 5000, color: 'green', words: [], characterLinks: [] }],
    characters: [{ id: 'randy', name: 'Randy', aliases: ['Rand'], biography: '', appearance: '', color: 'blue' },
      ...(test.reassign ? [{ id: 'jason', name: 'Jason', aliases: [], biography: '', appearance: '', color: 'green' }] : [])],
    cues: [], images: [], audioAssets: [], audioClips: [], audioVolume: 1,
  };
}
export const identityReviewCatalog = identityReviewCases.map(test => ({
  group: 'review-and-edit', id: test.key, journey: 'AUT-J06',
  nativeVerified: false, retirementAllowed: false,
  equivalenceStatus: test.number === 9 ? 'partial-outcomes-only-same-core-edit-batch-unproven' : 'prepared-native-unverified',
  sources: [{ id: `${identityFrozenSource.path}::${String(test.number).padStart(4, '0')}`, lines: test.lines }],
  oracles: ['real Confirm then Cancel and Save links', 'literal native UTF-16 edit sequence',
    'exact source and complete annotation identity', 'dialogue timing and word identities',
    'full loaded and persisted project equality; unrelated packages unchanged'],
}));
export function auditIdentityReviewFixtures() {
  assert.equal(new Set(identityReviewCases.map(value => value.key)).size, 6);
  for (const test of [...identityReviewCases, identityUnlinkCompanion]) {
    const input = identityReviewInput(test);
    assert.deepEqual(JSON.parse(JSON.stringify(input)), input);
    assert.equal(input.entries[0].kind, 'dialogue');
    assert.equal(test.source.slice(test.location, test.location + 5), 'Randy');
    let text = test.source;
    for (const change of test.edits) {
      assert.ok(change.start >= 0 && change.end >= change.start && change.end <= text.length);
      text = text.slice(0, change.start) + change.text + text.slice(change.end);
      assert.equal(text, change.expectedText);
    }
    assert.equal(text, test.result);
    assert.deepEqual(test.words.map(value => value.text), test.result.trim().split(/\s+/u));
    assert.equal(test.words.at(-1).endMs, 3000);
    assert.equal(Object.hasOwn(input, 'cloudProjectId'), false);
  }
  return { frozenTests: 5, assertions: 17, documents: 7, nativeVerified: false, retirementAllowed: false };
}
