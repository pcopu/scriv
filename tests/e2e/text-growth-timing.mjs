import assert from 'node:assert/strict';
import { ScrivSession } from '../../cli/scriv.mjs';
import { waitForSavedProject } from './support/saved-projects.mjs';

// Candidate: EditingTests.swift::0006. Import supplies the one-millisecond
// starting state; only the real inline editor grows it to three milliseconds.
// No duration alert, private model call, or JavaScript timing implementation.
assert.ok(process.env.SCRIV_E2E_APP, 'Set SCRIV_E2E_APP to an automation-enabled Catalyst bundle');
const session = await ScrivSession.launch(process.env.SCRIV_E2E_APP);
const baselineID = 'apps/mac/Tests/ScrivCoreTests/EditingTests.swift::0006';
const byID = (nodes, id) => nodes.filter(node => node.identifier === id);
const focusedEditors = nodes => nodes.filter(node => node.identifier.startsWith('script-editor-') && node.firstResponder);
const keyIs = (command, input, modifiers) => command.input === input
  && command.modifiers.length === modifiers.length
  && modifiers.every(modifier => command.modifiers.includes(modifier));
const rangeIs = (node, start, end = start) => node?.selection?.start === start && node.selection.end === end;
const source = 'Title: CLI text growth\n\nINT. ROOM\n\n@NARRATOR\na\n[[scriv duration=1 coverage=0]]';

async function reveal(node, nodes) {
  if (node.hittable) return;
  const scroll = nodes.filter(candidate => /ScrollView/.test(candidate.type) && candidate.hittable
    && node.path.startsWith(candidate.path + '.')).sort((a, b) => b.path.length - a.path.length)[0];
  assert.ok(scroll, 'Offscreen native input has a reachable scroll ancestor');
  await session.command('scroll', { target: scroll.path,
    y: scroll.scroll.y + node.frame.y - scroll.frame.y - 24 });
}

