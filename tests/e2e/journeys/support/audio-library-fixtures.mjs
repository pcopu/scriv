import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';

export const audioByteLimit = 128044;
export const syntheticFilename = 'Synthetic.wav';
export const draftBaseline = 'apps/catalyst/Tests/AudioTimingDraftTests.swift';
export const trackBaseline = 'apps/mac/Tests/ScrivCoreTests/AudioTrackTests.swift';

// Serialized INPUT fixture, not a parallel app model. The scene, script, word
// times and cues are literal frozen AudioTimingDraftTests fixture values. Only
// its fake audio bytes/metadata are omitted so the real importer supplies them.
export function audioProjectFixture() {
  return {
    schemaVersion: 1, id: 'audio-journey-input', title: 'Synthetic audio journey',
    createdAt: 1700000000000, modifiedAt: 1700000000000, revision: 0,
    scenes: [{ id: 'scene', title: 'Untitled scene', order: 0 }],
    entries: [
      { id: 'line1', sceneId: 'scene', order: 0, kind: 'dialogue', text: 'one two three',
        ownedDurationMs: 3000, coverageDurationMs: 0, color: 'purple', words: [
          { id: 'w1', text: 'one', startMs: 0, endMs: 600 },
          { id: 'w2', text: 'two', startMs: 1000, endMs: 1600 },
          { id: 'w3', text: 'three', startMs: 2200, endMs: 2800 },
        ] },
      { id: 'line2', sceneId: 'scene', order: 1, kind: 'dialogue', text: 'four',
        ownedDurationMs: 2000, coverageDurationMs: 0, color: 'purple',
        words: [{ id: 'line2-word', text: 'four', startMs: 0, endMs: 2000 }] },
    ],
    characters: [], images: [],
    cues: [
      { id: 'image1', sceneId: 'scene', label: '', startMs: 0, endMs: 3000, prompt: '' },
      { id: 'image2', sceneId: 'scene', label: '', startMs: 3000, endMs: 5000, prompt: '' },
    ],
    audioAssets: [], audioClips: [], audioVolume: 1,
  };
}

// Independent direction-choice acceptance variant, not the frozen ::0003
// fixture: line2 changes kind, removes dialogue words and sets direction
// coverage to its owned 2000 ms. The JSON decoder does not apply ScriptEntry's
// initializer floor; TimingEngine.validate requires coverage >= owned time.
// Its order/owned duration remain literal, so it starts at 3000 ms after line1.
export function audioDirectionProjectFixture() {
  const project = audioProjectFixture();
  project.title = 'Synthetic audio direction attachment';
  project.entries[1].kind = 'direction'; project.entries[1].words = [];
  project.entries[1].coverageDurationMs = 2000;
  return project;
}

