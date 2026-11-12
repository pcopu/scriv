import assert from 'node:assert/strict';
import { scriptAuthoringSteps, byID, focusedEditors, keyIs } from './script-authoring-steps.mjs';

export const whitespaceWordCase = {
  group: 'whitespace-word-preservation', id: 'every-original-word-field',
  interactions: ['SCR-03', 'SCR-04', 'SCR-05'],
  sourceSlice: 'apps/mac/Tests/ScrivCoreTests/WordTimingEditingTests.swift::0009',
  sourceLines: [110, 113],
  sourceSHA256: '90425bbc8b6e97fa0ca74c6da78103ff378c68c85ee1f736d406a1b3afab19c9',
  baselineCommit: '4d14b29f4fb49891e850fa9a8e5742dc878603c8',
  route: 'import-json → Command-Return edit toggle → UITextView selectAll/insertText whole-text replacement → Escape finish → save → different-project browser reopen',
  oracles: ['literal two leading spaces, newline, repeated interior spaces and trailing space',
    'every original word field unchanged, including absent timingSource',
    'complete saved/loaded project: only text, explicit empty characterLinks, revision and modifiedAt change',
    'different-document reopen preserves complete loaded model and exact Date witnesses; startup package unchanged'],
  nativeVerified: false, retirementAllowed: false,
};
export const whitespaceReplacement = '  one\n two   three ';
// Literal constructor-derived fields from frozen fixture() lines 5–10. Fixed
// synthetic ID/dates replace only nondeterministic constructor values. The title
// remains the constructor default; omitted optional fields must remain absent.
export function whitespaceWordFixture() {
  return { schemaVersion: 1, id: 'script-whitespace-word-fixture', title: 'Untitled',
    createdAt: 1700000000000, modifiedAt: 1700000000000, revision: 0,
    scenes: [{ id: 's', title: 'Untitled scene', order: 0 }],
    entries: [{ id: 'e', sceneId: 's', order: 0, kind: 'dialogue', text: 'one two three',
      ownedDurationMs: 3000, coverageDurationMs: 0, color: 'purple', words: [
        { id: 'w1', text: 'one', startMs: 0, endMs: 600 },
        { id: 'w2', text: 'two', startMs: 1000, endMs: 1600 },
        { id: 'w3', text: 'three', startMs: 2200, endMs: 2800 },
      ] }], characters: [], images: [],
    cues: [{ id: 'c1', sceneId: 's', label: '', startMs: 0, endMs: 1500, prompt: '' },
      { id: 'c2', sceneId: 's', label: '', startMs: 1500, endMs: 3000, prompt: '' }],
    audioAssets: [], audioClips: [], audioVolume: 1 };
}
const withoutImportEnvelope = value => {
  const copy = structuredClone(value);
  for (const key of ['id', 'createdAt', 'modifiedAt', 'revision']) delete copy[key];
  return copy;
};
export async function preserveWhitespaceWords(session) {
  const step = scriptAuthoringSteps(session);
  for (const command of ['import-json', 'loaded-project', 'persisted-projects', 'text', 'keys', 'key', 'activate']) {
    assert.ok((await session.command('capabilities')).commands.includes(command), `Matching app supports ${command}`);
  }
  const startup = await step.openScript();
  assert.deepEqual(await session.command('persisted-projects'), [startup]);
  const input = whitespaceWordFixture();
  assert.deepEqual(await session.command('import-json', { text: JSON.stringify(input) }),
    { dispatched: true, projectChanged: true });
  await step.selectTab('Script');
  const before = await step.saved(project => project.title === input.title && project.id !== startup.id);
  assert.notEqual(before.id, input.id); assert.equal(before.revision, 0);
  assert.deepEqual(withoutImportEnvelope(before), withoutImportEnvelope(input),
    'Import retains every frozen constructor field and optional omission');
  const initialLoaded = await session.command('loaded-project');
  assert.deepEqual(initialLoaded.project, before);
  await step.displayed('e', input.entries[0].text, { finished: true });
  assert.ok((await session.command('keys')).some(command => keyIs(command, '\r', ['command'])),
    'Real Command-Return edit toggle is installed');
  await step.key('\r', ['command']);
  let nodes = await session.waitFor(nodes => focusedEditors(nodes).length === 1
    && byID(nodes, 'script-editor-e').some(node => node.firstResponder && node.text === input.entries[0].text));
  await step.reveal(byID(nodes, 'script-editor-e')[0], nodes);
  await session.waitFor(nodes => byID(nodes, 'script-editor-e').some(node => node.firstResponder && node.hittable && node.editable));
  assert.deepEqual(await session.command('loaded-project'), initialLoaded, 'Entering the editor preserves the entire original model');
  // Semantic whole-text replacement with an embedded newline, NOT a physical
  // Return or the distinct public-delegate Return/split command.
  await session.command('text', { target: 'script-editor-e', text: whitespaceReplacement });
  await step.waitEditor('script-editor-e', whitespaceReplacement, whitespaceReplacement.length);
  await step.finishEditor();
  await step.displayed('e', whitespaceReplacement, { finished: true });
  await step.workspaceCommand('s');
  const after = await step.saved(project => project.id === before.id
    && project.entries.find(entry => entry.id === 'e')?.text === whitespaceReplacement);
  assert.deepEqual(after.entries[0].words, before.entries[0].words,
    'Frozen 0009: every original word field, ID, text, time and absent ownership marker is unchanged');
  assert.equal(after.revision, before.revision + 1);
  const expected = structuredClone(before);
  expected.entries[0].text = whitespaceReplacement;
  // updateText reconciles legacy nil links to an explicit empty array. This is
  // an exact expected field, never a filter that hides other entry differences.
  expected.entries[0].characterLinks = [];
  expected.revision = after.revision; expected.modifiedAt = after.modifiedAt;
  assert.deepEqual(after, expected, 'Complete package matches the explicit whitespace-edit oracle');
  const loaded = await session.command('loaded-project');
  assert.deepEqual(loaded.project, after);
  assert.equal(loaded.dateReferenceTimeBits.createdAt, initialLoaded.dateReferenceTimeBits.createdAt);
  assert.match(loaded.dateReferenceTimeBits.modifiedAt, /^\d+$/);
  assert.deepEqual(loaded.dateReferenceTimeBits.images, []);
  const packages = await session.command('persisted-projects');
  assert.equal(packages.length, 2);
  assert.deepEqual(packages.filter(project => project.id !== after.id), [startup]);
  async function open(project) {
    const header = await session.waitFor(nodes => byID(nodes, 'workspace-project').some(node => node.enabled && node.hittable));
    await session.command('activate', { target: byID(header, 'workspace-project')[0].path });
    const searchNodes = await session.waitFor(nodes => nodes.some(node => node.placeholder === 'Find a project' && node.hittable));
    await session.command('text', { target: searchNodes.find(node => node.placeholder === 'Find a project' && node.hittable).path, text: project.title });
    await session.waitFor(nodes => nodes.some(node => node.text === `${project.title} · ${project.scenes.length} scene${project.scenes.length === 1 ? '' : 's'}`));
    await step.activate('Open project');
    await session.waitFor(nodes => byID(nodes, 'workspace-project').some(node => node.title === project.title && node.hittable));
    const result = await session.command('loaded-project');
    assert.deepEqual(result.project, project);
    return result;
  }
  await open(startup);
  assert.deepEqual(await open(after), loaded, 'Real different-document browser reopen preserves full model and exact Date witnesses');
  assert.deepEqual((await session.command('persisted-projects')).sort((a, b) => a.id.localeCompare(b.id)),
    packages.sort((a, b) => a.id.localeCompare(b.id)), 'Reopen leaves both full packages unchanged');
  await step.selectTab('Script');
  await step.displayed('e', whitespaceReplacement, { finished: true });
  console.log('PASS: AUT-J02/whitespace-word-preservation/every-original-word-field');
}
