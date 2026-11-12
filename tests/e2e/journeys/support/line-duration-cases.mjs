import assert from 'node:assert/strict';
import { anchoredFixture, sampleFixture } from './json-model-cases.mjs';

// AUT-J04 literal input/oracle data only. No installed-model mutation, Swift
// test invocation, parallel timing engine, or native-pass claim.
export const baselineCommit = '4d14b29f4fb49891e850fa9a8e5742dc878603c8';
const prefix = 'apps/mac/Tests/ScrivCoreTests/';
export const lineDurationStatus = Object.freeze({
  journey: 'AUT-J04', portion: 'direction-owned-duration', status: 'prepared-native-unverified',
  nativeVerified: false, retirementAllowed: false,
  scriptRoute: 'ScriptEntryRow.durationButton > ScriptScreenController.editDuration > UIAlertController',
  scriptBlocker: 'Apply/Cancel have no verified supported Catalyst public activation route.',
  sheetRoute: 'Layers direction block > secondary UIMenu > ImageCoverageViewController(entry:)',
  sheetBlocker: 'Requires the separately audited narrow menu-action scope and matching native proof; menu observation alone is insufficient.',
  supportedScope: 'Embedded Layers direction UIButton only; never dialogue or an expanded Layers modal.',
  prohibitedWorkarounds: ['private UIAlertAction/UIAction handlers', 'direct store/model calls',
    'native-accessibility helper retry after Library Validation denial', 'production UI refactor solely for testing'],
});
export const frozenSources = [
  ['TimingTests.swift', '26b6b40639a22d73269ab511e4d7472d63001f0df2adb1cb9dfc568936ffca9e'],
  ['EditingTests.swift', 'd3f69339fc5d303713696c3ae18ea21bba5882ad89f376ebf1dc18d7e8f1a1de'],
  ['CueAnchoringTests.swift', 'bd5c8bb7516f83e4ca54cf72599e792165a729818a8873ffabd6a5e7f7c920c4'],
  ['WordTimingEditingTests.swift', '90425bbc8b6e97fa0ca74c6da78103ff378c68c85ee1f736d406a1b3afab19c9'],
].map(([source, sha256]) => ({ source: prefix + source, sha256 }));

