import assert from 'node:assert/strict';
import { scriptAuthoringSteps, runScriptJourney, byID, rangeIs, keyIs, focusedEditors,
  dialogueDisplayText, historyEntries } from './support/script-authoring-steps.mjs';
import { sourceFixtures as fixture, sourceCases, returnCases } from './support/script-authoring-cases.mjs';

import { exactSplitCases } from './support/script-exact-split-cases.mjs';
import { exactSplit } from './support/script-exact-split-steps.mjs';

import { whitespaceWordCase, preserveWhitespaceWords } from './support/script-whitespace-word-case.mjs';
import { retimedWordsCase, retimeEditedWords } from './support/script-retimed-words.mjs';

// AUT-J02 partial: add → edit/select → refresh → finish → workspace history.
// Return is a distinct public-delegate route, never a type('\n') substitute.
// The original editing slice's AUT-J05 companion remains in that same session.
// Native certification and frozen-baseline retirement are separate gates.

async function writeExactSource(session) {
  const step = scriptAuthoringSteps(session);
  let before = await step.openScript();

  // First authored line: consume the real placeholder once, then append.
  // Never use `text` in this phase: its select-all would conceal the regression.
  let context = await step.addDialogue(before, { revealEditor: false });
  let { editor, entryID } = context;
  const placeholder = context.added.entries.find(entry => entry.id === entryID).text;
  assert.equal(placeholder, fixture.placeholder, 'New dialogue starts with its production placeholder');
  const placeholderNodes = await step.waitEditor(editor.identifier, placeholder, 0, placeholder.length, { hittable: false });
  await step.reveal(byID(placeholderNodes, editor.identifier)[0], placeholderNodes);
  await step.waitEditor(editor.identifier, placeholder, 0, placeholder.length);
  await session.command('type', { target: editor.identifier, text: fixture.replacement });
  await step.waitEditor(editor.identifier, fixture.replacement, fixture.replacement.length);
  await session.command('type', { target: editor.identifier, text: fixture.suffix });
  const placeholderText = fixture.replacement + fixture.suffix;
  await step.waitEditor(editor.identifier, placeholderText, placeholderText.length);
  await step.finishEditor();
  await step.displayed(entryID, placeholderText, { finished: true });
  before = await step.saved(project => project.id === before.id
    && project.entries.find(entry => entry.id === entryID)?.text === placeholderText);
  assert.equal(before.entries.length, context.before.entries.length + 1, 'Typing and finishing add exactly one entry');
  assert.equal(before.entries.find(entry => entry.id === entryID).kind, 'dialogue');
  console.log('PASS: AUT-J02/write-exact-source/placeholder-consumed-once');

  // Next authored line: change exact UTF-16 ranges and retain selection across
  // an app refresh. Earlier authored text becomes part of the invariance oracle.
  context = await step.addDialogue(before);
  ({ editor, entryID } = context);
  const { decomposed, composed, astronaut } = fixture;
  assert.notEqual(decomposed, composed, 'The fixture contains distinct UTF-16 representations');
  assert.equal(decomposed.normalize('NFC'), composed, 'The final replacement is canonically equivalent');
  let expected = `😀 One two | ${decomposed} | ${composed} | ${astronaut} | Alex Alex.`;
  const waitEditor = (text, start, end = start, stage) => step.waitEditor(editor.identifier, text, start, end, { stage });
  const savedText = (text, stage) => step.savedExactText(context, text, stage);
  await session.command('text', { target: editor.identifier, text: expected }); // Fixture setup only.
  await waitEditor(expected, expected.length);
  await savedText(expected, 'Initial Unicode text');
  async function replaceRange(start, end, replacement, stage) {
    const source = expected;
    assert.ok(start >= 0 && end >= start && end <= source.length, `${stage}: fixture range is in bounds`);
    await session.command('selection', { target: editor.identifier, start, end });
    await waitEditor(source, start, end, `${stage}: selection before insertion`);
    await session.command('type', { target: editor.identifier, text: replacement });
    expected = source.slice(0, start) + replacement + source.slice(end);
    await waitEditor(expected, start + replacement.length, start + replacement.length, stage);
    await savedText(expected, stage);
    await waitEditor(expected, start + replacement.length, start + replacement.length, `${stage}: after save`);
  }
  assert.equal(expected.indexOf('One'), 3, 'Leading emoji occupies two UTF-16 units before the space');
  await replaceRange(3, 6, 'First', 'Replacement after a surrogate pair');
  assert.ok(expected.startsWith('😀 First two | '), 'Both spaces adjacent to the replaced word remain exact');
  const lastName = expected.lastIndexOf('Alex');
  assert.notEqual(lastName, expected.indexOf('Alex'), 'The fixture has two distinct matching substrings');
  await replaceRange(lastName, lastName + 'Alex'.length, 'A\u0301lex', 'Only the second repeated name changes');
  assert.ok(expected.endsWith('Alex A\u0301lex.'), 'The first identical occurrence is preserved');
  const astronautStart = expected.indexOf(astronaut);
  assert.ok(astronautStart >= 0);
  await replaceRange(astronautStart, astronautStart + astronaut.length, '🎬', 'Whole joined emoji replacement');
  await replaceRange(expected.length, expected.length, '  e\u0301 🎬', 'Collapsed-caret insertion with exact whitespace');

  const beforeCanonical = expected;
  const beforeCanonicalProject = await savedText(beforeCanonical, 'Before canonical-only replacement');
  const start = expected.indexOf(decomposed);
  assert.ok(start >= 0);
  const end = start + decomposed.length;
  await session.command('selection', { target: editor.identifier, start, end });
  let nodes = await waitEditor(expected, start, end);
  const zooms = nodes.filter(node => /^Shared script zoom, \d+ percent$/.test(node.label));
  assert.equal(zooms.length, 1, 'One shared script zoom control is present');
  const zoomBefore = Number(zooms[0].label.match(/\d+/)[0]);
  const zoomInput = zoomBefore >= 200 ? '-' : '=';
  assert.ok((await session.command('keys')).some(command => keyIs(command, zoomInput, ['command'])),
    'Enabled native zoom shortcut is available during editing');
  await step.key(zoomInput, ['command']);
  await session.waitFor(nodes => nodes.some(node => /^Shared script zoom, \d+ percent$/.test(node.label)
    && node.label !== zooms[0].label));
  nodes = await session.command('snapshot');
  const refreshed = byID(nodes, editor.identifier);
  assert.equal(refreshed.length, 1, 'Refresh retains one editor for the same entry');
  assert.ok(refreshed[0].firstResponder, 'Refresh retains native editor focus');
  assert.equal(refreshed[0].text, beforeCanonical, 'Refresh preserves exact source text');
  assert.ok(rangeIs(refreshed[0], start, end), 'Refresh preserves both UTF-16 selection endpoints');
  await step.reveal(refreshed[0], nodes);
  await waitEditor(beforeCanonical, start, end, 'Selection after zoom and scrolling');

  // No second selection: it would hide an app refresh that discarded the range.
  await session.command('type', { target: editor.identifier, text: composed });
  expected = beforeCanonical.slice(0, start) + composed + beforeCanonical.slice(end);
  assert.notEqual(expected, beforeCanonical, 'Canonical-only edit changes UTF-16 bytes');
  await waitEditor(expected, start + composed.length, start + composed.length, 'Canonical-only native replacement');
  const canonicalProject = await savedText(expected, 'Canonical-only replacement');
  const timingMetadata = project => project.entries.find(entry => entry.id === entryID).words.map(({ text, ...metadata }) => metadata);
  assert.deepEqual(timingMetadata(canonicalProject), timingMetadata(beforeCanonicalProject),
    'Canonical-only replacement preserves word IDs, endpoints and timing ownership');
  await waitEditor(expected, start + composed.length, start + composed.length, 'Canonical-only replacement after save');
  await step.finishEditor();
  await step.displayed(entryID, expected, { finished: true });
  await savedText(expected, 'Finished edit');
  await step.workspaceHistory();
  await savedText(beforeCanonical, 'Undo restores the exact decomposed text');
  await step.displayed(entryID, beforeCanonical);
  await step.workspaceHistory(true);
  before = await savedText(expected, 'Redo restores the exact composed text');
  await step.displayed(entryID, expected);
  console.log('PASS: AUT-J02/write-exact-source/unicode-range-refresh-history');

  // The select-all replacement route remains distinct from the type route.
  context = await step.addDialogue(before);
  ({ editor, entryID } = context);
  await session.command('text', { target: editor.identifier, text: fixture.fullText });
  await session.waitFor(nodes => byID(nodes, editor.identifier).some(node => node.text === fixture.fullText));
  await step.finishEditor();
  await step.displayed(entryID, fixture.fullText);
  const persisted = await step.saved(project => project.entries.some(entry => entry.text === fixture.fullText));
  assert.equal(persisted.entries.find(entry => entry.text === fixture.fullText).id, entryID);
  await step.workspaceHistory();
  await step.saved(project => project.id === persisted.id && project.entries.find(entry => entry.id === entryID)?.text !== fixture.fullText);
  await step.workspaceHistory(true);
  await step.saved(project => project.id === persisted.id && project.entries.find(entry => entry.id === entryID)?.text === fixture.fullText);
  await step.displayed(entryID, fixture.fullText);

  // Cross-family legacy companion, explicitly AUT-J05, not a claim that
  // character creation is source editing. Preserve the original tab transition.
  await step.selectTab('Characters');
  await step.activate('Add character');
  nodes = await session.waitFor(nodes => nodes.some(node => node.placeholder === 'Name' && node.firstResponder));
  const name = nodes.find(node => node.placeholder === 'Name' && node.firstResponder);
  await session.command('text', { target: name.path, text: fixture.character });
  await step.activate('Purple character colour');
  await step.activate('Pink character colour');
  await step.activate('Save character');
  await session.waitFor(nodes => nodes.some(node => node.identifier.startsWith('character-ribbon-') && node.label === fixture.character));
  const characterProject = await step.saved(project => project.characters.some(character => character.name === fixture.character));
  assert.equal(characterProject.characters.find(character => character.name === fixture.character).color, 'F272AC',
    'Pink colour action persists its result');
  console.log('PASS: AUT-J02/write-exact-source/replace-finish-history-character-companion (AUT-J05 tail)');
}

