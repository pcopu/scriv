import assert from 'node:assert/strict';
import { ScrivSession } from '../../../cli/scriv.mjs';
import { waitForSavedProject } from '../support/saved-projects.mjs';
import { audioLibrarySteps, sortedProjects } from './support/audio-library-steps.mjs';

// Real public CLI only. No private files, raw protocol IDs, grants or injected state.
const cases = ['fresh-owned-contract', 'refusal-nonmutation', 'rotate-reopen-twice', 'fresh-root-isolation'];
const isolation = { credentials: 'process-memory', outbox: 'private-run-root', network: 'disabled', oauth: 'disabled', peerTransport: 'disabled' };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const args = process.argv.slice(2);
assert.ok(args.every(arg => arg === '--list-cases'), 'Unknown argument');
if (args.includes('--list-cases')) {
  console.log(JSON.stringify({ journey: 'capability-safety-v89', nativeVerified: false, cases }));
} else {
  assert.ok(process.env.SCRIV_E2E_APP, 'Set SCRIV_E2E_APP to a verified automation-enabled Catalyst bundle');
  await run(process.env.SCRIV_E2E_APP);
}
async function contract(session, persistent, resumed) {
  const cap = await session.command('capabilities');
  assert.equal(cap.protocol, 1); assert.equal(cap.driver, 'UIKit controls');
  assert.equal(cap.completeInterfaceParity, false);
  assert.deepEqual(cap.cloudIsolation, isolation); // Advertised policy, NOT traffic or Keychain evidence.
  assert.deepEqual(cap.workspace, { persistent, resumed });
  assert.match(cap.runID, UUID); assert.match(cap.sessionID, UUID);
  assert.ok(cap.verificationRoot.endsWith('/ScrivVerification-CLI-' + cap.runID));
  assert.equal(new Set(cap.commands).size, cap.commands.length);
  for (const name of ['capabilities', 'snapshot', 'activate', 'text', 'select', 'key', 'persisted-projects', 'loaded-project', 'presented-alerts']) assert.ok(cap.commands.includes(name));
  for (const name of ['install-token', 'authorize-origin', 'outbox-write', 'resume', 'reset', 'delete-workspace']) assert.ok(!cap.commands.includes(name));
  return cap;
}
async function run(app) {
  let session = await ScrivSession.launch(app, { persistent: true });
  let fresh;
  const completed = [];
  async function chapter(name, body) { await body(); completed.push(name); console.log('PASS: capability-safety-v89/' + name); }
  let initial, sample, current, expectedLoaded, ui = audioLibrarySteps(session);
  async function packages() {
    assert.deepEqual(sortedProjects(await session.command('persisted-projects')), sortedProjects([sample, current]));
  }
  async function unchanged() {
    await packages();
    assert.deepEqual(await session.command('loaded-project'), expectedLoaded, 'Full model and Date witnesses are unchanged');
    assert.deepEqual(await session.command('presented-alerts'), []);
  }
  async function refuse(command, parameters, error) {
    await assert.rejects(session.command(command, parameters), { message: command + ': ' + error });
    await unchanged(); // EACH refusal has its own package/model/non-alert oracle.
  }
  try {
    await chapter('fresh-owned-contract', async () => {
      initial = await contract(session, true, false);
      assert.equal(initial.sessionID, initial.runID);
      await ui.tab('Script'); await session.command('key', { input: 's', modifiers: ['command'] });
      sample = await waitForSavedProject(session, p => p.title === 'YAM MAN');
      const fixture = {
        schemaVersion: 1, id: 'capability-safety-input', title: 'Synthetic capability boundary',
        createdAt: 1700000000000, modifiedAt: 1700000000000, revision: 0,
        scenes: [{ id: 'cap-scene', title: 'Isolated scene', order: 0 }],
        entries: [{ id: 'cap-direction', sceneId: 'cap-scene', order: 0, kind: 'direction', text: 'A private synthetic gate stays shut.', ownedDurationMs: 2000, coverageDurationMs: 2000, color: 'purple', words: [] }],
        characters: [], images: [], cues: [], audioAssets: [], audioClips: [], audioVolume: 1,
      };
      await session.command('import-json', { text: JSON.stringify(fixture) });
      current = await waitForSavedProject(session, p => p.id !== sample.id);
      const expected = { ...fixture, id: current.id, createdAt: current.createdAt, modifiedAt: current.modifiedAt };
      assert.match(current.id, UUID); assert.notEqual(current.id, sample.id);
      assert.ok(Number.isFinite(current.createdAt)); assert.ok(Number.isFinite(current.modifiedAt));
      assert.deepEqual(current, expected, 'Only import envelope identity/dates may differ from independent fixture');
      expectedLoaded = await session.command('loaded-project');
      assert.deepEqual(expectedLoaded.project, current);
      await unchanged();
    });
    await chapter('refusal-nonmutation', async () => {
      await ui.tab('Script');
      const tabs = (await session.command('snapshot')).filter(n => n.identifier === 'workspace-tabs');
      assert.equal(tabs.length, 1); assert.equal(tabs[0].enabled, true); assert.equal(tabs[0].hittable, true);
      // Unknown dispatch requires a valid, active, hittable target; otherwise an outer guard intercepts it.
      for (const command of ['install-token', 'authorize-origin', 'outbox-write', 'resume', 'reset', 'delete-workspace']) {
        await refuse(command, { target: 'workspace-tabs' }, 'Unknown command: ' + command);
      }
      await refuse('activate', {}, 'Missing target identifier or path');
      await refuse('activate', { target: 'synthetic-absent-target-v89' }, 'Target must match exactly one visible view');
      for (const index of [-1, tabs[0].segments.length, '0']) await refuse('select', { target: 'workspace-tabs', index }, 'Invalid segment');
      await refuse('text', { target: 'workspace-tabs', text: 'No mutation' }, 'Target is not a text editor');
      await refuse('type', { target: 'workspace-tabs', text: 'No mutation' }, 'Target is not a text input');
      await refuse('return', { target: 'workspace-tabs' }, 'Return requires the focused editable text view without composition');
      await refuse('accessibility-activate', { target: 'workspace-tabs' }, 'Target is not an enabled accessibility button');
      await refuse('key', { input: 's' }, 'Expected input and modifier names');
      for (const [command, error] of [
        ['loaded-project', 'Synthetic loaded-project observation is unavailable or invalid.'],
        ['local-image-evidence', 'Local image evidence is unavailable or inconsistent.'],
        ['script-interaction-counts', 'Synthetic interaction-count observation is unavailable or invalid.'],
        ['presented-alerts', 'Presented alert observation accepts no parameters'],
      ]) await refuse(command, { path: '/synthetic-disallowed' }, error);
      // Valid JSON padded to 65,537 ASCII bytes stays below the 1 MiB transport envelope.
      const oversized = JSON.stringify(current).padEnd(65_537, ' ');
      assert.equal(Buffer.byteLength(oversized, 'utf8'), 65_537); assert.deepEqual(JSON.parse(oversized), current);
      await refuse('import-json', { text: oversized }, 'Synthetic script import is unavailable or invalid.');
      // Host refusal precedes process shutdown and keeps the existing owner live.
      await assert.rejects(session.relaunch({ root: session.root }), { message: 'Relaunch requires a live persistent session with no arguments, pending commands or uncertain outcomes' });
      assert.deepEqual(await contract(session, true, false), initial);
      await unchanged();
      const afterTabs = (await session.command('snapshot')).filter(n => n.identifier === 'workspace-tabs');
      assert.equal(afterTabs.length, 1); assert.equal(afterTabs[0].selected, tabs[0].selected);
    });
    await chapter('rotate-reopen-twice', async () => {
      const processIDs = new Set([initial.sessionID]);
      for (let rotation = 0; rotation < 2; rotation++) {
        const previous = session, root = session.root;
        session = await previous.relaunch(); ui = audioLibrarySteps(session);
        const resumed = await contract(session, true, true);
        assert.equal(session.root, root); assert.equal(resumed.runID, initial.runID);
        assert.equal(resumed.verificationRoot, initial.verificationRoot);
        assert.ok(!processIDs.has(resumed.sessionID)); processIDs.add(resumed.sessionID);
        // Do not Save the fresh unsaved startup sample before reopening the retained project.
        await packages();
        assert.deepEqual(await ui.openProject(current), expectedLoaded);
        await unchanged();
        await assert.rejects(previous.command('snapshot'), { message: 'Session is closing or relaunching' });
        await assert.rejects(previous.relaunch(), { message: 'Relaunch requires a live persistent session with no arguments, pending commands or uncertain outcomes' });
        await unchanged();
      }
      assert.equal(processIDs.size, 3);
    });
    await chapter('fresh-root-isolation', async () => {
      // Close owner before starting another app: no simultaneous windows or focus ambiguity.
      await unchanged(); await session.close();
      fresh = await ScrivSession.launch(app);
      const cap = await contract(fresh, false, false);
      assert.notEqual(cap.runID, initial.runID); assert.notEqual(fresh.root, session.root);
      assert.equal(cap.sessionID, cap.runID);
      const freshUI = audioLibrarySteps(fresh);
      await freshUI.tab('Script'); await fresh.command('key', { input: 's', modifiers: ['command'] });
      const freshSample = await waitForSavedProject(fresh, p => p.title === 'YAM MAN');
      const before = await fresh.command('loaded-project');
      assert.deepEqual(await fresh.command('persisted-projects'), [freshSample]);
      assert.notEqual(freshSample.id, sample.id); assert.notEqual(freshSample.id, current.id);
      await assert.rejects(fresh.relaunch(), { message: 'Relaunch requires a live persistent session with no arguments, pending commands or uncertain outcomes' });
      assert.deepEqual(await fresh.command('persisted-projects'), [freshSample]);
      assert.deepEqual(await fresh.command('loaded-project'), before);
      assert.deepEqual(await fresh.command('presented-alerts'), []);
    });
    assert.deepEqual(completed, cases);
  } finally { await fresh?.close(); await session.close(); }
}