function project(id, sceneTitle = 'Untitled scene') {
  return { schemaVersion: 1, id, title: 'Untitled', createdAt: 1700000000000,
    modifiedAt: 1700000000000, revision: 0,
    scenes: [{ id: 's', title: sceneTitle, order: 0 }], entries: [], characters: [],
    images: [], cues: [], audioAssets: [], audioClips: [], audioVolume: 1 };
}
function direction(id, order, text, ownedDurationMs, coverageDurationMs) {
  return { id, sceneId: 's', order, kind: 'direction', text, ownedDurationMs,
    coverageDurationMs, color: 'purple', words: [] };
}
function dialogue(id, order, text, duration, words) {
  return { id, sceneId: 's', order, kind: 'dialogue', text,
    ownedDurationMs: duration, coverageDurationMs: 0, color: 'purple', words };
}
function word(id, text, startMs, endMs, authored = false) {
  return { id, text, startMs, endMs, ...(authored ? { timingSource: 'authored' } : {}) };
}
function cue(id, startMs, endMs) {
  return { id, sceneId: 's', label: '', startMs, endMs, prompt: '' };
}
// Literal fixture outputs, not a JavaScript retiming implementation. Optional
// legacy characterLinks/startAnchor/authoredDurationMs remain ABSENT until an
// operation actually establishes them. No comparison silently normalizes them.
export function editingFixture() {
  const value = project('line-duration-editing', 'INT. ROOM');
  value.entries = [
    direction('note', 0, 'Keep watching', 0, 2500),
    dialogue('a', 1, 'One two', 1000, [word('a-0', 'One', 0, 500), word('a-1', 'two', 500, 1000)]),
    dialogue('b', 2, 'Three four', 1000, [word('b-0', 'Three', 0, 555), word('b-1', 'four', 555, 1000)]),
    direction('later', 3, 'Look away', 0, 1000),
    dialogue('c', 4, 'Five six', 1000, [word('c-0', 'Five', 0, 571), word('c-1', 'six', 571, 1000)]),
  ];
  value.cues = [cue('first', 0, 1000), cue('second', 1000, 3000)];
  return value;
}
export function zeroOwnedFixture() {
  const value = project('line-duration-zero-owned', 'INT. ROOM');
  value.entries = [direction('a', 0, 'Turn', 0, 3000), direction('b', 1, 'Look', 0, 2000),
    dialogue('c', 2, 'Hello there', 3000, [word('c-0', 'Hello', 0, 1500), word('c-1', 'there', 1500, 3000)])];
  value.cues = [cue('picture', 0, 3000)];
  return value;
}
export function authoredFixture() {
  const value = project('line-duration-authored');
  value.entries = [dialogue('e', 0, 'one two three', 3000, [
    word('w1', 'one', 0, 600), word('w2', 'two', 1000, 1600), word('w3', 'three', 2200, 2800),
  ])];
  value.cues = [cue('c1', 0, 1500), cue('c2', 1500, 3000)];
  return value;
}
function terminalFixture() {
  const value = editingFixture();
  value.entries.push(direction('last-note', 5, 'Fade', 0, 1000));
  return value;
}
function editedAuthoredFixture() {
  // Exact state after frozen lines 100–103, not evidence those edits ran.
  const value = authoredFixture();
  value.entries[0].text = 'one new two three';
  value.entries[0].words = [word('w1', 'one', 0, 550), word('new-word', 'new', 550, 1100),
    word('w2', 'two', 1100, 1550, true), word('w3', 'three', 1550, 3000)];
  return value;
}
function pinnedFixture() {
  const value = authoredFixture();
  value.entries[0].words[0].timingSource = 'authored';
  value.entries[0].words[2].timingSource = 'authored';
  return value;
}
function populatedMetadataFixture() {
  // Supplemental acceptance only. These inert metadata records are not the
  // frozen reorder/word-timing scenario and never install or fetch media bytes.
  const value = anchoredFixture();
  value.images = [
    { id: 'image1', version: 1, fileName: 'one.png', sha256: 'a'.repeat(64),
      byteCount: 12, mimeType: 'image/png', characterIds: [], prompt: '', createdAt: 1700000000000 },
    { id: 'image2', version: 2, fileName: 'two.png', sha256: 'b'.repeat(64),
      byteCount: 15, mimeType: 'image/png', characterIds: [], prompt: '', createdAt: 1700000000000,
      previousVersionId: 'image1' },
  ];
  value.cues[1].imageId = 'image1'; value.cues[1].prompt = 'Keep this version';
  value.audioAssets = [{ id: 'audio', fileName: 'c'.repeat(64) + '.wav', sha256: 'c'.repeat(64),
    byteCount: 1000, durationMs: 2000, sampleRate: 48000, channelCount: 1,
    waveform: [0, 0.4, 0], originalName: 'Voice' }];
  value.audioClips = [{ id: 'clip', sceneId: 's', entryId: 'b', assetId: 'audio',
    startMs: 0, sourceStartMs: 100, durationMs: 900, volume: 1, isMuted: false }];
  return value;
}
function sampleInput(sample) {
  // Scriv's actual isolated sample supplies its randomly generated word IDs.
  // This constructor is input-copy preparation only, never installed state.
  assert.deepEqual(sample.images, []);
  assert.deepEqual(sample.audioAssets, []); assert.deepEqual(sample.audioClips, []);
  assert.ok(sample.cues.every(value => !Object.hasOwn(value, 'imageId')));
  assert.ok(sample.entries.every(value => !Object.hasOwn(value, 'characterLinks')));
  assert.ok(sample.cues.every(value => !Object.hasOwn(value, 'startAnchor')
    && !Object.hasOwn(value, 'authoredDurationMs')));
  const value = sampleFixture(sample);
  assert.deepEqual(value.entries.map(entry => entry.ownedDurationMs),
    [3200, 2400, 7600, 5300, 1400, 2400, 3000, 0, 5000, 2400, 0, 2800, 2800, 1600, 9800, 2600, 1800, 2200]);
  return value;
}
const anchors = [
  ['cue-01a', 'line-01', 0], ['cue-02a', 'line-02', 0], ['cue-03a', 'line-03', 0],
  ['cue-04a', 'line-04', 0], ['cue-05a', 'line-05', 0], ['cue-06a', 'line-06', 0],
  ['cue-07a', 'line-07', 0], ['cue-08a', 'line-08', 0], ['cue-08b', 'line-08', 1400],
  ['cue-08c', 'line-08', 3800], ['cue-09a', 'line-09', 0], ['cue-10a', 'line-10', 0],
  ['cue-10b', 'line-10', 1500], ['cue-11a', 'line-11', 0], ['cue-12a', 'line-12', 0],
  ['cue-13a', 'line-13', 0], ['cue-14a', 'line-14', 0], ['cue-15a', 'line-15', 0],
  ['cue-16a', 'line-16', 0],
];
const sampleCuts = {
  grown: [0,3200,5600,13200,18500,19900,22300,25300,26700,29100,30300,33700,35200,36500,39300,40900,50700,53300,55100,57300],
  shrunk: [0,3200,5600,13200,18500,19900,22300,25300,26700,29100,30300,31700,33200,34500,37300,38900,48700,51300,53100,55300],
};
// All values are literal expected model patches. Applying these patches to an
// input COPY is an equality oracle, never a copy of TimingEngine's algorithm.
function sampleCuePatches(cuts) {
  return anchors.map(([id, entryId, offsetMs], index) => ({ id,
    startMs: cuts[index], endMs: cuts[index + 1],
    startAnchor: { entryId, offsetMs }, authoredDurationMs: cuts[index + 1] - cuts[index] }));
}
const target = (source, ordinal) => `${prefix}${source}.swift::${ordinal}`;
const candidates = [
  { key: 'sample-direction', baselineID: target('TimingTests', '0004'), scope: 'candidate',
    assertionLines: [28,29,30,31,33,34], makeInput: sampleInput, needsStartupSample: true,
    entryID: 'line-09', originalSeconds: '2.400', steps: [
      { seconds: '3.4', display: '3.400', runtimeMs: 57300, starts: { 'line-10': 33700 },
        entries: [{ id: 'line-09', ownedDurationMs: 3400, coverageDurationMs: 6200 },
          { id: 'direction-08', coverageDurationMs: 5567 }], cues: sampleCuePatches(sampleCuts.grown) },
      { seconds: '1.4', display: '1.400', runtimeMs: 55300, starts: { 'line-10': 31700 },
        entries: [{ id: 'line-09', ownedDurationMs: 1400, coverageDurationMs: 4200 },
          { id: 'direction-08', coverageDurationMs: 5233 }], cues: sampleCuePatches(sampleCuts.shrunk) },
    ] },
  { key: 'zero-owned-prefix', baselineID: target('TimingTests', '0005'), scope: 'candidate',
    assertionLines: [43,44,45,46], makeInput: zeroOwnedFixture, entryID: 'a', originalSeconds: '0.000', steps: [
      { seconds: '1', display: '1.000', runtimeMs: 4000, starts: { b: 1000 },
        entries: [{ id: 'a', ownedDurationMs: 1000, coverageDurationMs: 4000 }],
        cues: [{ id: 'picture', startMs: 1000, endMs: 4000, startAnchor: { entryId: 'c', offsetMs: 0 }, authoredDurationMs: 3000 }] },
    ] },
  { key: 'terminal-zero-owned', baselineID: target('EditingTests', '0013'), scope: 'candidate',
    assertionLines: [147,148,149,150], makeInput: terminalFixture, entryID: 'last-note', originalSeconds: '0.000', steps: [
      { seconds: '0.7', display: '0.700', runtimeMs: 3700,
        entries: [{ id: 'last-note', ownedDurationMs: 700, coverageDurationMs: 1700 }],
        cues: [{ id: 'first', startAnchor: { entryId: 'a', offsetMs: 0 }, authoredDurationMs: 1000 },
          { id: 'second', endMs: 3700, startAnchor: { entryId: 'b', offsetMs: 0 }, authoredDurationMs: 2700 }] },
    ] },
  { key: 'anchored-zero-return', baselineID: target('CueAnchoringTests', '0009'), scope: 'candidate',
    assertionLines: [94,95,96,97,99,100,101,102], makeInput: anchoredFixture, entryID: 'a', originalSeconds: '1.000', steps: [
      { seconds: '0', display: '0.000', runtimeMs: 3000,
        entries: [{ id: 'a', ownedDurationMs: 0, coverageDurationMs: 1500 }],
        cues: [{ id: 'parent', endMs: 1500, authoredDurationMs: 1500 }, { id: 'child', startMs: 0, endMs: 1500 }] },
      { seconds: '1', display: '1.000', runtimeMs: 4000,
        entries: [{ id: 'a', ownedDurationMs: 1000, coverageDurationMs: 2500 }],
        cues: [{ id: 'parent', endMs: 2500, authoredDurationMs: 2500 }, { id: 'child', startMs: 1000, endMs: 2500 }] },
    ] },
  { key: 'authored-word-survives', baselineID: target('WordTimingEditingTests', '0008'), scope: 'partial',
    assertionLines: [105,107,108], uncoveredLines: [100,102,103], makeInput: editedAuthoredFixture,
    entryID: 'e', originalSeconds: '3.000', steps: [
      { seconds: '4', display: '4.000', runtimeMs: 4000,
        entries: [{ id: 'e', ownedDurationMs: 4000, words: [word('w1', 'one', 0, 550), word('new-word', 'new', 550, 1100),
          word('w2', 'two', 1100, 1550, true), word('w3', 'three', 1550, 4000)] }],
        cues: [{ id: 'c1', endMs: 2000, startAnchor: { entryId: 'e', offsetMs: 0 }, authoredDurationMs: 2000 },
          { id: 'c2', startMs: 2000, endMs: 4000, startAnchor: { entryId: 'e', offsetMs: 2000 }, authoredDurationMs: 2000 }] },
    ] },
  { key: 'too-short-dialogue', baselineID: target('EditingTests', '0008'), scope: 'partial',
    assertionLines: [88,89], uncoveredLines: [82,83,84,85,86,87], makeInput: editingFixture,
    entryID: 'a', originalSeconds: '1.000', rejection: { seconds: '0.001',
      error: 'Duration must be between 2ms and one hour.' } },
  { key: 'coverage-overflow', baselineID: target('EditingTests', '0008'), scope: 'partial',
    assertionLines: [93,94], uncoveredLines: [82,83,84,85,86,87],
    makeInput() { const value = editingFixture(); value.entries[0].coverageDurationMs = 86400000; return value; },
    entryID: 'a', originalSeconds: '1.000', rejection: { seconds: '2',
      error: 'Direction coverage must extend forward beyond its owned time and contain no spoken words.' } },
  { key: 'pinned-word-rejects-shrink', baselineID: target('WordTimingEditingTests', '0010'), scope: 'partial',
    assertionLines: [123,124], uncoveredLines: [117,119,120,121], makeInput: pinnedFixture,
    entryID: 'e', originalSeconds: '3.000', rejection: { seconds: '2.5',
      error: 'This edit would overwrite authored word timing. Adjust word times or increase the line duration first.' } },
  { key: 'image-erasure-rejected', baselineID: target('CueAnchoringTests', '0010'), scope: 'partial',
    assertionLines: [108,109], uncoveredLines: [106],
    makeInput() { const value = anchoredFixture(); value.cues[0].authoredDurationMs = 500; value.cues[0].endMs = 500; return value; },
    entryID: 'a', originalSeconds: '1.000', rejection: { seconds: '0',
      error: 'This duration would erase an image placement. Move or remove that image first; its identity and authored coverage have been preserved.' } },
  { key: 'populated-metadata-preserved', baselineID: null, scope: 'additional-acceptance', assertionLines: [],
    makeInput: populatedMetadataFixture, entryID: 'a', originalSeconds: '1.000', steps: [
      { seconds: '2', display: '2.000', runtimeMs: 5000,
        entries: [{ id: 'a', ownedDurationMs: 2000, coverageDurationMs: 3500 }],
        cues: [{ id: 'parent', endMs: 3500, authoredDurationMs: 3500 },
          { id: 'child', startMs: 2000, endMs: 3500 }] },
    ] },
];
const dialogueKeys = new Set(['authored-word-survives', 'too-short-dialogue',
  'coverage-overflow', 'pinned-word-rejects-shrink']);
