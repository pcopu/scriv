import assert from 'node:assert/strict';
import { ScrivSession } from '../../../cli/scriv.mjs';
import { focusedEditors, byID } from './support/script-authoring-steps.mjs';
import { scriptMergeCases, frozenMergeSources } from './support/script-merge-cases.mjs';
import { scriptMergeSteps, assertMerged } from './support/script-merge-steps.mjs';

// AUT-J02 / SCR-07. One actual public deleteBackward invocation per stimulus.
// Existing imported rows are reached through real Layers controls and the
// registered edit toggle. No fake keyboard events or direct model operations.
async function mergeAndSave(session, cases) {
  const step = scriptMergeSteps(session);
  const startup = await step.initialize();
  let checkedGuards = false, checkedObservationGuards = false;
  for (const test of cases) {
    try {
      const context = await step.importCase(test);
      let before = context.before;
      let removedID = test.target;
      let editorID = await step.focusEntry(before, test.target);
      if (!checkedGuards) { await step.verifyCommandGuards(before, editorID); checkedGuards = true; }
      if (test.splitAt !== undefined) {
        const original = before.entries.find(entry => entry.id === test.target);
        await step.select(editorID, original.text, test.splitAt);
        assert.deepEqual(await session.command('return', { target: editorID }),
          { dispatched: true, delegateAcceptedInsertion: false });
        const known = new Set(before.entries.map(entry => entry.id));
        const nodes = await session.waitFor(nodes => focusedEditors(nodes).length === 1
          && !known.has(focusedEditors(nodes)[0].identifier.slice('script-editor-'.length)));
        editorID = focusedEditors(nodes)[0].identifier;
        removedID = editorID.slice('script-editor-'.length);
        await step.reveal(focusedEditors(nodes)[0], nodes);
        await step.waitEditor(editorID, 'watching', 0);
        before = await step.saved(project => project.id === before.id && project.entries.length === before.entries.length + 1
          && project.entries.find(entry => entry.id === removedID)?.text === 'watching');
        const directions = before.entries.filter(entry => entry.kind === 'direction').sort((a, b) => a.order - b.order);
        assert.deepEqual(directions.map(entry => entry.text), ['Keep ', 'watching']);
        assert.deepEqual(directions.map(entry => entry.ownedDurationMs), [0, 0]);
        assert.deepEqual(directions.map(entry => entry.coverageDurationMs), [5000, 5000]);
      }
      const current = before.entries.find(entry => entry.id === removedID);
      await step.select(editorID, current.text, 0);
      const countsBefore = await step.interactionCounts();
      await step.deleteBackward(editorID);
      // The successful merge must focus the previous identity at its ORIGINAL
      // UTF-16 length. Do not repair focus/caret after dispatch.
      await step.waitEditor('script-editor-a', test.expectedText, test.caret, test.caret, { hittable: false });
      const merged = await step.saved(project => project.id === before.id
        && project.entries.length === before.entries.length - 1
        && project.entries.find(entry => entry.id === 'a')?.text === test.expectedText);
      assertMerged(test, before, merged, removedID);
      assert.equal((await step.interactionCounts()).mergeAtStartInvocations - countsBefore.mergeAtStartInvocations, 1,
        'The actual mounted script override invokes its installed merge callback exactly once');
      if (!checkedObservationGuards) {
        // A positive nonzero total also proves repeated reads cannot reset it.
        await step.verifyInteractionObservationGuards(merged, 'script-editor-a');
        checkedObservationGuards = true;
      }
      assert.equal(byID(await session.command('snapshot'), editorID).length, 0, 'Removed row has no remaining native editor');
      await step.finishAndSave(merged, 'a', test.expectedText);
      assert.equal((await step.interactionCounts()).mergeAtStartInvocations - countsBefore.mergeAtStartInvocations, 1,
        'Finish and Save do not invoke an additional merge callback');
      let final = merged;
      if (test.history) final = await step.history(before, merged, 'a');
      if (test.reopen) await step.reopen(final, startup);
      await step.unchangedOthers(context.others, before.id);
      console.log(`PASS: AUT-J02/SCR-07/${test.key}`);
    } catch (error) { throw new Error(`SCR-07/${test.key} failed without retrying the mutation`, { cause: error }); }
  }
}
async function nativeDeletion(session, cases) {
  const step = scriptMergeSteps(session);
  await step.initialize();
  for (const test of cases) {
    try {
      const { before, others } = await step.importCase(test);
      const editorID = await step.focusEntry(before, test.target);
      const original = before.entries.find(entry => entry.id === test.target);
      await step.select(editorID, original.text, test.start, test.end);
      let countsBefore;
      if (test.observeCallbackCounts) {
        assert.equal((await step.scriptInputState(editorID)).smartInsertDeleteDisabled, true,
          'The actual UITextView disables smart insert/delete before the exact Unicode deletion');
        countsBefore = await step.verifyInteractionObservationGuards(before, editorID);
      }
      await step.deleteBackward(editorID);
      await step.waitEditor(editorID, test.expectedText, test.caret);
      if (countsBefore) {
        assert.equal((await step.interactionCounts()).mergeAtStartInvocations - countsBefore.mergeAtStartInvocations, 0,
          'Frozen ScriptUIKitTests::0010: selected deletion invokes no merge callback');
      }
      const after = await step.saved(project => project.id === before.id
        && project.entries.find(entry => entry.id === test.target)?.text === test.expectedText);
      assert.equal(after.entries.length, before.entries.length, 'Native deletion does not merge or add a row');
      assert.deepEqual(after.entries.map(entry => entry.id), before.entries.map(entry => entry.id));
      const edited = after.entries.find(entry => entry.id === test.target);
      for (const field of ['id', 'sceneId', 'order', 'kind', 'ownedDurationMs', 'coverageDurationMs', 'color', 'characterId']) {
        assert.equal(edited[field], original[field], `Native deletion preserves the row's ${field}`);
      }
      assert.deepEqual(edited.words.map(word => word.text), test.expectedText.match(/\S+/gu) ?? []);
      for (const value of before.entries.filter(entry => entry.id !== test.target)) {
        assert.deepEqual(after.entries.find(entry => entry.id === value.id), value, 'All other entries remain unchanged');
      }
      for (const field of ['scenes', 'cues', 'characters', 'images', 'audioAssets', 'audioClips', 'audioVolume']) {
        assert.deepEqual(after[field], before[field]);
      }
      await step.waitEditor(editorID, test.expectedText, test.caret);
      await step.finishAndSave(after, test.target, test.expectedText);
      if (countsBefore) {
        assert.equal((await step.interactionCounts()).mergeAtStartInvocations - countsBefore.mergeAtStartInvocations, 0,
          'No merge callback occurs through persistence, Finish or Save');
      }
      await step.unchangedOthers(others, before.id);
      console.log(`PASS: AUT-J02/SCR-07/${test.key}`);
    } catch (error) { throw new Error(`SCR-07/${test.key} failed without a deletion fallback`, { cause: error }); }
  }
}
async function rejectBoundary(session, [test]) {
  const step = scriptMergeSteps(session);
  await step.initialize();
  const { before, others } = await step.importCase(test);
  const editorID = await step.focusEntry(before, test.target);
  await step.rejected(test, before, others, editorID);
  console.log(`PASS: AUT-J02/SCR-07/${test.key}`);
}
const workflows = { 'merge-and-save': mergeAndSave, 'native-deletion': nativeDeletion, 'rejected-boundaries': rejectBoundary };
let groups = Object.keys(workflows), list = false, groupSeen = false;
const args = process.argv.slice(2);
for (let index = 0; index < args.length; index++) {
  if (args[index] === '--list-cases') { list = true; continue; }
  assert.equal(args[index], '--group', `Unknown argument: ${args[index]}`);
  assert.equal(groupSeen, false, 'Use --group only once'); groupSeen = true;
  const group = args[++index]; assert.ok(Object.hasOwn(workflows, group), `--group must be one of ${Object.keys(workflows).join(', ')}`);
  groups = [group];
}
if (list) {
  console.log(JSON.stringify({ journey: 'AUT-J02', interaction: 'SCR-07', nativeVerified: false, frozenMergeSources,
    cases: scriptMergeCases.filter(test => groups.includes(test.group)).map(({ makeInput, ...test }) => test),
    excluded: ['physical Backspace delivery', 'IME/marked-text behavior', 'frozen ::0009 consecutive detached-editor callback sequence',
      'frozen ::0008 transient detached-editor equivalence',
      'in-memory atomicity under rejected modal', 'lease denial, races and cancellation', 'journal failure/recovery',
      'process relaunch', 'whole TimingEngine.validate parity'] }, null, 2));
} else {
  assert.ok(process.env.SCRIV_E2E_APP, 'Set SCRIV_E2E_APP to an automation-enabled Catalyst app; no fallback is supported');
  const roots = new Set();
  for (const group of groups) {
    const cases = scriptMergeCases.filter(test => test.group === group);
    // Rejection leaves its actual UIAlertController open. Each such document
    // owns a fresh process; do not call an alert handler or forge dismissal.
    const batches = group === 'rejected-boundaries' ? cases.map(test => [test]) : [cases];
    for (const batch of batches) {
      const session = await ScrivSession.launch(process.env.SCRIV_E2E_APP);
      try {
        assert.ok(!roots.has(session.root)); roots.add(session.root);
        await workflows[group](session, batch);
      } finally { await session.close(); }
    }
  }
}
