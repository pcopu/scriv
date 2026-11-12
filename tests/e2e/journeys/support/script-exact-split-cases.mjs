// Literal frozen constructor results, not a second implementation of splitting.
// Only constructor-generated UUIDs and clock values are replaced in prerequisites.
const word = (id, text, startMs, endMs, timingSource) => ({ id, text, startMs, endMs,
  ...(timingSource === undefined ? {} : { timingSource }) });
const ordinaryWords = () => [word('w1', 'One', 0, 818), word('w2', 'two', 818, 1636), word('w3', 'three', 1636, 3000)];
const link = (id, location, length, text) => ({ id, characterId: 'person', location, length, text, isConfirmed: true });
export const exactSplitFixtures = [
  { id: 'whitespace-word-identity', sourceCase: '0001', sourceLines: [8, 17], text: 'One  two\tthree', offset: 5,
    words: ordinaryWords(), texts: ['One  ', 'two\tthree'], durations: [818, 2182],
    resultWords: [[word('w1', 'One', 0, 818)], [word('w2', 'two', 0, 818), word('w3', 'three', 818, 2182)]],
    cueOwner: 'right', cueOffset: 882 },
  { id: 'inside-authored-word', sourceCase: '0002', sourceLines: [18, 28], text: 'Hello world', offset: 2,
    words: [word('w1', 'Hello', 0, 1500, 'authored'), word('w2', 'world', 1500, 3000)],
    texts: ['He', 'llo world'], durations: [600, 2400],
    resultWords: [[word('$leftWord', 'He', 0, 600, 'authored')],
      [word('$rightWord', 'llo', 0, 900, 'authored'), word('w2', 'world', 900, 2400)]],
    cueOwner: 'right', cueOffset: 1100 },
  { id: 'confirmed-identity-emoji', sourceCase: '0003', sourceLines: [29, 37], text: '🙂 Alex Alex', offset: 5,
    words: [word('w1', '🙂', 0, 334), word('w2', 'Alex', 334, 1667), word('w3', 'Alex', 1667, 3000)],
    links: [link('first', 3, 4, 'Alex'), link('second', 8, 4, 'Alex')],
    texts: ['🙂 Al', 'ex Alex'], durations: [1001, 1999],
    resultWords: [[word('w1', '🙂', 0, 334), word('$leftWord', 'Al', 334, 1001)],
      [word('$rightWord', 'ex', 0, 666), word('w3', 'Alex', 666, 1999)]],
    resultLinks: [[link('first', 3, 2, 'Al')], [link('$rightLink', 0, 2, 'ex'), link('second', 3, 4, 'Alex')]],
    cueOwner: 'right', cueOffset: 699 },
  { id: 'empty-left', sourceCase: '0004', sourceLines: [38, 45], text: 'One', offset: 0,
    words: [word('w1', 'One', 0, 3000)], texts: ['', 'One'], durations: [1, 2999],
    resultWords: [[], [word('w1', 'One', 0, 2999)]], cueOwner: 'right', cueOffset: 1699 },
  { id: 'empty-right', sourceCase: '0004', sourceLines: [38, 45], text: 'One', offset: 3,
    words: [word('w1', 'One', 0, 3000)], texts: ['One', ''], durations: [2999, 1],
    resultWords: [[word('w1', 'One', 0, 2999)], []], cueOwner: 'left', cueOffset: 1700 },
  { id: 'image-audio-anchors', sourceCase: '0005', sourceLines: [46, 55], text: 'One two three', offset: 4,
    words: ordinaryWords(), texts: ['One ', 'two three'], durations: [818, 2182],
    resultWords: [[word('w1', 'One', 0, 818)], [word('w2', 'two', 0, 818), word('w3', 'three', 818, 2182)]],
    cueOwner: 'right', cueOffset: 882, audio: true },
];
export function exactSplitInput(test) {
  return { schemaVersion: 1, id: 'exact-split-fixture', title: 'Untitled', createdAt: 1700000000000,
    modifiedAt: 1700000000000, revision: 0,
    scenes: [{ id: 's', title: 'Untitled scene', order: 0 }],
    entries: [{ id: 'a', sceneId: 's', order: 0, kind: 'dialogue', text: test.text,
      ownedDurationMs: 3000, coverageDurationMs: 0, color: 'purple', words: structuredClone(test.words),
      ...(test.links ? { characterLinks: structuredClone(test.links) } : {}) }],
    characters: test.links ? [{ id: 'person', name: 'Alex', aliases: [], biography: '', appearance: '', color: 'blue' }] : [],
    images: [], cues: [{ id: 'cue', sceneId: 's', label: '', startMs: 1700, endMs: 3000, prompt: '' }],
    // Frozen metadata only. No media files are created, downloaded or played.
    audioAssets: test.audio ? [{ id: 'audio', fileName: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.wav',
      sha256: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', byteCount: 20,
      durationMs: 3000, sampleRate: 44100, channelCount: 1, waveform: [0.2], originalName: 'Test' }] : [],
    audioClips: test.audio ? [{ id: 'clip', sceneId: 's', entryId: 'a', assetId: 'audio', startMs: 1600,
      sourceStartMs: 300, durationMs: 1000, volume: 1, isMuted: false }] : [], audioVolume: 1 };
}
export const exactSplitCases = exactSplitFixtures.map(test => ({ group: 'exact-split', id: test.id,
  interactions: ['SCR-03', 'SCR-04', 'SCR-06', 'SCR-05'],
  sourceSlice: `apps/mac/Tests/ScrivCoreTests/ScriptBoundaryEditingTests.swift::${test.sourceCase}`,
  sourceLines: test.sourceLines, sourceSHA256: 'b82428d728f60400b7ca9f3b676c283776b006529f0c9811647e92491ff908ad',
  baselineCommit: '4d14b29f4fb49891e850fa9a8e5742dc878603c8', selection: [test.offset, test.offset],
  route: 'fresh session per fixture → literal import-json → actual editor focus → selection → public Return delegate → store split → save/loaded/undo/redo/different-document reopen',
  oracles: ['exact constructor prerequisites including omitted optional fields and generated word times',
    'literal complete split model with strict fresh-ID relationships', 'exact source, stable untouched word identity, authored ownership and confirmed links',
    'cue ownership and audio source/placement conservation', 'complete undo/redo content with explicit bootstrap fields, package isolation and reopen'],
  nativeVerified: false, retirementAllowed: false,
}));
