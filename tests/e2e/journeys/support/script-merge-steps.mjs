import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { scriptAuthoringSteps, byID, readyTabs, focusedEditors, keyIs } from './script-authoring-steps.mjs';
import { authoredPayload } from './json-model-cases.mjs';
import { observePresentedError } from '../../support/presented-error.mjs';

const ordered = projects => [...projects].sort((a, b) => a.id.localeCompare(b.id));
const header = (nodes, title) => byID(nodes, 'workspace-project').find(node => node.title === title && node.hittable);
const content = project => { const value = structuredClone(project); delete value.modifiedAt; delete value.revision; return value; };
const entry = (project, id) => {
  const matches = project.entries.filter(value => value.id === id);
  assert.equal(matches.length, 1, `Exactly one saved entry has identity ${id}`); return matches[0];
};

export function scriptMergeSteps(session) {
  const step = scriptAuthoringSteps(session);
  let runID, lastInteractionCounts;
  async function initialize() {
    const capabilities = await session.command('capabilities');
    for (const command of ['delete-backward', 'return', 'import-json', 'loaded-project', 'presented-alerts', 'script-interaction-counts']) {
      assert.ok(capabilities.commands.includes(command), `Matching native app advertises ${command}`);
    }
    assert.equal(capabilities.scriptInteractionCountsSchemaVersion, 1);
    assert.equal(typeof capabilities.runID, 'string');
    assert.equal(capabilities.runID.length, 36);
    runID = capabilities.runID;
    assert.ok(capabilities.publicTextInputCommands?.includes('delete-backward'),
      'Deletion is the public text input route, not a semantic merge or private handler');
    await session.waitFor(readyTabs);
    await step.selectTab('Script');
    await step.workspaceCommand('s');
    return step.saved(project => project.title === 'YAM MAN');
  }
  async function importCase(test) {
    const others = await session.command('persisted-projects');
    const input = test.makeInput(); input.title = `Merge ${test.key} ${randomUUID()}`;
    assert.deepEqual(await session.command('import-json', { text: JSON.stringify(input) }),
      { dispatched: true, projectChanged: true });
    await session.waitFor(nodes => !!header(nodes, input.title));
    await step.selectTab('Script');
    const before = await step.saved(project => project.title === input.title && !others.some(old => old.id === project.id));
    assert.deepEqual(authoredPayload(before), authoredPayload(input),
      'Production import preserves literal fixture content; only its documented identity/date/revision envelope is reset');
    assert.deepEqual((await session.command('loaded-project')).project, before);
    await unchangedOthers(others, before.id);
    return { before, others };
  }
  async function unchangedOthers(others, projectID) {
    const saved = await session.command('persisted-projects');
    assert.equal(saved.length, others.length + 1, 'One fixture import creates exactly one package');
    assert.deepEqual(ordered(saved.filter(project => project.id !== projectID)), ordered(others),
      'Every other saved project remains exactly unchanged');
  }
  async function revealMatching(predicate) {
    let nodes = await session.waitFor(nodes => nodes.filter(predicate).length === 1);
    await step.reveal(nodes.find(predicate), nodes);
    nodes = await session.waitFor(nodes => nodes.filter(node => predicate(node) && node.hittable).length === 1);
    return nodes.find(node => predicate(node) && node.hittable);
  }
  async function activateMatching(predicate) {
    const node = await revealMatching(predicate);
    assert.equal(node.enabled, true, 'The actual UIControl is enabled');
    await session.command('activate', { target: node.path });
  }
  async function focusEntry(project, targetID) {
    const target = entry(project, targetID);
    const sceneEntries = project.entries.filter(value => value.sceneId === target.sceneId).sort((a, b) => a.order - b.order);
    await session.waitFor(nodes => sceneEntries.every(value => byID(nodes, `script-line-${value.id}`).length === 1));
    // Import selects the first source row. Other rows are selected through the
    // real Layers UIButton, never ScriptScreenController.beginEditing or store.
    if (targetID !== sceneEntries[0].id) {
      const disclosure = node => node.identifier === 'preview-layers-disclosure';
      const button = await revealMatching(disclosure);
      assert.equal(button.label, 'Expand Layers', 'Each fixture begins with collapsed Layers');
      await session.command('activate', { target: button.path });
      await session.waitFor(nodes => byID(nodes, 'preview-layers-disclosure').some(node => node.label === 'Collapse Layers'));
      const speaker = project.characters.find(value => value.id === target.characterId)?.name ?? 'Dialogue';
      const title = target.kind === 'dialogue' ? `${speaker}\n${target.text}` : `${target.text}\n0.0 s owned`;
      // Direction titles' duration formatting is observed by prefix instead of
      // reimplementing ScrivFormat. Exact selected entry/text is checked below.
      const matches = node => node.enabled === true && (target.kind === 'dialogue'
        ? node.title === title : node.title?.startsWith(target.text + '\n') && node.title.endsWith(' owned'));
      let nodes = await session.waitFor(nodes => nodes.filter(matches).length > 0);
      let buttons = nodes.filter(matches).sort((a, b) => a.frame.x - b.frame.x || a.frame.y - b.frame.y);
      const sameTitleEntries = sceneEntries.filter(value => value.kind === target.kind && value.text === target.text
        && value.characterId === target.characterId);
      assert.equal(buttons.length, sameTitleEntries.length, 'Only exact source row controls match the Layers title');
      const ordinal = sameTitleEntries.findIndex(value => value.id === targetID);
      assert.ok(ordinal >= 0);
      await step.reveal(buttons[ordinal], nodes);
      nodes = await session.command('snapshot');
      buttons = nodes.filter(matches).sort((a, b) => a.frame.x - b.frame.x || a.frame.y - b.frame.y);
      assert.equal(buttons.length, sameTitleEntries.length);
      assert.equal(buttons[ordinal].hittable, true, 'Existing source row must be reachable before selecting it');
      await session.command('activate', { target: buttons[ordinal].path });
      await activateMatching(disclosure);
      await session.waitFor(nodes => byID(nodes, 'preview-layers-disclosure').some(node => node.label === 'Expand Layers'));
    }
    assert.ok((await session.command('keys')).some(command => keyIs(command, '\r', ['command'])),
      'Installed native Command-Return edit toggle is enabled');
    await step.key('\r', ['command']);
    let nodes = await session.waitFor(nodes => focusedEditors(nodes).length === 1
      && focusedEditors(nodes)[0].identifier === `script-editor-${targetID}`
      && focusedEditors(nodes)[0].text === target.text);
    await step.reveal(focusedEditors(nodes)[0], nodes);
    nodes = await session.waitFor(nodes => byID(nodes, `script-editor-${targetID}`).some(node => node.firstResponder && node.hittable));
    assert.equal(byID(nodes, `script-editor-${targetID}`)[0].editable, true);
    // Navigation/focus must not change the imported baseline before mutation.
    assert.deepEqual((await session.command('loaded-project')).project, project);
    return `script-editor-${targetID}`;
  }
  async function select(editorID, text, start, end = start) {
    await session.command('selection', { target: editorID, start, end });
    await step.waitEditor(editorID, text, start, end);
  }
  async function deleteBackward(editorID) {
    // Once only. An uncertain outcome is a failure, not a reason to retry.
    assert.deepEqual(await session.command('delete-backward', { target: editorID }), { dispatched: true });
  }
  async function interactionCounts() {
    assert.equal((await session.command('capabilities')).runID, runID,
      'Counter comparisons remain in the same isolated app process');
    const counts = await session.command('script-interaction-counts');
    assert.deepEqual(Object.keys(counts).sort(),
      ['schemaVersion', 'observation', 'mergeAtStartInvocations', 'onTextEditInvocations'].sort(),
      'Observation returns only bounded callback totals and schema metadata');
    assert.equal(counts.schemaVersion, 1);
    assert.equal(counts.observation, 'actual-script-callback-invocations');
    for (const key of ['mergeAtStartInvocations', 'onTextEditInvocations']) {
      assert.ok(Number.isSafeInteger(counts[key]) && counts[key] >= 0 && counts[key] <= 1_000_000);
      if (lastInteractionCounts) assert.ok(counts[key] >= lastInteractionCounts[key],
        'Process totals never reset on observation, import or editor recreation');
    }
    lastInteractionCounts = counts;
    return counts;
  }
  async function scriptInputState(editorID) {
    const matches = byID(await session.command('snapshot'), editorID);
    assert.equal(matches.length, 1, 'Observe the exact mounted script editor');
    const { identifier, text, selection, firstResponder, editable, smartInsertDeleteDisabled } = matches[0];
    return { identifier, text, selection, firstResponder, editable, smartInsertDeleteDisabled };
  }
  async function verifyInteractionObservationGuards(project, editorID) {
    const before = await session.command('loaded-project');
    const savedBefore = await session.command('persisted-projects');
    const editorBefore = await scriptInputState(editorID);
    const countsBefore = await interactionCounts();
    assert.deepEqual(before.project, project);
    for (let pass = 0; pass < 2; pass++) {
      assert.deepEqual(await interactionCounts(), countsBefore, 'Reading counters does not reset or increment them');
    }
    for (const extra of [{ reset: true }, { target: editorID }]) {
      await assert.rejects(session.command('script-interaction-counts', extra),
        /Synthetic interaction-count observation is unavailable or invalid/);
    }
    assert.deepEqual(await interactionCounts(), countsBefore, 'Rejected extra parameters cannot mutate counter totals');
    assert.deepEqual(await session.command('loaded-project'), before, 'Observation and rejected parameters preserve the loaded model and Date bits');
    assert.deepEqual(await session.command('persisted-projects'), savedBefore, 'Observation and rejected parameters preserve every saved project');
    assert.deepEqual(await scriptInputState(editorID), editorBefore, 'Observation and rejected parameters preserve editor text, selection, focus and configuration');
    return countsBefore;
  }
  async function verifyCommandGuards(project, editorID) {
    const before = await session.command('loaded-project');
    await assert.rejects(session.command('delete-backward', { target: editorID, text: '' }),
      /Delete backward requires the focused editable script text view/);
    await assert.rejects(session.command('delete-backward', { target: 'workspace-tabs' }),
      /Delete backward requires the focused editable script text view/);
    assert.deepEqual(await session.command('loaded-project'), before, 'Rejected command parameters and non-text target are read-only');
    assert.deepEqual(before.project, project);
  }
  async function finishAndSave(project, id, text) {
    await step.finishEditor();
    await step.displayed(id, text, { finished: true });
    await step.workspaceCommand('s');
    const saved = await step.saved(value => value.id === project.id && value.revision >= project.revision
      && value.entries.find(value => value.id === id)?.text === text);
    assert.deepEqual(saved, project, 'Finishing and Save preserve every accepted project field');
    assert.deepEqual((await session.command('loaded-project')).project, project, 'Saved state equals the actual loaded Swift model');
    assert.deepEqual(await session.command('presented-alerts'), []);
  }
  async function history(before, after, targetID) {
    // This supplementary fixture explicitly supplies empty annotations and no
    // cues, so restore bootstrap/materialization has nothing to synthesize.
    await step.workspaceHistory();
    const undone = await step.saved(value => value.id === before.id && value.revision > after.revision
      && value.entries.length === before.entries.length);
    assert.deepEqual(content(undone), content(before), 'One workspace undo restores complete original content, including word metadata');
    for (const value of before.entries) await step.displayed(value.id, value.text);
    assert.deepEqual((await session.command('loaded-project')).project, undone);
    await step.workspaceHistory(true);
    const redone = await step.saved(value => value.id === before.id && value.revision > undone.revision
      && value.entries.length === after.entries.length);
    assert.deepEqual(content(redone), content(after), 'One workspace redo restores exact merged content and stable identities');
    await step.displayed(targetID, entry(after, targetID).text);
    assert.deepEqual((await session.command('loaded-project')).project, redone);
    return redone;
  }
  async function reopen(project, other) {
    async function open(value) {
      await activateMatching(node => node.identifier === 'workspace-project');
      const field = await revealMatching(node => node.placeholder === 'Find a project');
      await session.command('text', { target: field.path, text: value.title });
      await session.waitFor(nodes => nodes.some(node => node.text === `${value.title} · ${value.scenes.length} scene${value.scenes.length === 1 ? '' : 's'}`));
      await activateMatching(node => node.title === 'Open project');
      await session.waitFor(nodes => !!header(nodes, value.title));
      const loaded = await session.command('loaded-project');
      assert.equal(loaded.project.id, value.id, 'Browser Open changed the actual loaded model');
      return loaded;
    }
    const before = await session.command('loaded-project');
    assert.deepEqual(before.project, project);
    assert.deepEqual((await open(other)).project, other);
    assert.deepEqual(await open(project), before, 'Save/browser-reopen retains the complete merged model and exact Date storage witnesses');
  }
  async function rejected(test, before, others, editorID) {
    await select(editorID, entry(before, test.target).text, 0);
    const loadedBefore = await session.command('loaded-project');
    assert.deepEqual(loadedBefore.project, before);
    await deleteBackward(editorID);
    assert.deepEqual(await session.command('loaded-project'), loadedBefore,
      'Actual loaded model and Date bits are unchanged immediately after rejected dispatch');
    await observePresentedError(session, test.error);
    // Read-only observation retains exact synthetic package isolation while a
    // public validation alert is present. It never dismisses or activates it.
    for (let pass = 0; pass < 2; pass++) {
      assert.deepEqual(await session.command('loaded-project'), loadedBefore,
        'Actual loaded model and Date bits remain unchanged with the rejection presented');
      const saved = await session.command('persisted-projects');
      assert.deepEqual(saved.find(value => value.id === before.id), before,
        'Rejected merge leaves the complete saved project, revision, dates and source timing unchanged');
      await unchangedOthers(others, before.id);
      const nodes = await session.command('snapshot');
      const source = byID(nodes, editorID).concat(byID(nodes, `script-line-${test.target}`));
      assert.equal(source.length, 1, 'The original source row still has one mounted text surface');
      assert.equal(source[0].text, entry(before, test.target).text);
    }
  }
  return { ...step, initialize, importCase, unchangedOthers, focusEntry, select, deleteBackward,
    interactionCounts, scriptInputState, verifyInteractionObservationGuards,
    verifyCommandGuards, finishAndSave, history, reopen, rejected };
}

