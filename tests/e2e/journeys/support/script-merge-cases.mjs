import assert from 'node:assert/strict';

// Input documents only. Timings are literal fixture values, not a JavaScript
// implementation of Scriv's tokenizer, merge operation, or timing engine.
export const frozenMergeSources = {
  commit: '4d14b29f4fb49891e850fa9a8e5742dc878603c8',
  core: { path: 'apps/mac/Tests/ScrivCoreTests/ScriptBoundaryEditingTests.swift',
    sha256: 'b82428d728f60400b7ca9f3b676c283776b006529f0c9811647e92491ff908ad' },
  ui: { path: 'apps/catalyst/Tests/ScriptUIKitTests.swift',
    sha256: '986a3151f30ac1ca31c0f0d42272958891b692387f0fc1b06162a107a960c177' },
};
const word = (id, text, startMs, endMs, authored = false) => ({ id, text, startMs, endMs,
  ...(authored ? { timingSource: 'authored' } : {}) });
const line = (id, order, text, ownedDurationMs, words, extra = {}) => ({ id, sceneId: 's', order,
  kind: 'dialogue', text, ownedDurationMs, coverageDurationMs: 0, color: 'purple', words, ...extra });
const cue = (id, startMs, endMs) => ({ id, sceneId: 's', label: '', startMs, endMs, prompt: '' });
const character = id => ({ id, name: id === 'person' ? 'Alex' : id, aliases: [], biography: '', appearance: '', color: 'blue' });
function project(entries, extra = {}) {
  return { schemaVersion: 1, id: 'script-merge-input', title: 'Untitled', createdAt: 1700000000000,
    modifiedAt: 1700000000000, revision: 0, scenes: [{ id: 's', title: 'Untitled scene', order: 0 }],
    entries, cues: [], characters: [], images: [], audioAssets: [], audioClips: [], audioVolume: 1, ...extra };
}
const one = () => line('a', 0, 'One ', 3000, [word('a-one', 'One', 0, 3000)]);
const source = (kind, number, lines) => ({ id: `${frozenMergeSources[kind].path}::${String(number).padStart(4, '0')}`, lines });
const selected = (text, words) => project([line('a', 0, 'Prior ', 3000, [word('a-prior', 'Prior', 0, 3000)]),
  line('b', 1, text, 3000, words)]);