try {
  const capabilities = await session.command('capabilities');
  for (const command of ['import-fountain', 'persisted-projects', 'keys', 'key', 'selection', 'type']) {
    assert.ok(capabilities.commands.includes(command), `Matching app supports ${command}`);
  }
  let nodes = await session.waitFor(nodes => byID(nodes, 'workspace-tabs').some(node => node.enabled && node.hittable));
  const tabs = byID(nodes, 'workspace-tabs')[0];
  const scriptIndex = tabs.segments.indexOf('Script');
  assert.ok(scriptIndex >= 0, 'Actual Script tab exists');
  if (tabs.selected !== scriptIndex) await session.command('select', { target: tabs.identifier, index: scriptIndex });
  assert.ok((await session.command('keys')).some(command => keyIs(command, 's', ['command'])), 'Workspace Save is enabled');
  await session.command('key', { input: 's', modifiers: ['command'] });
  await waitForSavedProject(session, project => project.entries.length > 0);
  const retained = await session.command('persisted-projects');
  assert.equal(retained.length, 1, 'Fresh run contains only its saved startup sample');
  const knownIDs = new Set(retained.map(project => project.id));

  assert.deepEqual(await session.command('import-fountain', { text: source }),
    { dispatched: true, projectChanged: true }, 'Production importer installs a distinct synthetic project');
  const before = await waitForSavedProject(session, project => !knownIDs.has(project.id));
  assert.equal(before.title, 'CLI text growth');
  assert.equal(before.scenes.length, 1);
  assert.equal(before.entries.length, 1);
  assert.equal(before.cues.length, 1);
  const original = before.entries[0];
  const originalCue = before.cues[0];
  assert.equal(original.sceneId, before.scenes[0].id);
  assert.equal(original.kind, 'dialogue');
  assert.equal(original.text, 'a');
  assert.equal(original.ownedDurationMs, 1, 'Fixture begins at one millisecond, not the default estimate');
  assert.equal(original.coverageDurationMs, 0);
  assert.equal(original.words.length, 1);
  assert.ok(original.words[0].id, 'Original word has a persisted identity');
  assert.deepEqual(original.words.map(({ text, startMs, endMs }) => ({ text, startMs, endMs })),
    [{ text: 'a', startMs: 0, endMs: 1 }]);
  assert.ok(originalCue.id, 'Original picture cue has a persisted identity');
  assert.equal(originalCue.sceneId, original.sceneId);
  assert.equal(originalCue.startMs, 0);
  assert.equal(originalCue.endMs, 1);
  assert.equal((await session.command('persisted-projects')).length, retained.length + 1);

  const editorID = `script-editor-${original.id}`;
  const lineID = `script-line-${original.id}`;
  await session.waitFor(nodes => byID(nodes, 'workspace-project').some(node => node.title === before.title)
    && byID(nodes, lineID).some(node => node.text === 'a'));
  // The production importer selects its first entry. Discover and dispatch the
  // installed editing shortcut, then require that exact entry to own focus.
  const editKey = (await session.command('keys')).find(command => keyIs(command, '\r', ['command'])
    && command.action === 'toggleScriptEditingFromKeyboard:');
  assert.ok(editKey, 'Installed Command-Return action can edit the imported first entry');
  await session.command('key', { input: editKey.input, modifiers: editKey.modifiers });
  nodes = await session.waitFor(nodes => focusedEditors(nodes).length === 1
    && byID(nodes, editorID).some(node => node.firstResponder && node.text === 'a'));
  await reveal(byID(nodes, editorID)[0], nodes);
  await session.waitFor(nodes => byID(nodes, editorID).some(node => node.firstResponder && node.hittable && node.text === 'a'));
  await session.command('selection', { target: editorID, start: 1, end: 1 });
  await session.waitFor(nodes => byID(nodes, editorID).some(node => node.firstResponder && node.hittable
    && node.text === 'a' && rangeIs(node, 1)));
  await session.command('type', { target: editorID, text: ' b c' });
  await session.waitFor(nodes => byID(nodes, editorID).some(node => node.firstResponder
    && node.text === 'a b c' && rangeIs(node, 5)));
  assert.ok((await session.command('keys')).some(command => keyIs(command, 'Escape', [])), 'Native editor has its enabled finish action');
  await session.command('key', { input: 'Escape', modifiers: [] });
  await session.waitFor(nodes => focusedEditors(nodes).length === 0
    && byID(nodes, lineID).some(node => node.text === 'a b c'));

  const after = await waitForSavedProject(session, project => project.id === before.id
    && project.entries.some(entry => entry.id === original.id && entry.text === 'a b c'));
  assert.equal(after.entries.length, 1, 'Text growth does not split or add an entry');
  assert.equal(after.cues.length, 1, 'Text growth does not replace the original cue with extra cues');
  const entry = after.entries[0];
  const cue = after.cues[0];
  assert.equal(entry.id, original.id);
  assert.equal(entry.sceneId, original.sceneId);
  assert.equal(entry.kind, 'dialogue');
  assert.equal(entry.ownedDurationMs, 3, `${baselineID}: growth resizes before validating`);
  assert.equal(entry.words[0]?.id, original.words[0].id, `${baselineID}: first word identity survives`);
  assert.equal(cue.endMs, 3, `${baselineID}: picture end grows with the line`);
  assert.deepEqual(entry.words.map(word => word.endMs), [1, 2, 3], `${baselineID}: exact millisecond endpoints`);
  // Additional identity/source checks accompany, not replace, the four frozen
  // value assertions above and the production validation required for this save.
  assert.equal(cue.id, originalCue.id);
  assert.equal(cue.sceneId, originalCue.sceneId);
  assert.equal(cue.startMs, 0);
  assert.deepEqual(entry.words.map(word => word.text), ['a', 'b', 'c']);
  assert.deepEqual(entry.words.map(word => word.startMs), [0, 1, 2]);
  assert.equal(new Set(entry.words.map(word => word.id)).size, 3);
  assert.equal(entry.coverageDurationMs, original.coverageDurationMs);
  assert.equal(entry.characterId, original.characterId);
  for (const property of ['scenes', 'characters', 'images', 'audioAssets', 'audioClips']) {
    assert.deepEqual(after[property], before[property], `${property} remains unchanged`);
  }
  assert.ok(after.revision > before.revision, 'Accepted edit reaches a newer saved revision');

  const finalProjects = await session.command('persisted-projects');
  assert.equal(finalProjects.length, retained.length + 1, 'Only the actual import creates another project');
  assert.deepEqual(finalProjects.find(project => project.id === after.id), after, 'Finished timing remains exactly saved');
  for (const project of retained) {
    assert.deepEqual(finalProjects.find(candidate => candidate.id === project.id), project, 'Original saved project remains unchanged');
  }
  console.log(`PASS: ${baselineID}: actual imported 1 ms dialogue grows through the native editor to 3 ms, preserving the original word and cue identities and exact endpoints`);
} finally { await session.close(); }
