import assert from 'node:assert/strict';

// Literal synthetic input and expected source spans, not a second name matcher.
export const frozenMentionSource = {
  commit: '4d14b29f4fb49891e850fa9a8e5742dc878603c8',
  path: 'apps/mac/Tests/ScrivCoreTests/CharacterMentionTests.swift',
  sha256: 'cb01be993cb6a0cb3d6835993cfb9e544404c83054283c8d4bc943dd8ccb10e5',
};
const source = (number, lines) => ({
  id: `${frozenMentionSource.path}::${String(number).padStart(4, '0')}`, lines,
});
const character = (id, name, aliases = []) => ({
  id, name, aliases, biography: '', appearance: '', color: 'blue',
});
const proposed = (characterId, location, length, text) => ({
  characterId, location, length, text, isConfirmed: false,
});

export const mentionCases = [
  { key: 'canonical-alias-longest', group: 'mention-detection', journey: 'AUT-J06',
    sources: [source(1, [9, 10])],
    characters: [character('franklin', 'Farmer Franklin', ['Franklin']),
      character('farmer', 'Farmer'), character('m', 'Miyazaki')],
    text: "Franklin turns. Farmer Franklin asks Miyazaki's opinion.",
    expectedLinks: [proposed('franklin', 0, 8, 'Franklin'),
      proposed('franklin', 16, 15, 'Farmer Franklin'), proposed('m', 37, 8, 'Miyazaki')] },
  { key: 'canonical-over-alias-ambiguous-sam', group: 'mention-detection', journey: 'AUT-J06',
    sources: [source(2, [15, 16])],
    // The original deliberately supplies b before a; do not sort this catalog.
    characters: [character('b', 'Bea', ['Sam', 'Anna']), character('a', 'Anna', ['Sam'])],
    text: 'Anna and Sam', expectedLinks: [proposed('a', 0, 4, 'Anna')] },
  { key: 'duplicate-canonical-unassigned', group: 'mention-detection', journey: 'AUT-J06',
    sources: [source(2, [17])],
    characters: [character('a', 'Anna', ['Sam']), character('duplicate', 'Anna')],
    text: 'Anna', expectedLinks: [] },
  { key: 'unicode-boundaries-regex-literal', group: 'mention-detection', journey: 'AUT-J06',
    sources: [source(3, [23, 24, 25])],
    characters: [character('ann', 'Ann'), character('mei', '美'), character('plus', 'C++')],
    text: '🙂 Ann, ANNA, Joanne, 美！ C++? Ann_2.',
    expectedLinks: [proposed('ann', 3, 3, 'Ann'), proposed('mei', 22, 1, '美'),
      proposed('plus', 25, 3, 'C++')] },
];

export function mentionInput(test) {
  return {
    schemaVersion: 1, id: 'mention-detection-input', title: 'Mention detection',
    createdAt: 1700000000000, modifiedAt: 1700000000000, revision: 0,
    scenes: [{ id: 'mention-scene', title: 'Mentions', order: 0 }],
    entries: [
      { id: 'mention-line', sceneId: 'mention-scene', order: 0, kind: 'direction', text: 'Draft.',
        ownedDurationMs: 3000, coverageDurationMs: 5000, color: 'purple', words: [], characterLinks: [] },
      { id: 'untouched-line', sceneId: 'mention-scene', order: 1, kind: 'direction', text: 'Unrelated source.',
        ownedDurationMs: 3000, coverageDurationMs: 3000, color: 'green', words: [], characterLinks: [] },
    ],
    characters: structuredClone(test.characters), cues: [], images: [],
    audioAssets: [], audioClips: [], audioVolume: 1,
  };
}

export const mentionCatalogCases = mentionCases.map(test => ({
  group: test.group, id: test.key, journey: test.journey, sources: test.sources,
  oracles: ['exact imported catalog order/names/aliases', 'mounted Script text-input change',
    'complete ordered proposed characterLinks with literal UTF-16 source ranges',
    'unconfirmed unique link identities', 'all unrelated project fields preserved',
    'complete loaded/saved/browser-reopened equality'],
}));

// Portable fixture consistency only. This cannot prove application behavior.
export function auditMentionFixtures() {
  assert.equal(new Set(mentionCases.map(test => test.key)).size, 4);
  const sourceLines = [];
  for (const test of mentionCases) {
    const input = mentionInput(test);
    assert.deepEqual(JSON.parse(JSON.stringify(input)), input);
    assert.ok(Buffer.byteLength(JSON.stringify(input), 'utf8') < 64 * 1024);
    assert.deepEqual(input.characters, test.characters);
    assert.deepEqual(input.entries.map(entry => entry.characterLinks), [[], []]);
    assert.equal(input.entries[0].text, 'Draft.');
    assert.notEqual(test.text, input.entries[0].text);
    assert.deepEqual([input.images, input.audioAssets, input.audioClips], [[], [], []]);
    assert.equal(Object.hasOwn(input, 'cloudProjectId'), false);
    let end = 0;
    for (const link of test.expectedLinks) {
      assert.ok(input.characters.some(value => value.id === link.characterId));
      assert.ok(Number.isInteger(link.location) && Number.isInteger(link.length)
        && link.location >= end && link.length > 0 && link.location + link.length <= test.text.length);
      assert.equal(test.text.slice(link.location, link.location + link.length), link.text);
      assert.equal(link.isConfirmed, false);
      end = link.location + link.length;
    }
    sourceLines.push(...test.sources.flatMap(value => value.lines));
  }
  assert.deepEqual(sourceLines, [9, 10, 15, 16, 17, 23, 24, 25]);
  assert.equal(mentionCases[3].text.slice(0, 2), '🙂');
  assert.equal(mentionCases[3].expectedLinks[0].location, 3);
  return { frozenTests: 3, assertions: 8, documents: 4, nativeVerified: false };
}
