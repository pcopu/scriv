import assert from 'node:assert/strict';
import { constants } from 'node:fs';
import { open, lstat, readdir, realpath, access } from 'node:fs/promises';
import { join } from 'node:path';
import { ScrivSession } from '../../../cli/scriv.mjs';
import { inspectOwnedWorkspace } from '../../../cli/owned-workspace.mjs';
import { waitForSavedProject } from '../support/saved-projects.mjs';
import { fixture } from './support/generation-review-fixture.mjs';
import { characterCatalogSteps } from './support/character-catalog-steps.mjs';
import { editorDraftRecoverySteps } from './support/editor-draft-recovery-steps.mjs';
import { sortedProjects } from './support/generation-review-steps.mjs';

const cases = ['accepted-save-failure', 'retained-before-normal-open', 'normal-open-replays', 'repeated-clean-open', 'editor-draft-journal-review'];
const biography = 'Synthetic recovery biography. Cafe\u0301 🎬';
assert.ok(process.argv.slice(2).every(arg => arg === '--list-cases'), 'Unknown argument');
if (process.argv.includes('--list-cases')) {
  console.log(JSON.stringify({ journey: 'save-failure-recovery', cases, status: 'prepared-native-not-run', nativeVerified: false,
    excluded: ['crash durability', 'disk full', 'CAS contention', 'initial-save loss', 'malformed records', 'cloud account recovery'] }, null, 2));
} else {
  assert.equal(process.platform, 'darwin', 'Native macOS only');
  assert.ok(process.getuid() > 0 && process.geteuid() === process.getuid(), 'Require unprivileged matching real/effective uid');
  assert.ok(process.env.SCRIV_E2E_APP, 'Requires verified automation-enabled Catalyst app');
  let session = await ScrivSession.launch(process.env.SCRIV_E2E_APP, { persistent: true });
  const root = session.root;
  let historyLease, stage = 'setup';
  const sameIdentity = (a, b) => a.dev === b.dev && a.ino === b.ino;
  // Only this session's owned synthetic descendants. No supplied path, symlink,
  // capability mutation, journal write, file creation, or production data access.
  async function directory(path) {
    assert.ok(path === root || path.startsWith(root + '/'));
    assert.equal(await realpath(path), path);
    const named = await lstat(path);
    assert.ok(named.isDirectory() && !named.isSymbolicLink() && named.uid === process.getuid());
    assert.equal(named.mode & 0o7022, 0, 'No special bits or group/other write');
    const handle = await open(path, constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW);
    try {
      const info = await handle.stat();
      assert.ok(sameIdentity(named, info));
      return { path, handle, info, mode: info.mode & 0o7777 };
    } catch (error) { await handle.close(); throw error; }
  }
  async function tree(path) {
    const lease = await directory(path);
    try {
      const result = {};
      for (const name of (await readdir(path)).sort()) {
        const child = join(path, name), info = await lstat(child);
        assert.equal(info.uid, process.getuid());
        assert.ok(!info.isSymbolicLink());
        if (info.isDirectory()) result[name] = await tree(child);
        else {
          assert.ok(info.isFile() && info.nlink === 1 && info.size <= 8 * 1024 * 1024);
          const handle = await open(child, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
          try {
            assert.ok(sameIdentity(info, await handle.stat()));
            result[name] = (await handle.readFile()).toString('base64');
            assert.ok(sameIdentity(info, await lstat(child)));
          } finally { await handle.close(); }
        }
      }
      assert.ok(sameIdentity(lease.info, await lstat(path)));
      return result;
    } finally { await lease.handle.close(); }
  }
  async function records() {
    const files = await tree(join(root, 'PendingProjectSaves'));
    return Object.entries(files).filter(([name]) => name.endsWith('.json')).map(([name, bytes]) => {
      assert.match(name, /^[0-9a-f]{64}-\d+\.json$/);
      assert.equal(typeof bytes, 'string');
      return { name, bytes, record: JSON.parse(Buffer.from(bytes, 'base64').toString('utf8')) };
    });
  }
  async function restore() {
    if (!historyLease) return;
    const lease = historyLease;
    // Restore the exact opened inode, never chmod an unverified replacement.
    try {
      assert.ok(sameIdentity(lease.info, await lease.handle.stat()));
      await lease.handle.chmod(lease.mode);
      assert.equal((await lease.handle.stat()).mode & 0o7777, lease.mode);
      assert.ok(sameIdentity(lease.info, await lstat(lease.path)));
    } finally { await lease.handle.close(); historyLease = null; }
  }
  async function activate(predicate) {
    const nodes = await session.waitFor(nodes => nodes.filter(n => predicate(n) && n.hittable && n.enabled !== false).length === 1);
    await session.command('activate', { target: nodes.find(n => predicate(n) && n.hittable && n.enabled !== false).path });
  }
  async function saveFailureAlert(title) {
    const deadline = Date.now() + 15000;
    do {
      const alerts = await session.command('presented-alerts');
      assert.ok(alerts.length <= 1, 'No unrelated or additional failure alerts');
      if (alerts.length) {
        const alert = alerts[0];
        assert.equal(alert.observation, 'public-controller-presentation-state');
        assert.equal(alert.title, 'Scriv'); assert.equal(alert.style, 'alert');
        const prefix = `Could not save ${title}: `;
        assert.ok(alert.message.startsWith(prefix) && alert.message.length > prefix.length,
          'Observe the real save error for this synthetic project');
        assert.deepEqual(alert.actions, [{ title: 'OK', enabled: true, style: 'default' }]);
        if (!alert.beingPresented && !alert.beingDismissed && alert.viewAttachedToWindow) return alert;
      }
      await new Promise(resolve => setTimeout(resolve, 50));
    } while (Date.now() < deadline);
    throw new Error('Expected save-error alert did not finish presenting');
  }
  async function normalOpen(expected) {
    await activate(n => n.identifier === 'workspace-project');
    const nodes = await session.waitFor(nodes => nodes.some(n => n.placeholder === 'Find a project' && n.hittable));
    await session.command('text', { target: nodes.find(n => n.placeholder === 'Find a project' && n.hittable).path, text: expected.title });
    await session.waitFor(nodes => nodes.some(n => n.text === `${expected.title} · 1 scene`));
    await activate(n => n.title === 'Open project');
    await session.waitFor(nodes => nodes.some(n => n.identifier === 'workspace-project' && n.title === expected.title && n.hittable && n.enabled));
    assert.deepEqual((await session.command('loaded-project')).project, expected);
  }
  async function cold() {
    const before = await session.command('capabilities');
    session = await session.relaunch();
    const after = await session.command('capabilities');
    assert.equal(session.root, root); assert.equal(after.runID, before.runID);
    assert.notEqual(after.sessionID, before.sessionID); assert.equal(after.workspace.resumed, true);
  }
  try {
    const cap = await session.command('capabilities');
    assert.equal(cap.verificationRoot, root);
    for (const command of ['import-json', 'persisted-projects', 'loaded-project', 'presented-alerts']) assert.ok(cap.commands.includes(command));
    await inspectOwnedWorkspace(root);
    await session.waitFor(nodes => nodes.some(n => n.identifier === 'workspace-tabs' && n.hittable));
    await session.command('key', { input: 's', modifiers: ['command'] });
    const sentinel = await waitForSavedProject(session, p => p.title === 'YAM MAN');
    const input = structuredClone(fixture); input.title = 'Synthetic save recovery';
    assert.deepEqual(await session.command('import-json', { text: JSON.stringify(input) }), { dispatched: true, projectChanged: true });
    const baseline = await waitForSavedProject(session, p => p.title === input.title);
    assert.deepEqual(baseline.characters, input.characters); assert.deepEqual(baseline.entries, input.entries);
    assert.deepEqual(baseline.cues, input.cues);
    assert.match(baseline.id, /^[A-Za-z0-9_-]+$/); assert.notEqual(baseline.id, sentinel.id);
    const packagePath = join(root, 'Projects', baseline.id + '.scriv');
    const ui = characterCatalogSteps(session);
    await ui.openCatalog({ persist: false });
    const card = await ui.control(n => n.identifier === 'character-ribbon-mara');
    await session.command('activate', { target: card.path }); await ui.activate('Edit');
    await ui.saveEnabled(true);
    await ui.text(ui.biographyField, biography, 'recovery biography');
    const allBefore = sortedProjects([sentinel, baseline]);
    assert.deepEqual(sortedProjects(await session.command('persisted-projects')), allBefore);
    const settledBy = Date.now() + 15000;
    while ((await records()).length && Date.now() < settledBy) await new Promise(resolve => setTimeout(resolve, 50));
    assert.deepEqual(await records(), [], 'No initial pending save may contaminate failure');
    const packagesBefore = await tree(join(root, 'Projects'));
    await inspectOwnedWorkspace(root);
    const parent = await directory(packagePath); await parent.handle.close();
    historyLease = await directory(join(packagePath, 'history'));
    assert.equal(historyLease.mode & 0o700, 0o700);
    await historyLease.handle.chmod(historyLease.mode & ~0o200);
    assert.equal((await historyLease.handle.stat()).mode & 0o7777, historyLease.mode & ~0o200);
    await assert.rejects(access(historyLease.path, constants.W_OK), e => e.code === 'EACCES', 'Host must observe write refusal');
    stage = cases[0];
    // Dispatch once without waiting for a hittable catalog behind the error alert.
    await ui.activate('Save character');
    const failureAlert = await saveFailureAlert(baseline.title);
    // Read-only state, not a claim of pixel visibility or alert-input reachability.
    // No dismissal, private alert handler or native-accessibility fallback is used.
    await session.waitFor(nodes => !nodes.some(n => n.placeholder === 'Name')
      && nodes.some(n => typeof n.text === 'string' && n.text.includes('Save failed — accepted changes remain in local recovery')));
    const accepted = await session.command('loaded-project');
    const expected = structuredClone(baseline); expected.characters[0].biography = biography;
    expected.revision += 1; expected.modifiedAt = accepted.project.modifiedAt;
    assert.ok(Number.isFinite(expected.modifiedAt) && expected.modifiedAt >= baseline.modifiedAt);
    assert.deepEqual(accepted.project, expected, 'Only biography, one revision and bounded modification date changed');
    assert.deepEqual(sortedProjects(await session.command('persisted-projects')), allBefore);
    assert.deepEqual(await tree(join(root, 'Projects')), packagesBefore, 'Every package file byte, including history and sentinel, unchanged');
    const retained = await records(); assert.equal(retained.length, 1);
    const record = retained[0].record;
    assert.equal(record.schemaVersion, 2); assert.equal(record.beforeRevision, baseline.revision);
    assert.equal(record.label, 'Edit character'); assert.deepEqual(record.after, expected);
    assert.equal(record.scope.packagePath, packagePath); assert.equal(record.scope.projectID, baseline.id);
    assert.equal(record.scope.server, 'local'); assert.ok(record.scope.accountID == null && record.scope.cloudProjectID == null);
    assert.match(record.beforeHash, /^[0-9a-f]{64}$/); assert.match(record.afterHash, /^[0-9a-f]{64}$/);
    await restore(); // Required before native descendant validation on resume.
    assert.deepEqual(await session.command('presented-alerts'), [failureAlert],
      'The expected error remains presented; this journey never dismisses it');
    stage = cases[1]; await cold();
    // The owned-process relaunch may use SIGTERM or SIGKILL; exit mode and UIKit
    // lifecycle callbacks are unobserved. No graceful-exit or crash claim.
    // Refuse recovery credit if any canonical byte or pending record changed
    // before normal Projects open, regardless of how the old process exited.
    assert.deepEqual(await tree(join(root, 'Projects')), packagesBefore);
    assert.deepEqual(await records(), retained);
    assert.deepEqual(sortedProjects(await session.command('persisted-projects')), allBefore);
    stage = cases[2]; await normalOpen(expected);
    assert.deepEqual(await session.command('loaded-project'), accepted, 'Recovery preserves exact loaded model/date witnesses');
    assert.deepEqual(sortedProjects(await session.command('persisted-projects')), sortedProjects([sentinel, expected]));
    assert.deepEqual(await records(), [], 'Acknowledged only after public normal open saves the accepted record');
    const packagesAfter = await tree(join(root, 'Projects'));
    for (const [name, contents] of Object.entries(packagesBefore)) if (name !== baseline.id + '.scriv') assert.deepEqual(packagesAfter[name], contents);
    const oldPackage = packagesBefore[baseline.id + '.scriv'], newPackage = packagesAfter[baseline.id + '.scriv'];
    assert.deepEqual(Object.keys(newPackage).sort(), Object.keys(oldPackage).sort(), 'No unexpected package members');
    for (const [name, contents] of Object.entries(oldPackage)) if (!['history', 'project.json'].includes(name)) assert.deepEqual(newPackage[name], contents);
    for (const [name, contents] of Object.entries(oldPackage.history)) assert.deepEqual(newPackage.history[name], contents);
    const historyName = String(expected.revision).padStart(12, '0') + '.json';
    assert.deepEqual(Object.keys(newPackage.history).sort(), [...Object.keys(oldPackage.history), historyName].sort());
    const event = JSON.parse(Buffer.from(newPackage.history[historyName], 'base64').toString('utf8'));
    assert.deepEqual(event.snapshot, expected); assert.equal(event.label, 'Edit character');
    assert.equal(event.revision, expected.revision); assert.ok(Number.isFinite(event.date));
    assert.equal(typeof event.id, 'string'); assert.ok(event.id.length > 0);
    assert.deepEqual(JSON.parse(Buffer.from(newPackage['project.json'], 'base64').toString('utf8')), expected);
    stage = cases[3]; await cold(); await normalOpen(expected);
    assert.deepEqual(await session.command('loaded-project'), accepted);
    assert.deepEqual(await tree(join(root, 'Projects')), packagesAfter, 'Repeated recovery neither duplicates history nor changes any saved package bytes');
    assert.deepEqual(await records(), []);
    stage = cases[4];
    await editorDraftRecoverySteps({ getSession: () => session, root, baseline: expected,
      tree, directory, activate, cold, normalOpen, saveFailureAlert,
      refuseHistory: async () => {
        historyLease = await directory(join(packagePath, 'history'));
        await historyLease.handle.chmod(historyLease.mode & ~0o200);
        assert.ok(sameIdentity(historyLease.info, await lstat(historyLease.path)));
        await assert.rejects(access(historyLease.path, constants.W_OK), e => e.code === 'EACCES');
      }, restore });
    console.log('PASS: save-failure-recovery: real save refusal, retained before open, normal-open replay and clean repeated reopen');
  } catch (error) { throw new Error(`save-failure-recovery/${stage}; no uncertain mutation retried`, { cause: error }); }
  finally { try { await restore(); } finally { await session.close(); } }
}