export const lineDurationCases = candidates.map(test => ({ ...test,
  entryKind: dialogueKeys.has(test.key) ? 'dialogue' : 'direction',
  status: dialogueKeys.has(test.key) ? 'unsupported-dialogue-alert' : 'prepared-native-unverified',
  nativeVerified: false, retirementAllowed: false,
  ...(dialogueKeys.has(test.key) ? { blocker: lineDurationStatus.scriptBlocker } : {}),
  ...(test.rejection && !dialogueKeys.has(test.key) ? {
    observationRequirement: 'Requires the separately guarded read-only Owned duration sheet observer, including an optional terminal validation alert; no transient-between-observations claim.',
  } : {}),
  ...(test.needsStartupSample ? {
    historyDeferred: 'Sample restoration bootstraps random character-link identities; no partial or normalized Undo/Redo equality is substituted.',
  } : {}),
}));
export const directionDurationCases = lineDurationCases.filter(test => test.entryKind === 'direction');
export const unsupportedDialogueCases = lineDurationCases.filter(test => test.entryKind === 'dialogue');
export const invalidDirectionSeconds = ['', '-1', '3600.001', '1.2.3', 'NaN', 'inf', '-inf', '1e309'];

// Literal restored legacy ownership, not a cue resolver. Character catalogs are
// empty for these four non-sample success fixtures, so bootstrap adds [] exactly.
const legacyHistoryCues = {
  'zero-owned-prefix': [{ id: 'picture', startAnchor: { entryId: 'c', offsetMs: 0 }, authoredDurationMs: 3000 }],
  'terminal-zero-owned': [{ id: 'first', startAnchor: { entryId: 'a', offsetMs: 0 }, authoredDurationMs: 1000 },
    { id: 'second', startAnchor: { entryId: 'b', offsetMs: 0 }, authoredDurationMs: 2000 }],
};
export function expectedRestoredContent(test, snapshot) {
  assert.equal(test.needsStartupSample, undefined, 'Sample history is not approximated');
  assert.deepEqual(snapshot.characters, [], 'Only empty catalogs have a literal empty-link history oracle');
  const value = content(snapshot);
  for (const entry of value.entries) {
    assert.ok(!Object.hasOwn(entry, 'characterLinks') || entry.characterLinks.length === 0);
    entry.characterLinks = [];
  }
  for (const patch of legacyHistoryCues[test.key] ?? []) {
    const cue = value.cues.find(cue => cue.id === patch.id);
    assert.ok(cue);
    if (!Object.hasOwn(cue, 'startAnchor')) Object.assign(cue, structuredClone(patch));
  }
  assert.ok(value.cues.every(cue => cue.startAnchor && Number.isInteger(cue.authoredDurationMs)));
  return value;
}

