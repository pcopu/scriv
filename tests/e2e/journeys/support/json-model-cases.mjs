import assert from 'node:assert/strict';
// Fixture preparation changes JSON input copies only, never installed app state.
const prefix = 'apps/mac/Tests/ScrivCoreTests/';
const timingID = prefix + 'TimingTests.swift::0010';
const anchorsID = prefix + 'CueAnchoringTests.swift::0006';
const zeroID = prefix + 'CueAnchoringTests.swift::0013';
const sourceAnchorError = "An image's resolved timing must match its source-owned script anchor.";
const coverageError = 'Image cues must have positive coverage inside the scene.';
const bytesLimit = 64 * 1024;

// Literal serialized state after the frozen CueAnchoringTests fixture's
// materialize call. The IDs/dates that Swift originally generated randomly are
// stable synthetic values. Timings below are fixture data, not a timing engine.
function anchoredFixture() {
  return {
    schemaVersion: 1, id: 'json-anchor-fixture', title: 'Untitled',
    createdAt: 1700000000000, modifiedAt: 1700000000000, revision: 0,
    scenes: [{ id: 's', title: 'Untitled scene', order: 0 }],
    entries: [
      { id: 'a', sceneId: 's', order: 0, kind: 'direction', text: 'Watch the road',
        ownedDurationMs: 1000, coverageDurationMs: 2500, color: 'purple', words: [] },
      { id: 'b', sceneId: 's', order: 1, kind: 'dialogue', text: 'Move me',
        ownedDurationMs: 1000, coverageDurationMs: 0, color: 'purple', words: [
          { id: 'b-word-0', text: 'Move', startMs: 0, endMs: 666 },
          { id: 'b-word-1', text: 'me', startMs: 666, endMs: 1000 },
        ] },
      { id: 'c', sceneId: 's', order: 2, kind: 'dialogue', text: 'Stay here',
        ownedDurationMs: 1000, coverageDurationMs: 0, color: 'purple', words: [
          { id: 'c-word-0', text: 'Stay', startMs: 0, endMs: 500 },
          { id: 'c-word-1', text: 'here', startMs: 500, endMs: 1000 },
        ] },
      { id: 'd', sceneId: 's', order: 3, kind: 'dialogue', text: 'Then leave',
        ownedDurationMs: 1000, coverageDurationMs: 0, color: 'purple', words: [
          { id: 'd-word-0', text: 'Then', startMs: 0, endMs: 444 },
          { id: 'd-word-1', text: 'leave', startMs: 444, endMs: 1000 },
        ] },
    ],
    characters: [], images: [], audioAssets: [], audioClips: [], audioVolume: 1,
    cues: [
      { id: 'parent', sceneId: 's', label: 'Parent', startMs: 0, endMs: 2500, prompt: '',
        startAnchor: { entryId: 'a', offsetMs: 0 }, authoredDurationMs: 2500 },
      { id: 'child', sceneId: 's', label: 'Child', startMs: 1000, endMs: 2500, prompt: '',
        startAnchor: { entryId: 'b', offsetMs: 0 }, authoredDurationMs: 1500 },
    ],
  };
}

function sampleFixture(saved) {
  // The actual app supplies production .example()'s words and random word IDs.
  // The CLI sample is unillustrated. Build only a JSON INPUT copy; the app's
  // installed project and its files are never modified by the runner.
  assert.equal(saved.title, 'YAM MAN');
  assert.deepEqual(saved.scenes.map(scene => scene.id), ['scene-farm']);
  assert.deepEqual(saved.entries.map(entry => entry.id), [
    'line-01', 'line-02', 'line-03', 'line-04', 'line-05', 'line-06', 'line-07',
    'direction-08', 'line-08', 'line-09', 'direction-10', 'line-10', 'line-11',
    'line-12', 'line-13', 'line-14', 'line-15', 'line-16',
  ]);
  assert.equal(saved.entries.reduce((total, entry) => total + entry.ownedDurationMs, 0), 56300);
  assert.equal(saved.cues.length, 19);
  assert.equal(saved.cues[0].id, 'cue-01a');
  assert.equal(saved.entries[0].text, 'Miyazaki, do you have any questions?');
  assert.equal(saved.entries[2].text, 'Yes. Can you pay the...? Can you...? I would like you to pay.');
  assert.equal(saved.entries[0].words[0].text, 'Miyazaki,');
  assert.equal(saved.entries[2].words[0].text, 'Yes.');
  const fixture = structuredClone(saved);
  fixture.images = [];
  for (const cue of fixture.cues) delete cue.imageId;
  for (const character of fixture.characters) {
    delete character.portraitImageId;
    delete character.portraitRegion;
  }
  fixture.revision = 0;
  assert.ok(!fixture.cloudProjectId, 'Isolated sample has no cloud project');
  return fixture;
}

export const modelCases = [
  { id: timingID, name: 'orphan cue scene', fixture: 'sample',
    error: 'An image cue refers to a missing scene.',
    mutate(project) { project.cues[0].sceneId = 'missing'; } },
  { id: timingID, name: 'word identity duplicated across entries', fixture: 'sample',
    error: 'Word identities must be unique throughout the project.',
    mutate(project) { project.entries[2].words[0].id = project.entries[0].words[0].id; } },
  { id: anchorsID, name: 'missing anchor entry', error: sourceAnchorError,
    mutate(project) { project.cues[0].startAnchor.entryId = 'missing'; } },
  { id: anchorsID, name: 'offset equals source owned duration', error: sourceAnchorError,
    mutate(project) { project.cues[0].startAnchor.offsetMs = 1000; } },
  { id: anchorsID, name: 'anchor without authored duration',
    error: 'Image timing needs both its source anchor and authored extent.',
    mutate(project) { delete project.cues[0].authoredDurationMs; } },
  { id: anchorsID, name: 'unanchored parent overlaps anchored child',
    error: 'Overlapping image cues need source-owned script anchors.',
    mutate(project) { delete project.cues[0].startAnchor; delete project.cues[0].authoredDurationMs; } },
  { id: zeroID, name: 'anchored zero projection before scene end', error: coverageError,
    mutate(project) { project.cues[0].endMs = project.cues[0].startMs; } },
  { id: zeroID, name: 'legacy zero projection before scene end', error: coverageError,
    mutate(project) {
      project.cues[0].endMs = project.cues[0].startMs;
      delete project.cues[0].startAnchor;
      delete project.cues[0].authoredDurationMs;
    } },
];

function serialized(project) {
  const text = JSON.stringify(project);
  assert.ok(Buffer.byteLength(text, 'utf8') <= bytesLimit, 'Synthetic document fits the import boundary');
  return text;
}
function authoredPayload(project) {
  const value = structuredClone(project);
  // Production JSON import intentionally resets these envelope fields only.
  for (const key of ['id', 'createdAt', 'modifiedAt', 'revision', 'cloudProjectId']) delete value[key];
  return value;
}
function sortedPackages(projects) {
  return [...projects].sort((a, b) => a.id.localeCompare(b.id));
}

export { anchoredFixture, sampleFixture, serialized, authoredPayload };
