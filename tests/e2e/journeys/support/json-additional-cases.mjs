import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { anchoredFixture, authoredPayload, serialized } from './json-model-cases.mjs';

// Exact frozen 4d14b29 JSON payloads, wrapped only in valid document containers.
// These acceptance cases do not claim an invalid-input assertion or exercise a
// parallel decoder. Production import and saved-package observations are the oracle.
const prefix = 'apps/mac/Tests/ScrivCoreTests/';
const legacyWord = { id: 'w', text: 'word', startMs: 0, endMs: 100 };
const legacyCue = { id: 'cue', sceneId: 's', label: 'A', startMs: 0, endMs: 1000, prompt: '' };
function legacyContainer() {
  const project = anchoredFixture();
  project.entries = [{ id: 'source', sceneId: 's', order: 0, kind: 'dialogue', text: 'word',
    ownedDurationMs: 1000, coverageDurationMs: 0, color: 'purple', words: [structuredClone(legacyWord)] }];
  project.cues = [];
  return project;
}
function audioContainer() {
  const project = legacyContainer();
  project.scenes[0].id = 'scene';
  project.entries = [['first', 'One', 2000], ['second', 'Two', 3000]].map(([id, text, duration], order) => ({
    id, sceneId: 'scene', order, kind: 'dialogue', text, ownedDurationMs: duration,
    coverageDurationMs: 0, color: 'purple', words: [{ id: `${id}-word`, text, startMs: 0, endMs: duration }],
  }));
  // Frozen AudioTrackTests metadata only. No audio file is fabricated, fetched,
  // installed or played. Missing-file UI behavior requires native verification.
  const data = Buffer.from('audio test bytes');
  const sha256 = createHash('sha256').update(data).digest('hex');
  project.audioAssets = [{ id: 'voice', fileName: sha256 + '.wav', sha256, byteCount: data.length,
    durationMs: 4000, sampleRate: 48000, channelCount: 2, waveform: [0, 0.25, 0.75, 1], originalName: 'Voice.wav' }];
  project.audioClips = [{ id: 'clip', sceneId: 'scene', entryId: 'second', assetId: 'voice',
    startMs: 250, sourceStartMs: 500, durationMs: 3500, volume: 1, isMuted: false }];
  return project;
}
const definitions = [
  { id: prefix + 'WordTimingEditingTests.swift::0011', name: 'legacy word remains estimated',
    assertionLines: [128], makePositive: legacyContainer,
    verify(accepted) {
      assert.deepEqual(accepted.entries[0].words, [legacyWord]);
      assert.equal(Object.hasOwn(accepted.entries[0].words[0], 'timingSource'), false,
        'The exact legacy word must not acquire an authored timing marker');
    } },
  { id: prefix + 'CueAnchoringTests.swift::0008', name: 'legacy cue retains absent ownership',
    assertionLines: [86], makePositive() {
      const project = legacyContainer(); project.cues = [structuredClone(legacyCue)]; return project;
    },
    verify(accepted) {
      assert.deepEqual(accepted.cues, [legacyCue]);
      assert.equal(Object.hasOwn(accepted.cues[0], 'startAnchor'), false);
      assert.equal(Object.hasOwn(accepted.cues[0], 'authoredDurationMs'), false);
    } },
  { id: prefix + 'CueAnchoringTests.swift::0008', name: 'anchored document roundtrip preserves ownership',
    assertionLines: [89], makePositive: anchoredFixture,
    verify(accepted, positive) {
      assert.deepEqual(accepted.cues, positive.cues);
      assert.deepEqual(accepted.entries, positive.entries);
    } },
  { id: prefix + 'AudioTrackTests.swift::0004', name: 'audio metadata document roundtrip',
    assertionLines: [44], makePositive: audioContainer,
    verify(accepted, positive) {
      assert.deepEqual(accepted.audioAssets, positive.audioAssets);
      assert.deepEqual(accepted.audioClips, positive.audioClips);
      assert.equal(accepted.audioVolume, 1);
    } },
  { id: prefix + 'AudioTrackTests.swift::0004', name: 'legacy audio omissions decode to defaults',
    assertionLines: [45, 48], makePositive() {
      const project = audioContainer();
      delete project.audioAssets; delete project.audioClips; delete project.audioVolume;
      return project;
    },
    expectedPayload: positive => ({ ...authoredPayload(positive), audioAssets: [], audioClips: [], audioVolume: 1 }),
    verify(accepted) {
      assert.deepEqual(accepted.audioAssets, []); assert.deepEqual(accepted.audioClips, []);
      assert.equal(accepted.audioVolume, 1);
    } },
];
export const additionalTests = definitions.map((fixture, index) => ({
  group: 'additional', key: `additional/${index + 1}`, id: fixture.id, name: fixture.name,
  assertionLines: fixture.assertionLines, acceptanceOnly: true,
  makePositive: fixture.makePositive, serializePositive: serialized,
  verifyPositive(accepted, positive) {
    assert.equal(accepted.revision, 0);
    assert.ok(Number.isFinite(accepted.createdAt));
    assert.equal(accepted.modifiedAt, accepted.createdAt);
    assert.ok(!accepted.cloudProjectId);
    assert.deepEqual(authoredPayload(accepted), fixture.expectedPayload ? fixture.expectedPayload(positive) : authoredPayload(positive),
      'Payload survives production decode/import/save with only explicitly expected legacy defaults');
    fixture.verify(accepted, positive);
  },
  acceptedVisible: (nodes, accepted) => nodes.some(node => node.identifier === 'workspace-project'
    && node.title === accepted.title && node.label === accepted.title + ', Projects' && node.hittable),
}));
// Portable fixture reconciliation only. This proves no native result.
assert.equal(additionalTests.length, 5);
for (const test of additionalTests) {
  const positive = test.makePositive();
  assert.deepEqual(JSON.parse(test.serializePositive(positive)), positive);
  // Legacy defaults are observed in the app, never simulated in this check.
  if (test.key !== 'additional/5') test.verifyPositive(positive, positive);
}