export function content(projectValue) {
  const value = structuredClone(projectValue);
  delete value.revision; delete value.modifiedAt;
  return value;
}
export function expectedContent(before, step) {
  const value = content(before);
  for (const field of ['entries', 'cues']) for (const patch of step[field] ?? []) {
    const item = value[field].find(item => item.id === patch.id);
    assert.ok(item, `Literal expected ${field} patch targets an existing fixture identity`);
    Object.assign(item, structuredClone(patch));
  }
  return value;
}

export function verifyLineDurationSaved(before, after, step) {
  assert.equal(after.revision, before.revision + 1, 'One accepted duration edit creates one revision');
  assert.ok(Number.isFinite(after.modifiedAt));
  assert.deepEqual(content(after), expectedContent(before, step),
    'Complete model equals the literal oracle; only revision/modifiedAt are excluded');
  assert.deepEqual(after.images, before.images, 'Image versions and exact identities survive source resizing');
  assert.deepEqual(after.audioAssets, before.audioAssets, 'All audio asset metadata survives source resizing');
  assert.deepEqual(after.audioClips, before.audioClips, 'Every relative audio clip record survives source resizing');
  assert.equal(after.audioVolume, before.audioVolume);
}

// Portable structure checks deliberately do not validate Swift behavior.
export function auditLineDurationFixtures() {
  assert.equal(new Set(lineDurationCases.map(test => test.key)).size, 10);
  for (const test of lineDurationCases) {
    assert.equal(test.status, test.entryKind === 'dialogue' ? 'unsupported-dialogue-alert' : 'prepared-native-unverified');
    assert.equal(test.nativeVerified, false); assert.equal(test.retirementAllowed, false);
    assert.ok(test.steps?.length > 0 || test.rejection);
    if (test.needsStartupSample) continue;
    const input = test.makeInput();
    assert.ok(Buffer.byteLength(JSON.stringify(input)) <= 64 * 1024);
    assert.equal(input.entries.find(entry => entry.id === test.entryID)?.kind, test.entryKind);
    assert.ok(input.entries.every(entry => !Object.hasOwn(entry, 'characterLinks')));
    if (test.scope !== 'additional-acceptance') {
      assert.deepEqual(input.audioAssets, []); assert.deepEqual(input.audioClips, []);
    }
    const untouched = structuredClone(input);
    let expected = input;
    for (const step of test.steps ?? []) expected = expectedContent(expected, step);
    assert.deepEqual(input, untouched, 'Constructing literal oracles never changes fixture inputs');
    assert.deepEqual(expected.entries.flatMap(entry => entry.words.map(value => value.id)),
      input.entries.flatMap(entry => entry.words.map(value => value.id)), 'All literal successful cases conserve word identity/order');
    assert.deepEqual(expected.images, input.images);
  }
  assert.equal(directionDurationCases.length, 6);
  assert.equal(unsupportedDialogueCases.length, 4);
  assert.equal(directionDurationCases.filter(test => test.scope === 'candidate').length, 4);
  return { ...lineDurationStatus, frozenSources, cases: lineDurationCases.map(({ makeInput, ...test }) => test) };
}
