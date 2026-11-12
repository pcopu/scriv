import assert from 'node:assert/strict';
import { ScrivSession } from '../../../../cli/scriv.mjs';
import { scriptAuthoringSteps, byID, focusedEditors, keyIs } from './script-authoring-steps.mjs';
import { exactSplitFixtures, exactSplitInput } from './script-exact-split-cases.mjs';

const sorted = values => [...values].sort((a, b) => a.id.localeCompare(b.id));
const importContent = project => {
  const value = structuredClone(project);
  for (const field of ['id', 'createdAt', 'modifiedAt', 'revision']) delete value[field];
  return value;
};
const uuid = value => assert.match(value, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i);

// Complete literal postcondition. Observation supplies generated identities only;
// text, timing, links, ordering, anchors and every other model field are expected.
export function assertExactSplit(test, before, after, rightID) {
  uuid(rightID);
  const oldIDs = new Set([before.id, ...before.scenes.map(value => value.id),
    ...before.entries.flatMap(value => [value.id, ...value.words.map(word => word.id), ...(value.characterLinks ?? []).map(link => link.id)]),
    ...before.characters.map(value => value.id), ...before.cues.map(value => value.id)]);
  assert.ok(!oldIDs.has(rightID), 'Right entry has a fresh identity');
  const bindings = new Map(); const fresh = new Set([rightID]);
  function bind(expected, actual) {
    assert.ok(actual, 'Every expected word/link is present');
    if (!expected.id.startsWith('$')) return structuredClone(expected);
    uuid(actual.id);
    assert.ok(!oldIDs.has(actual.id) && !fresh.has(actual.id), 'Fragment identity is fresh and distinct from every source/new identity');
    assert.ok(!bindings.has(expected.id), 'Each symbolic fresh identity is bound once');
    fresh.add(actual.id); bindings.set(expected.id, actual.id);
    return { ...expected, id: actual.id };
  }
  const expected = structuredClone(before);
  expected.entries = test.texts.map((text, index) => {
    const observed = after.entries[index];
    return { ...structuredClone(before.entries[0]), id: index ? rightID : 'a', order: index,
      text, ownedDurationMs: test.durations[index],
      words: test.resultWords[index].map((word, position) => bind(word, observed?.words[position])),
      characterLinks: (test.resultLinks?.[index] ?? []).map((link, position) => bind(link, observed?.characterLinks?.[position])) };
  });
  expected.cues[0].startAnchor = { entryId: test.cueOwner === 'right' ? rightID : 'a', offsetMs: test.cueOffset };
  expected.cues[0].authoredDurationMs = 1300;
  if (test.audio) { expected.audioClips[0].entryId = rightID; expected.audioClips[0].startMs = 782; }
  expected.revision = before.revision + 1;
  assert.ok(Number.isFinite(after.modifiedAt) && after.modifiedAt >= before.modifiedAt);
  expected.modifiedAt = after.modifiedAt;
  assert.deepEqual(after, expected, 'Entire split model matches literal frozen expectations; no entry/optional fields are filtered');
  assert.equal(after.entries.map(value => value.text).join(''), before.entries[0].text);
  assert.equal(after.entries.reduce((sum, value) => sum + value.ownedDurationMs, 0), 3000);
  assert.ok(after.entries.every(value => value.ownedDurationMs >= 1));
  const words = after.entries.flatMap(value => value.words);
  assert.equal(new Set(words.map(value => value.id)).size, words.length);
  for (const entry of after.entries) {
    let end = 0;
    for (const word of entry.words) {
      assert.ok(Number.isInteger(word.startMs) && Number.isInteger(word.endMs)
        && word.startMs >= end && word.endMs > word.startMs && word.endMs <= entry.ownedDurationMs);
      end = word.endMs;
    }
  }
  if (!test.resultWords.flat().some(value => value.id.startsWith('$'))) {
    assert.deepEqual(words.map(value => value.id), before.entries[0].words.map(value => value.id));
  }
  if (test.audio) {
    assert.deepEqual(after.audioAssets, before.audioAssets);
    // These literal bounds prove the frozen placement is unchanged without
    // calling another implementation of AudioTimeline or accessing audio bytes.
    assert.equal(before.audioClips[0].startMs, 1600);
    assert.equal(after.entries[0].ownedDurationMs + after.audioClips[0].startMs, 1600);
    assert.equal(1600 + after.audioClips[0].durationMs, 2600);
    assert.equal(after.audioClips[0].sourceStartMs, 300);
    assert.ok(2600 <= 3000 && 300 + 1000 <= after.audioAssets[0].durationMs);
  }
  return expected;
}