// Generate new synthetic samples in memory. Never read a recording or file.
// Four one-second plateaus make the expected measured peaks explicit, without
// copying/reimplementing AudioWaveformAccumulator or an audio decoder.
export function syntheticPCM({ silence = false, milliseconds = 4000 } = {}) {
  assert.ok(Number.isInteger(milliseconds) && milliseconds > 0 && milliseconds <= 4001);
  const frames = 16 * milliseconds;
  const bytes = Buffer.alloc(44 + frames * 2);
  bytes.write('RIFF', 0); bytes.writeUInt32LE(bytes.length - 8, 4); bytes.write('WAVE', 8);
  bytes.write('fmt ', 12); bytes.writeUInt32LE(16, 16); bytes.writeUInt16LE(1, 20);
  bytes.writeUInt16LE(1, 22); bytes.writeUInt32LE(16000, 24); bytes.writeUInt32LE(32000, 28);
  bytes.writeUInt16LE(2, 32); bytes.writeUInt16LE(16, 34); bytes.write('data', 36);
  bytes.writeUInt32LE(frames * 2, 40);
  const levels = [0, 8192, 24576, 32767];
  for (let frame = 0; frame < frames; frame++) {
    const amplitude = silence ? 0 : levels[Math.min(3, Math.floor(frame / 16000))];
    bytes.writeInt16LE(frame % 2 ? -amplitude : amplitude, 44 + frame * 2);
  }
  return bytes;
}
export function verifyImportedAsset(asset, bytes, { silence = false } = {}) {
  const digest = createHash('sha256').update(bytes).digest('hex');
  assert.match(asset.id, /^[0-9A-Fa-f-]{36}$/);
  assert.deepEqual(Object.keys(asset).sort(), ['id', 'fileName', 'sha256', 'byteCount', 'durationMs',
    'sampleRate', 'channelCount', 'waveform', 'originalName'].sort());
  assert.equal(asset.sha256, digest);
  assert.equal(asset.fileName, digest + '.wav', 'Content-addressed metadata matches the exact synthetic bytes');
  assert.equal(asset.byteCount, bytes.length);
  assert.equal(asset.durationMs, 4000, 'The actual AVAudioFile decoder measured four seconds');
  assert.equal(asset.sampleRate, 16000); assert.equal(asset.channelCount, 1);
  assert.equal(asset.originalName, syntheticFilename);
  assert.equal(asset.waveform.length, 512);
  const expected = silence ? [0, 0, 0, 0] : [0, 0.25, 0.75, 32767 / 32768];
  for (let quarter = 0; quarter < 4; quarter++) {
    for (const peak of asset.waveform.slice(quarter * 128, (quarter + 1) * 128)) {
      assert.ok(Number.isFinite(peak) && Math.abs(peak - expected[quarter]) < 0.0000001,
        'Every persisted peak matches its known synthetic PCM plateau');
    }
  }
}
export function invalidAudioRequests() {
  const valid = syntheticPCM();
  const base64 = valid.toString('base64');
  const request = { base64, attachment: 'scene' };
  const malformed = (name, mutate) => {
    const bytes = Buffer.from(valid); mutate(bytes);
    return { name, request: { ...request, base64: bytes.toString('base64') } };
  };
  return [
    { name: 'missing-input', request: {} },
    { name: 'nonstring-input', request: { base64: 1, attachment: 'scene' } },
    { name: 'null-input', request: { base64: null, attachment: 'scene' } },
    { name: 'missing-attachment', request: { base64 } },
    { name: 'unknown-attachment', request: { ...request, attachment: 'entry-id' } },
    ...['path', 'url', 'filename', 'entryId', 'projectID'].map(key => ({ name: `extra-${key}`, request: { ...request, [key]: 'not-an-accepted-input' } })),
    { name: 'empty-base64', request: { ...request, base64: '' } },
    { name: 'invalid-base64', request: { ...request, base64: 'not base64!' } },
    { name: 'base64-whitespace', request: { ...request, base64: base64 + '\n' } },
    { name: 'truncated-header', request: { ...request, base64: valid.subarray(0, 43).toString('base64') } },
    { name: 'zero-frames', request: { ...request, base64: valid.subarray(0, 44).toString('base64') } },
    { name: 'over-four-seconds', request: { ...request, base64: syntheticPCM({ milliseconds: 4001 }).toString('base64') } },
    { name: 'trailing-byte', request: { ...request, base64: Buffer.concat([valid, Buffer.from([0])]).toString('base64') } },
    malformed('not-riff', bytes => bytes.write('RF64', 0)),
    malformed('riff-length', bytes => bytes.writeUInt32LE(bytes.length, 4)),
    malformed('not-wave', bytes => bytes.write('MP3 ', 8)),
    malformed('extended-format', bytes => bytes.writeUInt32LE(18, 16)),
    malformed('float-format', bytes => bytes.writeUInt16LE(3, 20)),
    malformed('stereo-format', bytes => bytes.writeUInt16LE(2, 22)),
    malformed('other-sample-rate', bytes => bytes.writeUInt32LE(48000, 24)),
    malformed('wrong-byte-rate', bytes => bytes.writeUInt32LE(31999, 28)),
    malformed('wrong-block-align', bytes => bytes.writeUInt16LE(4, 32)),
    malformed('wrong-bit-depth', bytes => bytes.writeUInt16LE(8, 34)),
    malformed('other-data-chunk', bytes => bytes.write('LIST', 36)),
    malformed('wrong-data-length', bytes => bytes.writeUInt32LE(2, 40)),
  ];
}
export const invalidTimingDrafts = [
  ...['', 'nan', 'inf', '-0.1', '1e200', '5.001', 'not time', '4.000'].map(source =>
    ({ name: `source-${source || 'empty'}`, source, duration: '2.500', offset: '0.250' })),
  { name: 'trim-overruns-source', source: '3.900', duration: '0.200', offset: '0.250' },
  { name: 'zero-duration', source: '0.500', duration: '0.000', offset: '0.250' },
  { name: 'rounded-zero-duration', source: '0.500', duration: '0.0004', offset: '0.250' },
  { name: 'nan-offset', source: '0.500', duration: '2.500', offset: 'nan' },
  { name: 'negative-offset', source: '0.500', duration: '2.500', offset: '-0.1' },
  { name: 'oversized-offset', source: '0.500', duration: '2.500', offset: '86400.001' },
];
// Only production-authored revision/modifiedAt change during one user edit.
export function stableContent(project) {
  const copy = structuredClone(project); delete copy.revision; delete copy.modifiedAt; return copy;
}
export function editedContent(project, change) {
  const copy = stableContent(project); change(copy); return copy;
}

// Portable fixture reconciliation only; this is never a native pass.
assert.equal(syntheticPCM().length, audioByteLimit);
assert.equal(syntheticPCM().readUInt32LE(40), 128000);
assert.equal(audioProjectFixture().entries[0].words[2].endMs, 2800);
assert.deepEqual(audioProjectFixture().entries.map(entry => entry.ownedDurationMs), [3000, 2000]);
assert.equal(invalidAudioRequests().length, 29);
for (const test of invalidAudioRequests()) assert.ok(Buffer.byteLength(JSON.stringify(test.request)) < 1_048_576);

const directionFixture = audioDirectionProjectFixture();
const directionExpected = audioProjectFixture();
directionExpected.title = 'Synthetic audio direction attachment';
directionExpected.entries[1] = { ...directionExpected.entries[1], kind: 'direction', words: [], coverageDurationMs: 2000 };
assert.deepEqual(directionFixture, directionExpected, 'Only the documented direction-choice adaptation changes');
