import assert from 'node:assert/strict';

// Literal synthetic INPUT documents, never a replacement decoder or model setter.
export function emptyDocument() {
  return { schemaVersion: 1, id: 'model-source', title: 'Model document', createdAt: 1600000000000,
    modifiedAt: 1600000001000, revision: 17, cloudProjectId: 'synthetic-reset-only',
    scenes: [], entries: [], characters: [], images: [], cues: [] };
}
export function completeDocument() {
  const p = emptyDocument();
  p.scenes = [{ id: 'scene', title: 'Archive', order: -0.5 }, { id: 'empty-scene', title: 'Empty', order: 0.25 }];
  p.entries = [
    { id: 'speech', sceneId: 'scene', order: 0.5, kind: 'dialogue', text: 'Mara waits.', characterId: 'mara',
      ownedDurationMs: 1000, coverageDurationMs: 0, color: 'purple', words: [
        { id: 'word-mara', text: 'Mara', startMs: 10, endMs: 400, timingSource: 'authored' },
        { id: 'word-waits', text: 'waits.', startMs: 500, endMs: 900 }],
      characterLinks: [{ id: 'mention', characterId: 'mara', location: 0, length: 4, text: 'Mara', isConfirmed: true },
        { id: 'unlink', location: 5, length: 5, text: 'waits', isConfirmed: true }] },
    { id: 'note', sceneId: 'scene', order: 1.25, kind: 'direction', text: 'Wait e\u0301.', ownedDurationMs: 0,
      coverageDurationMs: 2000, color: 'orange', words: [], characterLinks: [] },
  ];
  p.characters = [{ id: 'mara', name: 'Mara', aliases: ['Night watch', 'M'], biography: 'Line one\nLine two',
    appearance: 'Blue coat', color: 'teal', portraitImageId: 'image-two',
    portraitRegion: { imageID: 'image-two', imageSHA256: 'b'.repeat(64), isAutomatic: false,
      region: { x: 0.25, y: 0, width: 0.5, height: 1 } } }];
  p.images = [
    { id: 'image-one', version: 1, fileName: 'one.png', sha256: 'a'.repeat(64), mimeType: 'image/png', byteCount: 1,
      characterIds: [], prompt: '', createdAt: 1500000000123 },
    { id: 'image-two', version: 2, fileName: 'two.webp', sha256: 'b'.repeat(64), mimeType: 'image/webp', byteCount: 25 * 1024 * 1024,
      characterIds: ['mara'], prompt: 'Manual e\u0301', generationPrompt: 'Captured e\u0301', createdAt: 1500000000456,
      previousVersionId: 'image-one' },
  ];
  p.cues = [{ id: 'cue', sceneId: 'scene', imageId: 'image-two', label: 'A', startMs: 0, endMs: 1000,
    prompt: 'Cinematic e\u0301', startAnchor: { entryId: 'speech', offsetMs: 0 }, authoredDurationMs: 1500 }];
  p.audioAssets = [{ id: 'sound', fileName: 'c'.repeat(64) + '.flac', sha256: 'c'.repeat(64), byteCount: 1,
    durationMs: 1000, sampleRate: 1, channelCount: 1, waveform: [0, 0.25, 0.5, 1], originalName: 'Synthetic.flac' }];
  p.audioClips = [{ id: 'relative', sceneId: 'scene', entryId: 'speech', assetId: 'sound', startMs: 0,
    sourceStartMs: 0, durationMs: 1000, volume: 0, isMuted: true },
    { id: 'absolute', sceneId: 'scene', assetId: 'sound', startMs: 86400000,
      sourceStartMs: 999, durationMs: 1, volume: 1, isMuted: false }];
  p.audioVolume = 0;
  return p;
}
const omitEnvelope = p => {
  const { id, createdAt, modifiedAt, revision, cloudProjectId, ...payload } = p; return payload;
};
export const payload = omitEnvelope;
const accepted = (key, make, expected) => ({ key, make, expected: expected ?? (input => payload(input)) });
export const acceptedDocuments = [
  accepted('complete', completeDocument),
  accepted('minimal-legacy', emptyDocument, input => ({ ...payload(input), audioAssets: [], audioClips: [], audioVolume: 1 })),
  accepted('explicit-null-defaults', () => ({ ...emptyDocument(), cloudProjectId: null, audioAssets: null, audioClips: null, audioVolume: null }),
    input => ({ ...payload(input), audioAssets: [], audioClips: [], audioVolume: 1 })),
  accepted('nested-null-optionals', () => {
    const p = completeDocument(); p.entries[0].characterId = null; p.entries[0].characterLinks = null;
    p.entries[0].words[0].timingSource = null; p.characters[0].portraitImageId = null; p.characters[0].portraitRegion = null;
    p.images[1].generationPrompt = null; p.images[1].previousVersionId = null;
    p.cues[0].imageId = null; p.cues[0].startAnchor = null; p.cues[0].authoredDurationMs = null;
    p.audioClips[0].entryId = null; return p;
  }, input => {
    const p = structuredClone(input); delete p.entries[0].characterId; delete p.entries[0].characterLinks;
    delete p.entries[0].words[0].timingSource; delete p.characters[0].portraitImageId; delete p.characters[0].portraitRegion;
    delete p.images[1].generationPrompt; delete p.images[1].previousVersionId; delete p.cues[0].imageId;
    delete p.cues[0].startAnchor; delete p.cues[0].authoredDurationMs; delete p.audioClips[0].entryId; return payload(p);
  }),
  accepted('audio-upper-bounds', () => {
    const p = completeDocument(); Object.assign(p.audioAssets[0], { byteCount: 104857600, durationMs: 1800000,
      sampleRate: 192000, channelCount: 8, waveform: Array(2048).fill(0.5), originalName: 'a'.repeat(256) });
    p.audioVolume = 1; return p;
  }),
];
const audioMetadata = 'Audio metadata has invalid volume, duplicate IDs or too many clips.';
const assetError = 'An audio asset has invalid timing, waveform or content-addressed file metadata.';
const clipError = 'An audio clip has an invalid source, entry, trim or volume.';
const reject = (key, mutate, error, source) => ({ key, make: completeDocument, mutate, error, source });
export const rejectedDocuments = [
  reject('audio-volume-high', p => p.audioVolume = 1.0001, audioMetadata, ['AudioTrack.swift', 97, 100]),
  reject('audio-duplicate-asset', p => p.audioAssets.push(structuredClone(p.audioAssets[0])), audioMetadata, ['AudioTrack.swift', 97, 100]),
  reject('audio-duplicate-clip', p => p.audioClips.push(structuredClone(p.audioClips[0])), audioMetadata, ['AudioTrack.swift', 97, 100]),
  reject('audio-sample-rate-high', p => p.audioAssets[0].sampleRate = 192001, assetError, ['AudioTrack.swift', 102, 111]),
  reject('audio-waveform-negative', p => p.audioAssets[0].waveform[1] = -0.01, assetError, ['AudioTrack.swift', 102, 111]),
  reject('audio-waveform-too-many', p => p.audioAssets[0].waveform = Array(2049).fill(0), assetError, ['AudioTrack.swift', 102, 111]),
  reject('audio-byte-count-high', p => p.audioAssets[0].byteCount = 104857601, assetError, ['AudioTrack.swift', 102, 111]),
  reject('audio-clip-duration-high', p => p.audioClips[1].durationMs = 2, clipError, ['AudioTrack.swift', 114, 121]),
  reject('audio-cross-scene-entry', p => p.audioClips[0].sceneId = 'empty-scene', clipError, ['AudioTrack.swift', 114, 121]),
  reject('audio-start-high', p => p.audioClips[1].startMs = 86400001, clipError, ['AudioTrack.swift', 114, 121]),
  reject('word-id-cross-entry-duplicate', p => { const e = structuredClone(p.entries[0]); e.id = 'other-speech'; e.order = 2; p.entries.push(e); },
    'Word identities must be unique throughout the project.', ['TimingEngine.swift', 44, 45]),
  reject('speaker-missing', p => p.entries[0].characterId = 'missing', 'A speaker no longer exists.', ['TimingEngine.swift', 50, 50]),
  reject('schema-future', p => p.schemaVersion = 2, 'This project needs a newer version of Scriv.', ['TimingEngine.swift', 38, 38]),
  reject('revision-negative-before-reset', p => p.revision = -1, 'Project identity, revision and dates must be valid.', ['TimingEngine.swift', 39, 40]),
  reject('missing-required-scenes', p => { delete p.scenes; }, null, ['Models.swift', 162, 162]),
  reject('null-required-date', p => p.createdAt = null, null, ['Models.swift', 161, 161]),
  reject('wrong-audio-array-type', p => p.audioAssets = {}, null, ['Models.swift', 164, 164]),
  reject('unknown-word-timing-enum', p => p.entries[0].words[0].timingSource = 'estimated', null, ['Models.swift', 18, 27]),
];
export function checkInputs() {
  assert.equal(new Set([...acceptedDocuments, ...rejectedDocuments].map(x => x.key)).size, 23);
  for (const test of [...acceptedDocuments, ...rejectedDocuments]) {
    const input = test.make(); if (test.mutate) test.mutate(input);
    const text = JSON.stringify(input); assert.deepEqual(JSON.parse(text), input);
    assert.ok(Buffer.byteLength(text) <= 65536, `${test.key} reaches the model decoder below the CLI import byte limit`);
  }
}
