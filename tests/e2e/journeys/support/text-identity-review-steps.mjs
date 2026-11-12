import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { scriptAuthoringSteps, byID, readyTabs, focusedEditors, keyIs } from './script-authoring-steps.mjs';
import { identityReviewCases, identityUnlinkCompanion, identityReviewInput, auditIdentityReviewFixtures } from './text-identity-review-fixtures.mjs';

const ordered = projects => [...projects].sort((a, b) => a.id.localeCompare(b.id));
const line = project => {
  const matches = project.entries.filter(entry => entry.id === 'identity-line');
  assert.equal(matches.length, 1);
  return matches[0];
};
const payload = project => {
  const copy = structuredClone(project);
  for (const key of ['id', 'createdAt', 'modifiedAt', 'revision']) delete copy[key];
  return copy;
};
const uuid = value => assert.match(value, /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i);
const sheetSource = nodes => nodes.filter(node => node.label === 'Source line, unchanged');
const namedButton = title => node => /Button$/.test(node.type) && node.title === title;
const header = (nodes, title) => byID(nodes, 'workspace-project').some(node => node.title === title && node.hittable);

export async function runIdentityReview(session) {
  auditIdentityReviewFixtures();
  const step = scriptAuthoringSteps(session);
  const capabilities = await session.command('capabilities');
  for (const command of ['snapshot', 'activate', 'scroll', 'selection', 'type', 'text', 'keys', 'key',
    'script-insert', 'script-delete-selection', 'script-interaction-counts', 'delete-backward', 'import-json', 'loaded-project', 'persisted-projects', 'presented-alerts']) {
    assert.ok(capabilities.commands.includes(command), `Matching actual app advertises ${command}`);
  }
  assert.ok(capabilities.publicDelegateCommands.includes('script-insert'));
  assert.ok(capabilities.publicDelegateCommands.includes('script-delete-selection'));
  const runID = capabilities.runID;
  await session.waitFor(readyTabs);
  await step.selectTab('Script');
  await step.workspaceCommand('s');
  const startup = await step.saved(project => project.title === 'YAM MAN');
  assert.deepEqual(await session.command('persisted-projects'), [startup], 'Fresh synthetic session only');

  async function activate(predicate) {
    let nodes = await session.waitFor(nodes => nodes.filter(predicate).length === 1);
    await step.reveal(nodes.find(predicate), nodes);
    nodes = await session.waitFor(nodes => nodes.filter(predicate).length === 1
      && nodes.find(predicate).enabled === true && nodes.find(predicate).hittable);
    assert.deepEqual(await session.command('activate', { target: nodes.find(predicate).path }), { dispatched: true });
  }
  const button = title => activate(namedButton(title));
  async function persistedExactly(projects) {
    assert.deepEqual(ordered(await session.command('persisted-projects')), ordered(projects));
  }
  async function fullState(beforeWitness, expected, others) {
    const saved = await step.saved(project => project.id === expected.id && project.revision === expected.revision);
    assert.deepEqual(saved, expected, 'Every saved field, source, identity, timing and unrelated value is exact');
    const witness = await session.command('loaded-project');
    assert.deepEqual(witness.project, expected, 'Complete loaded canonical model equals the saved package');
    assert.equal(witness.dateReferenceTimeBits.createdAt, beforeWitness.dateReferenceTimeBits.createdAt);
    assert.deepEqual(witness.dateReferenceTimeBits.images, beforeWitness.dateReferenceTimeBits.images);
    assert.match(witness.dateReferenceTimeBits.modifiedAt, /^\d+$/);
    await persistedExactly([...others, expected]);
    assert.deepEqual(await session.command('presented-alerts'), []);
    return witness;
  }
  function changed(before, after, target, maximumTextFlushes = 1) {
    assert.ok(Number.isInteger(after.revision) && after.revision >= before.revision + 1
      && after.revision <= before.revision + maximumTextFlushes,
    'One revision per accepted flush; a multi-edit session may auto-flush between edits');
    assert.equal(typeof after.modifiedAt, 'number');
    assert.ok(Number.isFinite(after.modifiedAt) && after.modifiedAt >= before.modifiedAt);
    return { ...before, revision: after.revision, modifiedAt: after.modifiedAt,
      entries: before.entries.map(entry => entry.id === 'identity-line' ? target : entry) };
  }
  async function openReview(source) {
    await step.displayed('identity-line', source, { finished: true });
    await button('Review 1 character suggestion');
    const nodes = await session.waitFor(nodes => sheetSource(nodes).length === 1
      && nodes.filter(namedButton('Save links')).length === 1
      && nodes.find(namedButton('Save links')).enabled === true);
    assert.equal(sheetSource(nodes)[0].text, source);
    assert.equal(sheetSource(nodes)[0].editable, false, 'Review source is genuinely read-only');
  }
  async function sourceUnchanged(source) {
    const nodes = await session.waitFor(nodes => sheetSource(nodes).length === 1);
    assert.equal(sheetSource(nodes)[0].text, source);
  }
  async function closeReview(title) {
    await button(title);
    await session.waitFor(nodes => sheetSource(nodes).length === 0 && readyTabs(nodes));
  }
  async function phrase(text) {
    const predicate = node => node.placeholder === 'Exact words from this line';
    let nodes = await session.waitFor(nodes => nodes.filter(predicate).length === 1);
    await step.reveal(nodes.find(predicate), nodes);
    nodes = await session.waitFor(nodes => nodes.filter(predicate).length === 1
      && nodes.find(predicate).hittable && nodes.find(predicate).enabled === true);
    assert.deepEqual(await session.command('text', { target: nodes.find(predicate).path, text }), { dispatched: true });
  }
  async function insertionCounts() {
    assert.equal((await session.command('capabilities')).runID, runID);
    const counts = await session.command('script-interaction-counts');
    assert.deepEqual(Object.keys(counts).sort(),
      ['schemaVersion', 'observation', 'mergeAtStartInvocations', 'onTextEditInvocations'].sort());
    assert.equal(counts.schemaVersion, 1);
    assert.equal(counts.observation, 'actual-script-callback-invocations');
    for (const key of ['onTextEditInvocations', 'mergeAtStartInvocations']) {
      assert.ok(Number.isSafeInteger(counts[key]) && counts[key] >= 0 && counts[key] <= 1_000_000);
    }
    return counts;
  }
  let insertionGuardsChecked = false;
  async function verifyInsertionRejections(id) {
    const witness = await session.command('loaded-project');
    const persisted = ordered(await session.command('persisted-projects'));
    const counts = await insertionCounts();
    const editorState = nodes => byID(nodes, id).map(({ text, selection, firstResponder, editable }) =>
      ({ text, selection, firstResponder, editable }));
    const before = editorState(await session.command('snapshot'));
    for (const args of [
      { target: id, text: '' }, { target: id, text: '\n' }, { target: id, text: '\r' },
      { target: id, text: 'x'.repeat(65537) }, { target: id, text: 'X', start: 0 },
      { target: 'script-line-identity-line', text: 'X' },
    ]) {
      await assert.rejects(session.command('script-insert', args), /^Error: script-insert:/,
        'Unsupported payload/target must fail before any insertion');
      assert.deepEqual(await insertionCounts(), counts);
      assert.deepEqual(editorState(await session.command('snapshot')), before);
      assert.deepEqual(await session.command('loaded-project'), witness);
      assert.deepEqual(ordered(await session.command('persisted-projects')), persisted);
    }
    insertionGuardsChecked = true;
  }
  async function verifySelectedDeletionRejections(id, source, selection) {
    const witness = await session.command('loaded-project');
    const persisted = ordered(await session.command('persisted-projects'));
    const counts = await insertionCounts();
    async function unchanged(start, end) {
      await step.waitEditor(id, source, start, end);
      assert.deepEqual(await insertionCounts(), counts);
      assert.deepEqual(await session.command('loaded-project'), witness);
      assert.deepEqual(ordered(await session.command('persisted-projects')), persisted);
    }
    // Extra fields are rejected even with a valid nonempty selection.
    for (const extra of [{ text: '' }, { start: 0 }, { replacement: '' }]) {
      await assert.rejects(session.command('script-delete-selection', { target: id, ...extra }),
        /^Error: script-delete-selection:/);
      await unchanged(selection.start, selection.end);
    }
    // At zero a generic delete could merge; this adapter must reject untouched.
    for (const caret of [0, source.length]) {
      await session.command('selection', { target: id, start: caret, end: caret });
      await step.waitEditor(id, source, caret, caret);
      await assert.rejects(session.command('script-delete-selection', { target: id }), /^Error: script-delete-selection:/);
      await unchanged(caret, caret);
    }
    await assert.rejects(session.command('script-delete-selection', { target: 'workspace-project' }),
      /^Error: script-delete-selection:/);
    await unchanged(source.length, source.length);
    await session.command('selection', { target: id, start: selection.start, end: selection.end });
    await unchanged(selection.start, selection.end);
  }
  async function editSource(source, edits) {
    await step.displayed('identity-line', source, { finished: true });
    assert.ok((await session.command('keys')).some(command => keyIs(command, '\r', ['command'])));
    assert.deepEqual(await step.key('\r', ['command']), { dispatched: true });
    const id = 'script-editor-identity-line';
    let nodes = await session.waitFor(nodes => focusedEditors(nodes).length === 1
      && byID(nodes, id).length === 1 && byID(nodes, id)[0].firstResponder && byID(nodes, id)[0].text === source);
    await step.reveal(byID(nodes, id)[0], nodes);
    nodes = await session.waitFor(nodes => byID(nodes, id).length === 1
      && byID(nodes, id)[0].hittable && byID(nodes, id)[0].editable && byID(nodes, id)[0].firstResponder);
    assert.equal(byID(nodes, id)[0].smartInsertDeleteDisabled, true);
    let current = source;
    // Both prefix/suffix replacements remain in ONE mounted editing session.
    for (const edit of edits) {
      await session.command('selection', { target: id, start: edit.start, end: edit.end });
      await step.waitEditor(id, current, edit.start, edit.end);
      if (!insertionGuardsChecked) await verifyInsertionRejections(id);
      if (edit.delete) await verifySelectedDeletionRejections(id, current, edit);
      const countsBefore = await insertionCounts();
      if (edit.delete) {
        assert.deepEqual(await session.command('script-delete-selection', { target: id }),
          { dispatched: true, delegateAcceptedDeletion: true, coverage: 'public-script-selection-deletion-delegate-contract' });
      } else {
        assert.deepEqual(await session.command('script-insert', { target: id, text: edit.text }),
          { dispatched: true, delegateAcceptedInsertion: true, coverage: 'public-script-insertion-delegate-contract' });
      }
      const countsAfter = await insertionCounts();
      const callbackDelta = countsAfter.onTextEditInvocations - countsBefore.onTextEditInvocations;
      const mergeDelta = countsAfter.mergeAtStartInvocations - countsBefore.mergeAtStartInvocations;
      console.log(JSON.stringify({ command: edit.delete ? 'script-delete-selection' : 'script-insert',
        onTextEditInvocationDelta: callbackDelta, mergeAtStartInvocationDelta: mergeDelta }));
      assert.equal(callbackDelta, 1, 'Exactly one real edit callback; duplicate or missing callbacks fail without retry');
      assert.equal(mergeDelta, 0, 'Insertion/selected deletion must not dispatch a line merge');
      current = edit.expectedText;
      await step.waitEditor(id, current, edit.start + (edit.delete ? 0 : edit.text.length));
    }
    await step.finishEditor();
    await step.displayed('identity-line', current, { finished: true });
    await step.workspaceCommand('s');
  }
  async function reopen(project) {
    await activate(node => node.identifier === 'workspace-project');
    let nodes = await session.waitFor(nodes => nodes.filter(node => node.placeholder === 'Find a project').length === 1);
    const find = nodes.find(node => node.placeholder === 'Find a project');
    assert.ok(find.enabled && find.hittable);
    await session.command('text', { target: find.path, text: project.title });
    await session.waitFor(nodes => nodes.some(node => node.text === `${project.title} · 1 scene`));
    await button('Open project');
    await session.waitFor(nodes => header(nodes, project.title));
    return session.command('loaded-project');
  }

  for (const test of [...identityReviewCases, identityUnlinkCompanion]) {
    try {
      const others = await session.command('persisted-projects');
      const input = identityReviewInput(test);
      input.title = `Identity ${test.key} ${randomUUID()}`;
      assert.deepEqual(await session.command('import-json', { text: JSON.stringify(input) }), { dispatched: true, projectChanged: true });
      await session.waitFor(nodes => header(nodes, input.title));
      await step.selectTab('Script');
      const before = await step.saved(project => project.title === input.title);
      assert.notEqual(before.id, input.id);
      assert.equal(before.revision, 0);
      assert.deepEqual(payload(before), payload(input));
      const beforeWitness = await session.command('loaded-project');
      assert.deepEqual(beforeWitness.project, before);
      await persistedExactly([...others, before]);

      // Confirm/Cancel twice: each reopening must still offer the original proposal.
      // loaded-project rejects this controller; while open ONLY persistence is observed.
      for (let pass = 0; pass < 2; pass++) {
        await openReview(test.source);
        await button('Confirm');
        await session.waitFor(nodes => nodes.some(node => node.text === 'Confirmed link')
          && nodes.filter(namedButton('Confirm')).length === 0);
        await sourceUnchanged(test.source);
        await persistedExactly([...others, before]);
        if (test.key === 'emoji-prefix' && pass === 1) {
          await phrase('waits');
          await session.waitFor(nodes => nodes.filter(node => node.text === 'Occurrence in scene').length === 1);
          // The reviewed Randy row now says Unlink, leaving exactly one Keep unlinked.
          await button('Keep unlinked');
          await session.waitFor(nodes => nodes.some(node => node.text === 'Kept unlinked'));
          await phrase('not here');
          await session.waitFor(nodes => nodes.filter(node => node.text === 'Those exact words are not in this line.').length === 1);
          await sourceUnchanged(test.source);
          await persistedExactly([...others, before]);
        }
        await closeReview('Cancel');
        assert.deepEqual(await session.command('loaded-project'), beforeWitness,
          'Cancel restores the complete loaded state and exact date bits; no in-sheet model claim');
        await persistedExactly([...others, before]);
      }
      await openReview(test.source);
      await button(test.unlink ? 'Keep unlinked' : 'Confirm');
      await session.waitFor(nodes => nodes.some(node => node.text === (test.unlink ? 'Kept unlinked' : 'Confirmed link')));
      await sourceUnchanged(test.source);
      await persistedExactly([...others, before]);
      await closeReview('Save links');
      await step.workspaceCommand('s');
      const reviewed = await step.saved(project => project.id === before.id && project.revision === before.revision + 1);
      const confirmed = { ...line(before).characterLinks[0], isConfirmed: true };
      if (test.unlink) delete confirmed.characterId;
      assert.deepEqual(line(reviewed).characterLinks, [confirmed], 'Review preserves the original annotation ID/range/wording, with exact confirmation or explicit unlink');
      const reviewedExpected = changed(before, reviewed, { ...line(before), characterLinks: [confirmed] });
      const reviewedWitness = await fullState(beforeWitness, reviewedExpected, others);

      await editSource(test.source, test.edits);
      const after = await step.saved(project => project.id === before.id && line(project).text === test.result);
      let links = [];
      if (!test.noLinks) {
        if (test.reassign) {
          assert.equal(line(after).characterLinks.length, 1);
          const id = line(after).characterLinks[0].id;
          uuid(id); assert.notEqual(id, confirmed.id);
          links = [{ id, characterId: 'jason', location: 0, length: 5, text: 'Jason', isConfirmed: false }];
        } else links = [{ ...confirmed, location: test.resultLocation }];
      }
      const actualWords = line(after).words;
      assert.equal(actualWords.length, test.words.length);
      const oldWordIDs = new Set(line(reviewed).words.map(value => value.id));
      const newIDs = new Set();
      const words = test.words.map((expected, index) => {
        if (expected.id !== null) return expected;
        const id = actualWords[index].id;
        uuid(id); assert.ok(!oldWordIDs.has(id)); assert.ok(!newIDs.has(id)); newIDs.add(id);
        return { ...expected, id };
      });
      const expected = changed(reviewed, after, { ...line(reviewed), text: test.result, words, characterLinks: links }, test.edits.length);
      const afterWitness = await fullState(reviewedWitness, expected, others);
      console.log(JSON.stringify({ journey: 'AUT-J06', case: test.key, textInputDispatches: test.edits.length,
        nativeEditorSessions: 1, observedRevisionDelta: after.revision - reviewed.revision,
        exactCoreEditBatchVerified: false, retirementAllowed: false }));
      assert.deepEqual((await reopen(startup)).project, startup);
      assert.deepEqual(await reopen(expected), afterWitness, 'Actual browser reopen preserves every field and exact date bits');
      await persistedExactly([...others, expected]);
      console.log(`PASS: AUT-J06/review-and-edit/${test.key}`);

      if (test.key === 'emoji-prefix') {
        // Additional real selected-deletion interaction, not frozen ::0007's
        // duplicate-name ambiguity or final-text-only reconciliation fallback.
        await editSource(test.result, [{ start: 0, end: 3, delete: true, expectedText: test.source }]);
        const deleted = await step.saved(project => project.id === before.id && line(project).text === test.source);
        const deletedExpected = changed(expected, deleted, { ...line(reviewed), characterLinks: [confirmed] });
        await fullState(afterWitness, deletedExpected, others);
        console.log('PASS: AUT-J06/review-and-edit/companion-selected-emoji-deletion');
      }
    } catch (error) {
      throw new Error(`AUT-J06/review-and-edit/${test.key} failed; no mutation was retried`, { cause: error });
    }
  }
}
