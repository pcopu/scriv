import assert from 'node:assert/strict';
import { scriptAuthoringSteps, byID, keyIs } from './script-authoring-steps.mjs';
import { whitespaceWordFixture } from './script-whitespace-word-case.mjs';
import { sortedProjects } from './audio-library-steps.mjs';

const group = 'retime-edited-words';
export const retimedWordsCase = {
  group, id: 'retime-edited-words',
  route: 'import-json → Script Command-Return → edit text → correct invalid draft → Escape → Save',
  oracles: ['an overfull gap leaves the whole saved project and authored timing intact',
    'corrected text re-estimates both gaps and retains authored endpoints and IDs',
    'editing a long dialogue preserves each existing word ID and the explicit time partition'],
  nativeVerified: false, retirementAllowed: false,
};

export async function retimeEditedWords(session) {
  const step = scriptAuthoringSteps(session), editor = 'script-editor-e';
  const startup = await step.openScript();
  const savedProjects = [startup];

  async function importAndEdit(id, title, words, ownedDurationMs) {
    const input = whitespaceWordFixture();
    const text = words.map(word => word.text).join(' ');
    Object.assign(input, { id, title });
    Object.assign(input.entries[0], { text, words, ownedDurationMs, characterLinks: [] });
    input.cues[1].endMs = ownedDurationMs;
    assert.deepEqual(await session.command('import-json', { text: JSON.stringify(input) }),
      { dispatched: true, projectChanged: true });
    await step.selectTab('Script');
    const project = await step.saved(project => project.title === title);
    assert.deepEqual(project, { ...input, id: project.id, createdAt: project.createdAt, modifiedAt: project.modifiedAt });
    const loaded = await session.command('loaded-project');
    assert.deepEqual(loaded.project, project);
    await step.displayed('e', text, { finished: true });
    assert.ok((await session.command('keys')).some(command => keyIs(command, '\r', ['command'])));
    assert.deepEqual(await step.key('\r', ['command']), { dispatched: true });
    const nodes = await session.waitFor(nodes => byID(nodes, editor).some(node => node.firstResponder && node.text === text));
    await step.reveal(byID(nodes, editor)[0], nodes);
    await session.waitFor(nodes => byID(nodes, editor).some(node => node.firstResponder && node.hittable));
    return loaded;
  }
  async function draft(text) {
    await session.command('text', { target: editor, text });
    await step.waitEditor(editor, text, text.length);
  }
  async function finish(before, text, expectedWords) {
    await step.finishEditor();
    await step.workspaceCommand('s');
    const saved = await step.saved(project => project.id === before.id && project.entries[0].text === text);
    const actualWords = saved.entries[0].words;
    const newWord = actualWords.find(word => word.text === expectedWords.addition);
    assert.match(newWord?.id ?? '', /^[A-Fa-f0-9-]{36}$/);
    assert.ok(!before.entries[0].words.some(word => word.id === newWord.id));
    assert.deepEqual(saved, { ...before, revision: before.revision + 1, modifiedAt: saved.modifiedAt,
      entries: [{ ...before.entries[0], text, words: expectedWords.words(newWord.id) }] });
    assert.deepEqual((await session.command('loaded-project')).project, saved);
    savedProjects.push(saved);
    assert.deepEqual(sortedProjects(await session.command('persisted-projects')), sortedProjects(savedProjects));
  }

  const pin = { id: 'authored-pin', text: 'pin', startMs: 1, endMs: 500, timingSource: 'authored' };
  const back = { id: 'estimated-back', text: 'back', startMs: 900, endMs: 1300 };
  const pinned = await importAndEdit('script-pin-input', 'Script pinned timing fixture', [pin, back], 3000);
  await draft('a b pin back');
  await session.waitFor(nodes => nodes.some(node => node.text
    === 'This edit would overwrite authored word timing. Adjust word times or increase the line duration first.'));
  assert.deepEqual(await session.command('loaded-project'), pinned);
  assert.deepEqual(sortedProjects(await session.command('persisted-projects')), sortedProjects([startup, pinned.project]));
  await draft('a pin back');
  await finish(pinned.project, 'a pin back', { addition: 'a',
    words: id => [{ id, text: 'a', startMs: 0, endMs: 1 }, pin, { ...back, startMs: 500, endMs: 3000 }] });

  const longWords = Array.from({ length: 501 }, (_, index) => ({
    id: 'long-word-' + index, text: 'w' + String(index).padStart(3, '0'),
    startMs: index * 10, endMs: (index + 1) * 10,
  }));
  const durationMs = 6000;
  const long = await importAndEdit('script-long-input', 'Script long timing fixture', longWords, durationMs);
  const expanded = long.project.entries[0].text + ' tail';
  await draft(expanded);
  await finish(long.project, expanded, { addition: 'tail', words: id => {
    const words = [...longWords, { id, text: 'tail' }];
    return words.map(({ id, text }, index) => ({ id, text,
      startMs: Math.floor(index * durationMs / words.length),
      endMs: Math.floor((index + 1) * durationMs / words.length) }));
  } });
}
