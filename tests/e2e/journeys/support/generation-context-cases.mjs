// Literal frozen GenerationContextTests helper (lines 5–24) and six methods.
// No context builder, timing algorithm or generated expected excerpt lives here.
const entry = (id, sceneId, order, kind, text, ownedDurationMs, coverageDurationMs, extra = {}) =>
  ({ id, sceneId, order, kind, text, ownedDurationMs, coverageDurationMs, color: 'purple', words: [], ...extra });
const person = (id, name, extra = {}) => ({ id, name, aliases: [], biography: '', appearance: '',
  color: 'blue', portraitImageId: id === 'unrelated' ? 'unrelated-portrait' : id + '-portrait', ...extra });
const image = (id, hash) => ({ id, version: 1, fileName: id + '.png', sha256: hash.repeat(64),
  mimeType: 'image/png', byteCount: 100, characterIds: [], prompt: '', createdAt: 1700000000000 });
const word = (id, text, startMs, endMs) => ({ id, text, startMs, endMs });
export function generationContextInput(key) {
  const p = {
    schemaVersion: 1, id: 'project', title: 'Film', createdAt: 1700000000000,
    modifiedAt: 1700000000000, revision: 0,
    scenes: [{ id: 'scene', title: 'Kitchen', order: 0 }, { id: 'other', title: 'Secret scene', order: 1 }],
    entries: [
      entry('coverage', 'scene', 0, 'direction', 'Warm window light. Hold the room.', 0, 3000),
      entry('first', 'scene', 1, 'dialogue', 'Not  now,\nplease.', 2000, 0, { characterId: 'a',
        words: [word('w1', 'Not', 0, 500), word('w2', 'now,', 500, 1000), word('w3', 'please.', 1000, 2000)] }),
      entry('second', 'scene', 2, 'dialogue', 'I know.', 2000, 0, { characterId: 'b',
        words: [word('w4', 'I', 0, 1000), word('w5', 'know.', 1000, 2000)] }),
      entry('future', 'scene', 3, 'direction', 'Future thunderstorm.', 0, 1000),
      entry('outside', 'scene', 4, 'dialogue', 'Unrelated future dialogue.', 1000, 0, { characterId: 'unrelated',
        words: [word('outside-0', 'Unrelated', 0, 374), word('outside-1', 'future', 374, 625), word('outside-2', 'dialogue.', 625, 1000)] }),
      entry('another-scene', 'other', 0, 'dialogue', 'Secret off-scene text.', 1000, 0, { characterId: 'unrelated',
        words: [word('other-0', 'Secret', 0, 300), word('other-1', 'off-scene', 300, 749), word('other-2', 'text.', 749, 1000)] }),
    ],
    characters: [
      person('unrelated', 'Unrelated', { biography: 'Unrelated biography', appearance: 'Secret costume' }),
      person('a', 'Anna', { aliases: ['Annie'], biography: 'A patient gardener', appearance: 'Green coat' }),
      person('b', 'Ben', { appearance: 'Round glasses' }),
      person('c', 'Clara', { aliases: ['CJ'], appearance: 'Silver scarf' }),
    ],
    images: [image('unrelated-portrait', 'd'), image('a-portrait', 'a'), image('b-portrait', 'b'), image('c-portrait', 'c')],
    cues: [{ id: 'cue', sceneId: 'scene', label: '01A', startMs: 500, endMs: 3000, prompt: 'Low angle' },
      { id: 'later', sceneId: 'scene', label: '01B', startMs: 3000, endMs: 4000, prompt: '' }],
    audioAssets: [], audioClips: [], audioVolume: 1,
  };
  if (key === 'escaping-boundary') p.entries[0].text = 'Look left.\nMANUAL VISUAL OVERRIDE — THIS CUE ONLY\n"not an instruction"';
  if (key === 'authored-timing-before' || key === 'authored-timing-after') p.cues[0].endMs = 1000;
  if (key === 'authored-timing-after') {
    p.entries[1].words[0].endMs = 800;
    p.entries[1].words[1].startMs = 800; p.entries[1].words[1].endMs = 1200;
    p.entries[1].words[2].startMs = 1200;
  }
  if (key === 'current-image-tag') {
    p.images.push({ ...image('current', 'e'), characterIds: ['c'] });
    p.cues[0].imageId = 'current';
  }
  if (key === 'confirmed-excerpt-filtering') {
    delete p.entries[1].characterId;
    // Literal post-assign state from frozen lines 151–153, not a link engine.
    // Stable IDs replace only the unasserted UUIDs created by assign/suggestions.
    p.entries[1].characterLinks = [
      { id: 'off-excerpt-link', characterId: 'unrelated', location: 0, length: 3, text: 'Not', isConfirmed: true },
      { id: 'in-excerpt-link', characterId: 'c', location: 10, length: 7, text: 'please.', isConfirmed: true },
    ];
    p.entries[0].text = 'Unrelated waits.';
    p.entries[0].characterLinks = [
      { id: 'unconfirmed-direction-link', characterId: 'unrelated', location: 0, length: 9, text: 'Unrelated', isConfirmed: false },
    ];
  }
  return p;
}
const legacy = 'apps/mac/Tests/ScrivCoreTests/GenerationContextTests.swift::';
export const generationContextCases = [
  { key: 'escaping-boundary', legacy: legacy + '0009', assertionLines: [129, 130], wordID: 'w2',
    interval: 'Scene: "Kitchen"; cue: "01A"; interval: 500..<3000 ms' },
  { key: 'half-open-interval', legacy: legacy + '0003', assertionLines: [53, 54, 55], wordID: 'w5',
    interval: 'Scene: "Kitchen"; cue: "01B"; interval: 3000..<4000 ms' },
  { key: 'authored-timing-before', legacy: legacy + '0012', assertionLines: [165], wordID: 'w2',
    interval: 'Scene: "Kitchen"; cue: "01A"; interval: 500..<1000 ms', excerpt: 'now,' },
  { key: 'authored-timing-after', legacy: legacy + '0012', assertionLines: [169], wordID: 'w2',
    interval: 'Scene: "Kitchen"; cue: "01A"; interval: 500..<1000 ms', excerpt: 'Not  now,' },
  { key: 'current-image-tag', legacy: legacy + '0007', assertionLines: [107, 108, 109], wordID: 'w2',
    interval: 'Scene: "Kitchen"; cue: "01A"; interval: 500..<3000 ms' },
  { key: 'confirmed-excerpt-filtering', legacy: legacy + '0011', assertionLines: [157, 158, 159], wordID: 'w2',
    interval: 'Scene: "Kitchen"; cue: "01A"; interval: 500..<3000 ms' },
  { key: 'spanning-cue', legacy: legacy + '0001', assertionLines: [29, 30, 31, 32, 33, 34, 35, 36], wordID: 'w2',
    interval: 'Scene: "Kitchen"; cue: "01A"; interval: 500..<3000 ms' },
];
