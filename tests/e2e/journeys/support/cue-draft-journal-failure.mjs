import assert from 'node:assert/strict';
import { constants } from 'node:fs';
import { access, lstat, open, readdir, realpath } from 'node:fs/promises';
import { join } from 'node:path';
import { ScrivSession } from '../../../../cli/scriv.mjs';
import { inspectOwnedWorkspace } from '../../../../cli/owned-workspace.mjs';
import { waitForSavedProject } from '../../support/saved-projects.mjs';
import { reopenProject } from '../../support/project-defaults-steps.mjs';
import { fixture } from './generation-review-fixture.mjs';
import { nodeWithID as byID, sortedProjects, reviewSteps } from './generation-review-steps.mjs';
import { coverageSteps } from './picture-coverage-steps.mjs';

const fieldID = 'generation-optional-direction';
const draft = 'Retain this direction after a local write failure 🎬';
const warning = 'The latest edit could not be written to recovery, so it was not accepted into the field. The attempted text is retained below in memory only. Retry before closing the app.';
const sameInode = (a, b) => a.dev === b.dev && a.ino === b.ino;

async function whileJournalCannotOpenForWriting(root, operation) {
  await inspectOwnedWorkspace(root);
  const directory = join(root, 'CuePromptDrafts');
  const path = join(directory, '.journal-lock');
  assert.equal(await realpath(path), path, 'Use only the owned non-symlinked journal lock');
  const parent = await lstat(directory), named = await lstat(path);
  assert.ok(parent.isDirectory() && parent.uid === process.getuid() && (parent.mode & 0o777) === 0o700);
  assert.ok(named.isFile() && named.uid === process.getuid() && named.nlink === 1);
  const handle = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    const stat = await handle.stat();
    assert.ok(sameInode(stat, named) && stat.nlink === 1);
    const mode = stat.mode & 0o7777;
    assert.equal(mode, 0o600);
    // Deny the production O_RDWR open on its own lock, leaving journal and project bytes intact.
    await handle.chmod(0o400);
    try {
      await assert.rejects(access(path, constants.W_OK), error => error.code === 'EACCES');
      await operation();
    } finally {
      await handle.chmod(mode);
      assert.equal((await handle.stat()).mode & 0o7777, mode);
      assert.ok(sameInode(stat, await lstat(path)));
    }
  } finally { await handle.close(); }
}

export async function runCueDraftJournalFailure(group) {
  assert.ok(process.getuid() > 0 && process.getuid() === process.geteuid(), 'The native write refusal requires an unprivileged app user');
  let session = await ScrivSession.launch(process.env.SCRIV_E2E_APP, { persistent: true });
  try {
    const capabilities = await session.command('capabilities');
    for (const command of ['snapshot', 'text', 'activate', 'import-json', 'loaded-project', 'persisted-projects', 'image-evidence', 'presented-alerts'])
      assert.ok(capabilities.commands.includes(command));
    await session.waitFor(nodes => byID(nodes, 'workspace-tabs')?.hittable);
    await session.command('key', { input: 's', modifiers: ['command'] });
    const sentinel = await waitForSavedProject(session, project => project.title === 'YAM MAN');
    const input = { ...structuredClone(fixture), title: `Synthetic direction ${group}` };
    assert.deepEqual(await session.command('import-json', { text: JSON.stringify(input) }), { dispatched: true, projectChanged: true });
    const project = await waitForSavedProject(session, value => value.title === input.title);
    assert.deepEqual(project, { ...input, id: project.id, createdAt: project.createdAt, modifiedAt: project.modifiedAt });
    const loaded = await session.command('loaded-project');
    assert.deepEqual(loaded.project, project);
    const saved = sortedProjects([sentinel, project]);
    assert.deepEqual(sortedProjects(await session.command('persisted-projects')), saved);

    await session.waitFor(nodes => byID(nodes, fieldID)?.editable === true);
    const records = async () => (await readdir(join(session.root, 'CuePromptDrafts'))).filter(name => name.endsWith('.json'));
    async function assertUnchanged() {
      assert.deepEqual(await session.command('loaded-project'), loaded);
      assert.deepEqual(sortedProjects(await session.command('persisted-projects')), saved);
      assert.deepEqual(await records(), []);
    }
    assert.deepEqual(await records(), []);
    const titledButton = title => node => node.type === 'UIButton' && (node.title === title || node.label === title);
    if (group === 'journal-read-retry') {
      const root = session.root;
      const error = node => node.text?.startsWith('Local direction recovery could not be checked:');
      const retry = titledButton('Retry save');
      await whileJournalCannotOpenForWriting(root, async () => {
        session = await session.relaunch();
        const resumed = await session.command('capabilities');
        assert.equal(session.root, root);
        assert.equal(resumed.runID, capabilities.runID);
        assert.notEqual(resumed.sessionID, capabilities.sessionID);
        assert.equal(resumed.workspace.resumed, true);
        await reopenProject(session, project);
        await session.waitFor(nodes => byID(nodes, fieldID)?.editable === false
          && nodes.some(error) && nodes.filter(retry).length === 1);
        await assertUnchanged();
      });
      await coverageSteps(session).activate(retry);
      await session.waitFor(nodes => byID(nodes, fieldID)?.editable === true
        && byID(nodes, fieldID)?.text === project.cues[0].prompt && !nodes.some(error));
      await assertUnchanged();
      assert.deepEqual((await session.command('image-evidence')).jobs, []);
      return;
    }

    const direction = await reviewSteps(session).reveal(fieldID);
    const composer = direction.path.slice(0, direction.path.lastIndexOf('.'));
    const matchingTitle = titledButton('Retry retaining this text');
    const retry = node => matchingTitle(node) && node.path.startsWith(composer + '.');
    await whileJournalCannotOpenForWriting(session.root, async () => {
      assert.deepEqual(await session.command('text', { target: direction.path, text: draft }), { dispatched: true });
      await session.waitFor(nodes => nodes.some(node => node.text === warning)
        && nodes.some(node => node.text === draft && node.identifier !== fieldID)
        && nodes.filter(retry).length === 1);
      await assertUnchanged();
    });

    await coverageSteps(session).activate(retry);
    const committed = await waitForSavedProject(session, value => value.id === project.id && value.cues[0].prompt === draft);
    const expected = structuredClone(project);
    expected.cues[0].prompt = draft;
    expected.revision += 1;
    expected.modifiedAt = committed.modifiedAt;
    assert.ok(Number.isFinite(committed.modifiedAt) && committed.modifiedAt >= project.modifiedAt);
    assert.deepEqual(committed, expected, 'Retry commits exactly one direction revision without retyping');
    await session.waitFor(nodes => byID(nodes, fieldID)?.text === draft
      && !nodes.some(node => node.text === warning || retry(node)
        || node.text === 'Direction saved in local recovery until the project save completes.'));
    assert.deepEqual(await records(), []);
    assert.deepEqual((await session.command('loaded-project')).project, committed);
    assert.deepEqual(sortedProjects(await session.command('persisted-projects')), sortedProjects([sentinel, committed]));
    assert.deepEqual(await session.command('presented-alerts'), []);
    assert.deepEqual((await session.command('image-evidence')).jobs, []);
  } finally { await session.close(); }
}