export function assertMerged(test, before, after, removedID) {
  const previous = entry(before, 'a'), removed = entry(before, removedID), merged = entry(after, 'a');
  assert.equal(after.id, before.id);
  assert.equal(after.revision, before.revision + 1, 'One accepted merge is one project revision');
  assert.equal(after.entries.length, before.entries.length - 1);
  assert.deepEqual(after.entries.map(value => value.id).sort(), before.entries.filter(value => value.id !== removedID).map(value => value.id).sort());
  assert.equal(merged.text, test.expectedText, 'Merge preserves exact source UTF-16 without inserting whitespace');
  assert.equal(merged.text, previous.text + removed.text);
  assert.equal(merged.ownedDurationMs, previous.ownedDurationMs, 'Previous row keeps its existing owned time');
  for (const field of ['id', 'sceneId', 'order', 'kind', 'color', 'characterId']) assert.equal(merged[field], previous[field]);
  for (const original of before.entries.filter(value => !['a', removedID].includes(value.id))) {
    assert.deepEqual(entry(after, original.id), original, 'Every unrelated entry is exactly unchanged');
  }
  for (const field of ['scenes', 'characters', 'images', 'audioAssets', 'audioClips', 'audioVolume']) {
    assert.deepEqual(after[field], before[field], `Merge preserves all ${field}`);
  }
  if (merged.kind === 'dialogue') {
    assert.deepEqual(merged.words.map(value => value.text), merged.text.match(/\S+/gu) ?? []);
    let end = 0;
    for (const value of merged.words) {
      assert.ok(Number.isInteger(value.startMs) && Number.isInteger(value.endMs)
        && value.startMs >= end && value.endMs > value.startMs && value.endMs <= merged.ownedDurationMs);
      end = value.endMs;
    }
    assert.equal(end, merged.ownedDurationMs);
  }
  if (test.preserveWordIDs) {
    const original = [...previous.words, ...removed.words];
    assert.deepEqual(merged.words.map(value => value.id), original.map(value => value.id));
    assert.deepEqual(merged.words.map(value => value.timingSource), original.map(value => value.timingSource));
  }
  if (test.expectedWordTimes) assert.deepEqual(merged.words.map(value => [value.startMs, value.endMs]), test.expectedWordTimes);
  assert.deepEqual(after.cues.map(value => value.id).sort(), before.cues.map(value => value.id).sort(), 'Every image cue survives');
  if (test.key === 'touching-annotations') {
    assert.equal(merged.words.length, 1);
    assert.deepEqual(merged.characterLinks.map(({ id, ...value }) => value), [
      { characterId: 'person', location: 0, length: 4, text: 'Alex', isConfirmed: true },
      { characterId: 'person', location: 4, length: 4, text: 'Alex', isConfirmed: true },
    ]);
    assert.equal(merged.characterLinks[0].id, 'link');
    assert.equal(new Set(merged.characterLinks.map(value => value.id)).size, 2);
  }
  if (test.key === 'all-cues-retained') {
    assert.deepEqual(after.cues, [
      { id: 'cue', sceneId: 's', label: '', startMs: 1020, endMs: 2320, prompt: '',
        startAnchor: { entryId: 'a', offsetMs: 1020 }, authoredDurationMs: 1300 },
      { id: 'second', sceneId: 's', label: '', startMs: 2100, endMs: 3000, prompt: '',
        startAnchor: { entryId: 'a', offsetMs: 2100 }, authoredDurationMs: 1500 },
    ]);
  }
  if (test.key === 'zero-owned-direction-roundtrip') {
    assert.equal(merged.coverageDurationMs, 5000);
    assert.equal(merged.ownedDurationMs, 0);
    assert.deepEqual(merged.words, []);
  }
}
