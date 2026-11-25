import assert from 'node:assert/strict';
import { lstat, readdir, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { ScrivSession } from '../../../cli/scriv.mjs';
import { waitForSavedProject } from '../support/saved-projects.mjs';
import { fixture } from './support/generation-review-fixture.mjs';
import { nodeWithID as byID, sortedProjects, reviewSteps } from './support/generation-review-steps.mjs';
import { coverageSteps } from './support/picture-coverage-steps.mjs';

// Real public input -> retained invalid draft -> owned cold reload -> correction.
// No crash window, injected journal, production API, provider or alert dispatch.
const oversized = 'x'.repeat(29999) + '🎬'; // 30,001 UTF-16 units, 30,003 UTF-8 bytes.
const corrected = 'Cafe\u0301 🎬 recovery corrected';
const refusal = 'Image direction exceeds 30,000 UTF-16 characters. Shorten the draft before applying it; the exact draft remains saved on this Mac.';
const cases = ['retain-rejected-direction', 'cold-recovery', 'repeated-cold-recovery', 'correct-and-save', 'cold-clean-state',
  'review-recovered-direction-after-undo'];
assert.ok(process.argv.slice(2).every(arg => arg === '--list-cases'), 'Unknown argument');
if (process.argv.includes('--list-cases')) {
  console.log(JSON.stringify({ journey: 'cue-draft-recovery', nativeVerified: false, status: 'prepared-not-run', cases,
    excluded: ['crash durability', 'PendingProjectSaveJournal replay', 'EditorDraftJournal', 'account conflicts',
      'discard alert', 'CAS contention', 'storage exhaustion', 'physical keyboard parity'] }, null, 2));
} else {
  assert.ok(process.env.SCRIV_E2E_APP, 'Requires a verified automation-enabled Catalyst bundle on macOS');
  let session = await ScrivSession.launch(process.env.SCRIV_E2E_APP, { persistent: true });
  let stage = 'setup';
  const root = session.root;
  // Read-only host evidence, not native command results. Only app-owned synthetic
  // journal bytes are inspected; never create/modify/clear a recovery record.
  async function journals() {
    const directory = join(root, 'CuePromptDrafts');
    const info = await lstat(directory);
    assert.ok(info.isDirectory() && !info.isSymbolicLink());
    const result = [];
    for (const name of (await readdir(directory)).sort()) {
      if (!name.endsWith('.json')) continue;
      assert.match(name, /^[a-f0-9]{64}\.json$/);
      const path = join(directory, name), stat = await lstat(path);
      assert.ok(stat.isFile() && !stat.isSymbolicLink() && stat.nlink === 1);
      assert.ok(stat.size < 2 * 1024 * 1024);
      const bytes = await readFile(path, 'utf8');
      result.push({ name, bytes, record: JSON.parse(bytes) });
    }
    return result;
  }
  async function activate(predicate) {
    const nodes = await session.waitFor(nodes => nodes.some(node => predicate(node) && node.hittable && node.enabled !== false));
    const node = nodes.find(node => predicate(node) && node.hittable && node.enabled !== false);
    await session.command('activate', { target: node.path });
  }
  async function open(project) {
    await activate(node => node.identifier === 'workspace-project');
    const nodes = await session.waitFor(nodes => nodes.some(node => node.placeholder === 'Find a project' && node.hittable));
    await session.command('text', { target: nodes.find(node => node.placeholder === 'Find a project' && node.hittable).path, text: project.title });
    await session.waitFor(nodes => nodes.some(node => node.text === `${project.title} · 1 scene`));
    await activate(node => node.title === 'Open project');
    // Opening changes the underlying title before the browser's animated dismissal.
    // Wait for the real workspace control to become reachable before observing it.
    await session.waitFor(nodes => {
      const control = byID(nodes, 'workspace-project');
      return control?.title === project.title && control.hittable && control.enabled;
    });
    assert.deepEqual((await session.command('loaded-project')).project, project);
  }
  async function relaunch(project) {
    const old = await session.command('capabilities');
    session = await session.relaunch();
    const next = await session.command('capabilities');
    assert.equal(session.root, root); assert.equal(next.runID, old.runID);
    assert.notEqual(next.sessionID, old.sessionID);
    assert.equal(next.workspace.resumed, true);
    await open(project); // Normal UI open, startup intentionally skips recovery.
  }
  async function retained(baseline, allSaved, record) {
    await session.waitFor(nodes => byID(nodes, 'generation-optional-direction')?.text === oversized
      && nodes.some(node => node.text === refusal));
    assert.deepEqual(await session.command('loaded-project'), baseline, 'Rejected draft never changes loaded canonical model or exact date bits');
    assert.deepEqual(sortedProjects(await session.command('persisted-projects')), allSaved, 'Both complete saved packages are unchanged');
    assert.deepEqual(await session.command('presented-alerts'), [], 'No unsupported alert route');
    const actual = await journals();
    assert.equal(actual.length, 1, 'Exactly one local cue draft, no duplicate on retry');
    assert.equal(actual[0].record.text, oversized);
    assert.equal(actual[0].record.sourcePrompt, '');
    assert.equal(actual[0].record.scope.projectID, baseline.project.id);
    assert.equal(actual[0].record.scope.cueID, 'review-cue');
    assert.equal(actual[0].record.scope.packagePath, join(root, 'Projects', baseline.project.id + '.scriv'));
    if (record) assert.deepEqual(actual, record, 'Cold retry preserves exact journal bytes and revision');
    assert.deepEqual((await session.command('image-evidence')).jobs, [], 'No provider jobs started');
    return actual;
  }
  try {
    const capability = await session.command('capabilities');
    for (const command of ['import-json', 'loaded-project', 'persisted-projects', 'image-evidence', 'presented-alerts'])
      assert.ok(capability.commands.includes(command));
    await session.waitFor(nodes => byID(nodes, 'workspace-tabs')?.hittable);
    await session.command('key', { input: 's', modifiers: ['command'] });
    const sentinel = await waitForSavedProject(session, project => project.title === 'YAM MAN');
    const input = structuredClone(fixture); input.title = 'Synthetic cue recovery';
    assert.deepEqual(await session.command('import-json', { text: JSON.stringify(input) }), { dispatched: true, projectChanged: true });
    const project = await waitForSavedProject(session, value => value.title === input.title);
    assert.deepEqual(project.cues, input.cues); assert.deepEqual(project.entries, input.entries);
    assert.deepEqual(project.characters, input.characters);
    const baseline = await session.command('loaded-project');
    assert.deepEqual(baseline.project, project);
    const saved = sortedProjects([sentinel, project]);
    stage = cases[0];
    // Package publication does not imply the async composer recovery read is ready.
    await session.waitFor(nodes => byID(nodes, 'generation-optional-direction')?.editable === true);
    const prompt = await reviewSteps(session).reveal('generation-optional-direction');
    assert.equal(prompt.editable, true);
    await session.command('text', { target: prompt.path, text: oversized });
    const draft = await retained(baseline, saved);
    for (stage of cases.slice(1, 3)) { await relaunch(project); await retained(baseline, saved, draft); }
    stage = cases[3];
    const editor = await reviewSteps(session).reveal('generation-optional-direction');
    assert.equal(editor.editable, true);
    await session.command('text', { target: editor.path, text: corrected });
    const committed = await waitForSavedProject(session, value => value.id === project.id && value.cues[0].prompt === corrected);
    const expected = structuredClone(project); expected.cues[0].prompt = corrected;
    expected.revision += 1; expected.modifiedAt = committed.modifiedAt;
    assert.ok(Number.isFinite(committed.modifiedAt) && committed.modifiedAt >= project.modifiedAt);
    assert.deepEqual(committed, expected, 'Exactly one corrected prompt revision; unrelated text, timing, characters and cue metadata preserved');
    await session.waitFor(nodes => byID(nodes, 'generation-optional-direction')?.text === corrected
      && !nodes.some(node => node.text === refusal || node.text === 'Direction saved in local recovery until the project save completes.'));
    assert.deepEqual(await journals(), [], 'Recovery journal is empty when observed after corrected canonical persistence');
    const correctedLoaded = await session.command('loaded-project');
    assert.deepEqual(correctedLoaded.project, expected);
    stage = cases[4]; await relaunch(expected);
    await session.waitFor(nodes => byID(nodes, 'generation-optional-direction')?.editable
      && byID(nodes, 'generation-optional-direction')?.text === corrected);
    assert.deepEqual(await session.command('loaded-project'), correctedLoaded);
    assert.deepEqual(sortedProjects(await session.command('persisted-projects')), sortedProjects([sentinel, expected]));
    assert.deepEqual(await journals(), []);
    assert.deepEqual((await session.command('image-evidence')).jobs, []);
    console.log('PASS: cue-draft-recovery: rejected text retained across two owned relaunches, corrected once and clean on third reopen');

    stage = cases[5];
    const review = coverageSteps(session);
    const intervening = 'Canonical direction before Undo';
    const recovery = 'Recovered direction after Undo 🎬';
    const reviewStatus = 'Recovered direction — review before replacing the current prompt.';
    async function enterDirection(text) {
      const field = await reviewSteps(session).reveal('generation-optional-direction');
      assert.equal(field.editable, true);
      await session.command('text', { target: field.path, text });
      await session.waitFor(nodes => byID(nodes, 'generation-optional-direction')?.text === text);
    }
    async function savedDirection(previous, text, restoredByUndo = false) {
      const actual = await waitForSavedProject(session, value => value.id === previous.id && value.cues[0].prompt === text);
      const next = structuredClone(previous);
      next.cues[0].prompt = text;
      next.revision += 1; next.modifiedAt = actual.modifiedAt;
      // Undo backfills mention metadata on these two legacy dialogue entries.
      if (restoredByUndo) {
        for (const entry of next.entries) entry.characterLinks = [];
      }
      assert.ok(Number.isFinite(actual.modifiedAt) && actual.modifiedAt >= previous.modifiedAt);
      assert.deepEqual(actual, next, 'Only the expected changes are present in the new revision');
      return actual;
    }
    await enterDirection(intervening);
    const accepted = await savedDirection(expected, intervening);
    await session.waitFor(nodes => !nodes.some(node => node.text === 'Direction saved in local recovery until the project save completes.'));
    assert.deepEqual(await journals(), []);
    await enterDirection(oversized);
    await session.waitFor(nodes => nodes.some(node => node.text === refusal));
    const conflicting = await journals();
    assert.equal(conflicting.length, 1);
    assert.equal(conflicting[0].record.sourcePrompt, intervening);
    assert.equal(conflicting[0].record.text, oversized);
    await session.command('end-editing');
    await review.tab('Storyboard');
    // Focus can settle asynchronously after leaving the editor. Wait for the
    // workspace action and dispatch Undo once, without retrying a mutation.
    const undoReady = async () => {
      const key = (await session.command('keys')).find(key => key.input === 'z' && key.modifiers.length === 1 && key.modifiers[0] === 'command');
      return key?.responderType === 'ScrivWorkspaceController' && key.action === 'undoProject';
    };
    const undoDeadline = performance.now() + 5000;
    let canUndo = await undoReady();
    while (!canUndo && performance.now() < undoDeadline) {
      await new Promise(resolve => setTimeout(resolve, 50));
      canUndo = await undoReady();
    }
    assert.ok(canUndo, 'Workspace Undo is available after leaving the direction editor');
    assert.deepEqual(await session.command('key', { input: 'z', modifiers: ['command'] }), { dispatched: true });
    const restored = await savedDirection(accepted, corrected, true);
    await review.tab('Script');
    await session.waitFor(nodes => nodes.some(node => node.text === reviewStatus)
      && byID(nodes, 'generation-optional-direction')?.editable === true);
    assert.deepEqual(await journals(), conflicting, 'Undo keeps the exact original draft for explicit review');
    await enterDirection(recovery);
    await session.waitFor(nodes => nodes.some(node => node.text === reviewStatus));
    const revisedDraft = await journals();
    assert.equal(revisedDraft.length, 1);
    assert.equal(revisedDraft[0].record.sourcePrompt, intervening);
    assert.equal(revisedDraft[0].record.text, recovery);
    assert.deepEqual((await session.command('loaded-project')).project, restored);
    assert.deepEqual(sortedProjects(await session.command('persisted-projects')), sortedProjects([sentinel, restored]));
    await review.activate(node => node.type === 'UIButton' && node.title === 'Use this draft');
    const rebased = await savedDirection(restored, recovery);
    await session.waitFor(nodes => !nodes.some(node => node.text === reviewStatus
      || node.text === 'Direction saved in local recovery until the project save completes.'));
    assert.deepEqual(await journals(), []);
    assert.deepEqual((await session.command('loaded-project')).project, rebased);
    assert.deepEqual(sortedProjects(await session.command('persisted-projects')), sortedProjects([sentinel, rebased]));
    assert.deepEqual(await session.command('presented-alerts'), []);
    assert.deepEqual((await session.command('image-evidence')).jobs, []);
    console.log('PASS: cue-draft-recovery: workspace Undo retains the draft until Use this draft explicitly commits it');
  } catch (error) { throw new Error(`cue-draft-recovery/${stage}; no uncertain mutation retried`, { cause: error }); }
  finally { await session.close(); } // Release lease/process; preserve synthetic data, no recursive deletion.
}