async function runExactSplitFixture(session, test) {
  const step = scriptAuthoringSteps(session);
  const capabilities = await session.command('capabilities');
  for (const command of ['import-json', 'loaded-project', 'persisted-projects', 'return', 'selection']) {
    assert.ok(capabilities.commands.includes(command), `Matching app supports ${command}`);
  }
  assert.ok(capabilities.publicDelegateCommands.includes('return'), 'Return is the mounted public delegate route');
  const startup = await step.openScript();
  assert.deepEqual(await session.command('persisted-projects'), [startup]);
  async function unchangedOthers(others, projectID) {
    const packages = await session.command('persisted-projects');
    assert.equal(packages.length, others.length + 1);
    assert.deepEqual(sorted(packages.filter(value => value.id !== projectID)), sorted(others));
  }
  async function open(project) {
    const nodes = await session.waitFor(nodes => byID(nodes, 'workspace-project').some(node => node.enabled && node.hittable));
    await session.command('activate', { target: byID(nodes, 'workspace-project')[0].path });
    const search = await session.waitFor(nodes => nodes.some(node => node.placeholder === 'Find a project' && node.hittable));
    await session.command('text', { target: search.find(node => node.placeholder === 'Find a project' && node.hittable).path, text: project.title });
    await session.waitFor(nodes => nodes.some(node => node.text === `${project.title} · ${project.scenes.length} scene${project.scenes.length === 1 ? '' : 's'}`));
    await step.activate('Open project');
    await session.waitFor(nodes => byID(nodes, 'workspace-project').some(node => node.title === project.title && node.hittable));
    const loaded = await session.command('loaded-project');
    assert.deepEqual(loaded.project, project, 'Browser opened the exact intended project, not another Untitled import');
    return loaded;
  }
  try {
    const others = await session.command('persisted-projects');
    const input = exactSplitInput(test);
    assert.deepEqual(await session.command('import-json', { text: JSON.stringify(input) }), { dispatched: true, projectChanged: true });
    await step.selectTab('Script');
    const before = await step.saved(project => project.title === 'Untitled' && !others.some(value => value.id === project.id));
    uuid(before.id); assert.notEqual(before.id, input.id); assert.equal(before.revision, 0);
    assert.equal(before.createdAt, before.modifiedAt);
    assert.deepEqual(importContent(before), importContent(input), 'Import preserves all literal constructor fields and optional omissions');
    const initialLoaded = await session.command('loaded-project');
    assert.deepEqual(initialLoaded.project, before);
    await unchangedOthers(others, before.id);
    await step.displayed('a', test.text, { finished: true });
    assert.ok((await session.command('keys')).some(command => keyIs(command, '\r', ['command'])));
    await step.key('\r', ['command']);
    let nodes = await session.waitFor(nodes => focusedEditors(nodes).length === 1
      && byID(nodes, 'script-editor-a').some(node => node.firstResponder && node.text === test.text));
    await step.reveal(byID(nodes, 'script-editor-a')[0], nodes);
    await session.command('selection', { target: 'script-editor-a', start: test.offset, end: test.offset });
    await step.waitEditor('script-editor-a', test.text, test.offset);
    assert.deepEqual(await session.command('loaded-project'), initialLoaded, 'Focus and selection leave complete prerequisites intact');
    assert.deepEqual(await session.command('return', { target: 'script-editor-a' }),
      { dispatched: true, delegateAcceptedInsertion: false }, 'Delegate splits once, without newline insertion or retry');
    nodes = await session.waitFor(nodes => focusedEditors(nodes).length === 1
      && focusedEditors(nodes)[0].identifier !== 'script-editor-a');
    const editor = focusedEditors(nodes)[0], rightID = editor.identifier.slice('script-editor-'.length);
    await step.waitEditor(editor.identifier, test.texts[1], 0, 0, { hittable: false });
    const split = await step.saved(project => project.id === before.id && project.entries.length === 2);
    assertExactSplit(test, before, split, rightID);
    const splitLoaded = await session.command('loaded-project');
    assert.deepEqual(splitLoaded.project, split);
    assert.equal(splitLoaded.dateReferenceTimeBits.createdAt, initialLoaded.dateReferenceTimeBits.createdAt);
    await step.finishEditor();
    await step.displayed('a', test.texts[0], { finished: true });
    await step.displayed(rightID, test.texts[1], { finished: true });
    await step.workspaceCommand('s');
    assert.deepEqual(await step.saved(project => project.id === split.id && project.revision === split.revision), split);
    assert.deepEqual(await session.command('loaded-project'), splitLoaded, 'Finish/save do not change source or Date witnesses');
    await step.workspaceHistory();
    const undone = await step.saved(project => project.id === before.id && project.revision === split.revision + 1);
    const undoExpected = structuredClone(before);
    // Production restore bootstraps legacy annotations and materializes the
    // legacy cue in the restore transaction. Neither difference is filtered.
    if (!test.links) undoExpected.entries[0].characterLinks = [];
    undoExpected.cues[0].startAnchor = { entryId: 'a', offsetMs: 1700 };
    undoExpected.cues[0].authoredDurationMs = 1300;
    undoExpected.revision = split.revision + 1; undoExpected.modifiedAt = undone.modifiedAt;
    assert.deepEqual(undone, undoExpected, 'One Undo restores full literal prerequisites plus explicit production bootstrap fields');
    assert.deepEqual((await session.command('loaded-project')).project, undone);
    await step.displayed('a', test.text);
    assert.equal(byID(await session.command('snapshot'), `script-line-${rightID}`).length, 0);
    await step.workspaceHistory(true);
    const redone = await step.saved(project => project.id === before.id && project.revision === undone.revision + 1);
    assert.deepEqual(redone, { ...split, revision: undone.revision + 1, modifiedAt: redone.modifiedAt },
      'One Redo restores complete split content and every generated identity');
    const loaded = await session.command('loaded-project'); assert.deepEqual(loaded.project, redone);
    await unchangedOthers(others, before.id);
    // Exactly one imported fixture exists in this session. Default-title
    // browser filtering is unambiguous even while summaries load in any order.
    assert.equal(others.filter(value => value.title === 'Untitled').length, 0);
    await open(startup);
    assert.deepEqual(await open(redone), loaded, 'Different-document reopen preserves the full model and exact Date witnesses');
    await step.selectTab('Script');
    await step.displayed('a', test.texts[0], { finished: true });
    await step.displayed(rightID, test.texts[1], { finished: true });
    await unchangedOthers(others, before.id);
    console.log(`PASS: AUT-J02/exact-split/${test.id}`);
  } catch (error) { throw new Error(`Exact split ${test.id} failed; no frozen case is retired and no weaker fixture is substituted`, { cause: error }); }
}

export async function exactSplit(session) {
  // Reuse the runner's first fresh session, then close it before launching the
  // next app. close() is idempotent; the runner also closes it in its finally.
  // Later fixtures own isolated app/storage, closed here even after failure.
  // This preserves literal constructor titles without browser ordering guesses.
  const roots = new Set([session.root]);
  await runExactSplitFixture(session, exactSplitFixtures[0]);
  await session.close();
  for (const test of exactSplitFixtures.slice(1)) {
    const isolated = await ScrivSession.launch(process.env.SCRIV_E2E_APP);
    try {
      assert.ok(!roots.has(isolated.root), 'Every exact split fixture receives fresh synthetic storage');
      roots.add(isolated.root);
      await runExactSplitFixture(isolated, test);
    } finally { await isolated.close(); }
  }
}