async function returnBoundary(session) {
  const step = scriptAuthoringSteps(session);
  assert.ok((await session.command('capabilities')).commands.includes('return'),
    'Matching app exposes the explicit public-delegate Return command; no insertion fallback is allowed');
  const initial = await step.openScript();
  let previous = initial;
  assert.equal(returnCases[2].start, 8, 'The Unicode split offset includes the two-unit leading emoji');
  assert.equal(returnCases[2].text.slice(returnCases[2].start, returnCases[2].end), 'cafe\u0301 👩🏽‍🚀');
  for (const test of returnCases) {
    try {
      const { editor, entryID } = await step.addDialogue(previous);
      await session.command('text', { target: editor.identifier, text: test.text }); // Setup, never Return.
      await step.waitEditor(editor.identifier, test.text, test.text.length, test.text.length, { hittable: false });
      const beforeSplit = await step.saved(project => project.id === initial.id
        && project.entries.length === previous.entries.length + 1
        && project.entries.find(entry => entry.id === entryID)?.text === test.text);
      const original = beforeSplit.entries.find(entry => entry.id === entryID);
      assert.equal(original.kind, 'dialogue');
      assert.equal(original.ownedDurationMs, 3000, 'New dialogue retains its three-second duration');
      assert.deepEqual(original.words.map(word => word.text), test.text.match(/\S+/gu) ?? []);
      const preSplitIDs = new Set(beforeSplit.entries.map(entry => entry.id));
      await session.command('selection', { target: editor.identifier, start: test.start, end: test.end });
      await step.waitEditor(editor.identifier, test.text, test.start, test.end);
      // Calls the mounted public edit delegate once with observed native range.
      // Its false result forbids insertText fallback and selected-text deletion.
      assert.deepEqual(await session.command('return', { target: editor.identifier }),
        { dispatched: true, delegateAcceptedInsertion: false },
        'The actual script delegate rejects inserting a newline or deleting selected characters');
      let nodes;
      try {
        nodes = await session.waitFor(nodes => focusedEditors(nodes).length === 1
          && !preSplitIDs.has(focusedEditors(nodes)[0].identifier.slice('script-editor-'.length)));
      } catch (error) {
        const evidence = await step.returnFailureEvidence(initial.id, editor.identifier, entryID, preSplitIDs);
        throw new Error(`Return did not focus a new entry. Read-only synthetic outcome: ${JSON.stringify(evidence)}`, { cause: error });
      }
      const rightEditor = focusedEditors(nodes)[0];
      const rightID = rightEditor.identifier.slice('script-editor-'.length);
      const leftText = test.text.slice(0, test.start);
      const rightText = test.text.slice(test.start);
      assert.notEqual(rightID, entryID, 'Split creates a new right-hand identity');
      await step.waitEditor(rightEditor.identifier, rightText, 0, 0, { hittable: false });
      await step.reveal(rightEditor, nodes);
      await step.waitEditor(rightEditor.identifier, rightText, 0);
      await step.displayed(entryID, leftText);
      const split = await step.saved(project => project.id === initial.id
        && project.entries.length === beforeSplit.entries.length + 1
        && project.entries.find(entry => entry.id === entryID)?.text === leftText
        && project.entries.find(entry => entry.id === rightID)?.text === rightText);
      const left = split.entries.find(entry => entry.id === entryID);
      const right = split.entries.find(entry => entry.id === rightID);
      assert.deepEqual(split.entries.filter(entry => !preSplitIDs.has(entry.id)).map(entry => entry.id), [rightID],
        'Exactly one new entry appears and it owns the focused right-hand editor');
      assert.equal(left.text + right.text, test.text, 'Return preserves every original UTF-16 code unit, including selected text');
      assert.equal(right.text.slice(0, test.end - test.start), test.text.slice(test.start, test.end),
        'The complete selected substring remains at the start of the new line');
      assert.ok(!left.text.includes('\n') && !right.text.includes('\n'), 'Return does not become a source newline');
      for (const entry of [left, right]) {
        assert.equal(entry.kind, original.kind, 'Both entries remain dialogue');
        assert.equal(entry.sceneId, original.sceneId, 'Both entries remain in the original scene');
        assert.equal(entry.characterId, original.characterId, 'Splitting preserves speaker identity');
        assert.ok(entry.ownedDurationMs >= 1, 'Even an empty spoken line owns positive time');
        assert.deepEqual(entry.words.map(word => word.text), entry.text.match(/\S+/gu) ?? [],
          'Persisted word spelling exactly matches the new source text');
        let previousEnd = 0;
        for (const word of entry.words) {
          assert.ok(Number.isInteger(word.startMs) && Number.isInteger(word.endMs)
            && word.startMs >= previousEnd && word.endMs > word.startMs
            && word.endMs <= entry.ownedDurationMs, 'Persisted word timing is ordered and within its line');
          previousEnd = word.endMs;
        }
      }
      assert.equal(left.ownedDurationMs + right.ownedDurationMs, original.ownedDurationMs,
        'Split redistributes the existing duration without inventing time');
      assert.deepEqual([...left.words, ...right.words].map(word => word.id), original.words.map(word => word.id),
        'Complete source words keep their exact stable IDs across the boundary');
      const sceneEntries = split.entries.filter(entry => entry.sceneId === original.sceneId).sort((a, b) => a.order - b.order);
      assert.equal(sceneEntries[sceneEntries.findIndex(entry => entry.id === entryID) + 1]?.id, rightID,
        'The new line is immediately after its original in scene order');
      for (const prior of beforeSplit.entries.filter(entry => entry.id !== entryID)) {
        assert.deepEqual(split.entries.find(entry => entry.id === prior.id), prior,
          'Every unrelated entry, including its exact text, IDs and timing, is unchanged');
      }
      await step.waitEditor(rightEditor.identifier, rightText, 0, 0, { hittable: false });
      await step.finishEditor();
      const splitDisplays = nodes => byID(nodes, `script-line-${entryID}`).some(node => node.text === dialogueDisplayText(leftText))
        && byID(nodes, `script-line-${rightID}`).some(node => node.text === dialogueDisplayText(rightText));
      await session.waitFor(splitDisplays);
      // Finish first: these are workspace history commands, not native text undo.
      await step.workspaceHistory();
      const undone = await step.saved(project => project.id === initial.id
        && project.entries.length === beforeSplit.entries.length && !project.entries.some(entry => entry.id === rightID)
        && project.entries.find(entry => entry.id === entryID)?.text === test.text);
      assert.deepEqual(historyEntries(undone), historyEntries(beforeSplit),
        'One workspace Undo restores exact original entry text, IDs, order, speaker and timing');
      await session.waitFor(nodes => byID(nodes, `script-line-${entryID}`).some(node => node.text === dialogueDisplayText(test.text))
        && byID(nodes, `script-line-${rightID}`).length === 0 && byID(nodes, rightEditor.identifier).length === 0);
      await step.workspaceHistory(true);
      const redone = await step.saved(project => project.id === initial.id && project.entries.length === split.entries.length
        && project.entries.find(entry => entry.id === entryID)?.text === leftText
        && project.entries.find(entry => entry.id === rightID)?.text === rightText);
      assert.deepEqual(historyEntries(redone), historyEntries(split),
        'One workspace Redo restores the same split entry IDs and exact text, order, speaker and timing');
      await session.waitFor(splitDisplays);
      previous = redone;
      console.log(`PASS: AUT-J02/return-boundary/${test.id}: ${test.name}`);
    } catch (error) { throw new Error(`Return boundary case failed: ${test.name}`, { cause: error }); }
  }
  assert.equal(previous.entries.length, initial.entries.length + returnCases.length * 2,
    'Each completed case leaves exactly its two saved split lines');
}

await runScriptJourney({ journey: 'AUT-J02', companions: ['AUT-J05: editing.mjs character-create/palette tail'],
  workflows: { 'write-exact-source': writeExactSource, 'return-boundary': returnBoundary,
    'whitespace-word-preservation': preserveWhitespaceWords, 'exact-split': exactSplit,
    'retime-edited-words': retimeEditedWords },
  cases: [...sourceCases, whitespaceWordCase, ...exactSplitCases, retimedWordsCase],
  excluded: ['physical keyboard/IME or tap selection', 'Backspace/merge/native text undo', 'journal rejection/recovery/leases',
    'character-link editing beyond the exact-split confirmed partition fixture', 'font size/native object identity', 'process relaunch (browser reopen covered by whitespace-word-preservation and exact-split)', 'uncovered frozen UIKit assertions'] });