export const scriptMergeCases = [
  { key: 'authored-words', group: 'merge-and-save', target: 'b',
    sources: [source('core', 6, [60, 61, 62, 63])],
    makeInput() { const a = one(); a.words[0].timingSource = 'authored';
      return project([a, line('b', 1, 'two three', 2000,
        [word('b-two', 'two', 0, 750), word('b-three', 'three', 750, 2000, true)])], { cues: [cue('cue', 1700, 3000)] }); },
    expectedText: 'One two three', caret: 4, preserveWordIDs: true,
    expectedWordTimes: [[0, 1800], [1800, 2250], [2250, 3000]] },
  { key: 'touching-annotations', group: 'merge-and-save', target: 'b',
    sources: [source('core', 7, [70, 71])],
    makeInput() { const link = { id: 'link', characterId: 'person', location: 0, length: 4, text: 'Alex', isConfirmed: true };
      return project([line('a', 0, 'Alex', 3000, [word('a-alex', 'Alex', 0, 3000)], { characterLinks: [structuredClone(link)] }),
        line('b', 1, 'Alex', 1000, [word('b-alex', 'Alex', 0, 1000)], { characterLinks: [structuredClone(link)] })],
      { characters: [character('person')], cues: [cue('cue', 1700, 3000)] }); },
    expectedText: 'AlexAlex', caret: 4 },
  { key: 'all-cues-retained', group: 'merge-and-save', target: 'b',
    sources: [source('core', 8, [77, 78])],
    makeInput: () => project([one(), line('b', 1, 'two', 2000, [word('b-two', 'two', 0, 2000)])],
      { cues: [cue('cue', 1700, 3000), cue('second', 3500, 5000)] }),
    expectedText: 'One two', caret: 4, preserveWordIDs: true },
  { key: 'zero-owned-direction-roundtrip', group: 'merge-and-save', target: 'a', splitAt: 5,
    sources: [source('core', 9, [83, 85])],
    makeInput: () => project([line('a', 0, 'Keep watching', 0, [], { kind: 'direction', coverageDurationMs: 5000 }),
      line('spoken', 1, 'One', 6000, [word('spoken-one', 'One', 0, 6000)])]),
    expectedText: 'Keep watching', caret: 5 },
  { key: 'unicode-history-reopen', group: 'merge-and-save', target: 'b', sources: [], history: true, reopen: true,
    makeInput: () => project([line('a', 0, '😀 cafe\u0301 ', 3000,
      [word('a-face', '😀', 0, 1000), word('a-decomposed', 'cafe\u0301', 1000, 3000, true)], { characterLinks: [] }),
    line('b', 1, '👩🏽‍🚀 café  Alex', 2000, [word('b-astronaut', '👩🏽‍🚀', 0, 500),
      word('b-composed', 'café', 500, 1000), word('b-alex', 'Alex', 1000, 2000)], { characterLinks: [] })]),
    expectedText: '😀 cafe\u0301 👩🏽‍🚀 café  Alex', caret: 9, preserveWordIDs: true },
  { key: 'selected-zero-deletes-only-selection', group: 'native-deletion', target: 'b',
    sources: [source('ui', 9, [119, 121, 122])],
    makeInput: () => selected('One two', [word('b-one', 'One', 0, 1500), word('b-two', 'two', 1500, 3000)]),
    start: 0, end: 3, expectedText: ' two', caret: 0 },
  { key: 'unicode-selected-word-keeps-spaces', group: 'native-deletion', target: 'b',
    sources: [source('ui', 10, [130, 131, 132])],
    observeCallbackCounts: true,
    makeInput: () => selected('😀 One two', [word('b-face', '😀', 0, 429),
      word('b-one', 'One', 429, 1714), word('b-two', 'two', 1714, 3000)]),
    start: 3, end: 6, expectedText: '😀  two', caret: 3 },
  { key: 'nonzero-caret-ordinary-backspace', group: 'native-deletion', target: 'b', sources: [],
    makeInput: () => selected('One two', [word('b-one', 'One', 0, 1500), word('b-two', 'two', 1500, 3000)]),
    start: 3, end: 3, expectedText: 'On two', caret: 2 },
  { key: 'first-row-rejected', group: 'rejected-boundaries', target: 'a',
    sources: [source('core', 10, [91])],
    makeInput: () => project([line('a', 0, '🙂 e\u0301', 3000,
      [word('a-smile', '🙂', 0, 1500), word('a-accent', 'e\u0301', 1500, 3000)])], { cues: [cue('cue', 1700, 3000)] }),
    error: 'There is no previous line in this scene.' },
  { key: 'previous-scene-is-not-previous-row', group: 'rejected-boundaries', target: 'a', sources: [],
    makeInput: () => project([line('other', 0, 'Other scene', 3000,
      [word('other-one', 'Other', 0, 1500), word('other-two', 'scene', 1500, 3000)], { sceneId: 'prior' }), one()],
    { scenes: [{ id: 's', title: 'Current scene', order: 1 }, { id: 'prior', title: 'Earlier scene', order: 0 }] }),
    error: 'There is no previous line in this scene.' },
  { key: 'mixed-kind-rejected', group: 'rejected-boundaries', target: 'b',
    sources: [source('core', 10, [93])],
    makeInput: () => project([line('a', 0, '🙂 e\u0301', 3000,
      [word('a-smile', '🙂', 0, 1500), word('a-accent', 'e\u0301', 1500, 3000)]),
      line('b', 1, 'Action', 0, [], { kind: 'direction' })], { cues: [cue('cue', 1700, 3000)] }),
    error: 'A spoken line and a direction cannot be merged without changing their meaning. Move the text explicitly instead.' },
  { key: 'insufficient-previous-duration', group: 'rejected-boundaries', target: 'b',
    sources: [source('core', 11, [99])],
    makeInput: () => project([line('a', 0, 'x ', 1, [word('a-x', 'x', 0, 1)]),
      line('b', 1, 'y z', 2, [word('b-y', 'y', 0, 1), word('b-z', 'z', 1, 2)])]),
    error: 'The previous line is too short for all these words. Increase its duration before merging.' },
  { key: 'different-speakers-rejected', group: 'rejected-boundaries', target: 'b', sources: [],
    makeInput: () => project([line('a', 0, 'One ', 3000, [word('a-one', 'One', 0, 3000)], { characterId: 'Left' }),
      line('b', 1, 'two', 2000, [word('b-two', 'two', 0, 2000)], { characterId: 'Right' })],
    { characters: [character('Left'), character('Right')] }),
    error: 'These lines have different speakers. Assign the same speaker before merging so dialogue is not attributed to another character.' },
];

// Portable serialization/fixture checks only: never report these as app passes.
assert.equal(new Set(scriptMergeCases.map(test => test.key)).size, scriptMergeCases.length);
for (const test of scriptMergeCases) {
  const input = test.makeInput();
  assert.deepEqual(JSON.parse(JSON.stringify(input)), input);
  assert.ok(Buffer.byteLength(JSON.stringify(input), 'utf8') < 64 * 1024);
  assert.equal(input.cloudProjectId, undefined);
  assert.deepEqual([input.images, input.audioAssets, input.audioClips], [[], [], []]);
  assert.equal(input.entries.filter(entry => entry.id === test.target).length, 1);
}
assert.equal(scriptMergeCases.find(test => test.key === 'unicode-history-reopen').makeInput().entries[0].text.length, 9);
