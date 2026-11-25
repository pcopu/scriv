import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { ScrivSession } from '../../../cli/scriv.mjs';
import { observePresentedError } from '../support/presented-error.mjs';
import { waitForSavedProject } from '../support/saved-projects.mjs';
import { nativeFixtureEmail, nativeFixtureTeam, lostCloudEditReceipt, interruptedCloudEdit, startNativeCloudFixture } from './support/native-cloud-fixture.mjs';
import { byID as nodesByID, keyIs, scriptAuthoringSteps } from './support/script-authoring-steps.mjs';
import { audioProjectFixture } from './support/audio-library-fixtures.mjs';

const groups = ['sync', 'lease-renewal', 'staged-edit', 'staged-receipt-retry', 'logout-revocation-failure'];
const args = process.argv.slice(2);
if (args.length === 1 && args[0] === '--list-cases') {
  console.log(JSON.stringify({ groups }));
  process.exit(0);
}
assert.ok(args.length === 0 || args.length === 2 && args[0] === '--group' && groups.includes(args[1]), 'Choose a supported cloud project group');

assert.ok(process.env.SCRIV_E2E_APP, 'Requires a verified automation-enabled Catalyst app');
const fixture = await startNativeCloudFixture();
let session;
let step = 'launch';
async function control(matches, settled = false) {
  const enabled = nodes => nodes.filter(node => node.hittable && (node.enabled || node.sensitive && node.interactive) && matches(node));
  let previous = '', stableSince = 0;
  const nodes = await session.waitFor(nodes => {
    const [target, second] = enabled(nodes);
    if (!target || second) { previous = ''; return false; }
    if (!settled) return true;
    const current = JSON.stringify([target.path, target.frame]);
    if (current !== previous) { previous = current; stableSince = Date.now(); return false; }
    return Date.now() - stableSince >= 1000;
  });
  return enabled(nodes)[0];
}
const click = async (label, settled) => session.command('activate', { target: (await control(
  node => node.type === 'UIButton' && (node.title === label || node.label === label), settled)).path });
const workspaceProject = node => node.identifier === 'workspace-project';
const projectsSearch = node => node.placeholder === 'Find a project';
async function openCloudDialogue(line) {
  const script = scriptAuthoringSteps(session);
  await script.selectTab('Script');
  assert.equal(line.kind, 'dialogue');
  await script.displayed(line.id, line.text, { finished: true });
  const editKey = (await session.command('keys')).find(command => keyIs(command, '\r', ['command'])
    && command.action === 'toggleScriptEditingFromKeyboard:');
  assert.ok(editKey, 'The selected script line exposes its native edit shortcut');
  await script.key(editKey.input, editKey.modifiers);
  const editorID = 'script-editor-' + line.id;
  const nodes = await session.waitFor(nodes => nodesByID(nodes, editorID).some(node => node.firstResponder && node.text === line.text));
  await script.reveal(nodesByID(nodes, editorID)[0], nodes);
  await session.command('selection', { target: editorID, start: line.text.length, end: line.text.length });
  await script.waitEditor(editorID, line.text, line.text.length);
  return { script, editorID };
}
async function appendToCloudDialogue(line, addition, armFixture) {
  const { script, editorID } = await openCloudDialogue(line);
  const revisedText = line.text + addition;
  await armFixture();
  await session.command('type', { target: editorID, text: addition });
  await script.waitEditor(editorID, revisedText, revisedText.length);
  await script.finishEditor();
  return revisedText;
}
// Cloud snapshots return items by ID. Each entry's order remains part of the comparison.
const byID = (a, b) => a.id.localeCompare(b.id);
const content = ({ revision, modifiedAt, entries, characters, ...rest }) => ({
  ...rest, entries: [...entries].sort(byID), characters: [...characters].sort(byID),
});
async function signIn(deliveries) {
  await session.command('activate', { target: (await control(workspaceProject)).path });
  await click('Sign in to Scriv…', true);
  const email = await control(node => node.type === 'UITextField' && node.label === 'Email address', true);
  await session.command('text', { target: email.path, text: nativeFixtureEmail });
  await click('Continue with email');
  await session.waitFor(nodes => nodes.some(node => node.text === 'Check your email'));
  assert.equal(await fixture.deliveries(), deliveries);
  const codeField = await control(node => node.type === 'UITextField' && node.sensitive && node.text === '<redacted>', true);
  if (stagedGroup) {
    await assert.rejects(session.command('accessibility-snapshot'), /Accessibility observation is unavailable while sensitive input is present/);
  }
  await assert.rejects(session.command('text', { target: codeField.path, text: 'blocked input' }), /Sensitive input is unavailable/);
  assert.equal((await session.command('snapshot')).find(node => node.title === 'Sign in with code')?.enabled, false);
  assert.deepEqual(await session.deliverFixtureEmailCode(await fixture.takeCode()), { delivered: true });
  assert.ok((await session.command('snapshot')).some(node => node.sensitive && node.text === '<redacted>'));
  await click('Sign in with code');
  await assert.rejects(session.deliverFixtureEmailCode('000000'), /owned synthetic sign-in mailbox is unavailable/);
}
async function openCloudFromProjects(title) {
  await control(projectsSearch, true);
  await click('Scriv Cloud');
  await session.waitFor(nodes => nodes.some(node => node.text === title + ' · Cloud project'));
  await click('Open project');
  await control(node => workspaceProject(node) && node.title === title, true);
}
const newReplicaContent = ({ id, createdAt, ...project }) => content(project);
const stagedGroup = args[1] === 'staged-edit' || args[1] === 'staged-receipt-retry';

async function importDenseScene() {
  const project = audioProjectFixture();
  project.title = 'Synthetic dense scene order';
  const [first, second] = project.entries;
  first.order = 1;
  second.order = 1 + Number.EPSILON;
  for (let index = 0; index < 102; index++) {
    project.entries.push({ ...second, id: `tail-${index}`, order: 100 + index, text: 'Pause.',
      kind: 'direction', words: [], ownedDurationMs: 0, coverageDurationMs: 0 });
  }
  project.cues = [{ ...project.cues[0], startAnchor: { entryId: first.id, offsetMs: 0 }, authoredDurationMs: 3000 }];
  assert.deepEqual(await session.command('import-json', { text: JSON.stringify(project) }),
    { dispatched: true, projectChanged: true });
  const saved = await waitForSavedProject(session, item => item.title === project.title);
  assert.deepEqual(saved.entries, project.entries);
  assert.deepEqual(saved.cues, project.cues);
  return saved;
}

async function verifyStagedEdit(original) {
  const dropReceipt = args[1] === 'staged-receipt-retry';
  step = 'insert one dialogue where there is no distinct order between its neighbors';
  const script = scriptAuthoringSteps(session);
  await script.selectTab('Script');
  await script.displayed('line1', 'one two three', { finished: true });
  assert.equal(await fixture.watchStagedEdit(original.cloudProjectId, dropReceipt), true);
  const isAdd = nodes => nodes.filter(node => node.title === 'Dialogue' && node.enabled);
  const controls = await session.waitFor(nodes => isAdd(nodes).length === 1);
  await script.reveal(isAdd(controls)[0], controls, true);
  await script.activate('Dialogue');
  const added = await waitForSavedProject(session, project => project.id === original.id
    && project.entries.length === original.entries.length + 1);
  const existing = [...original.entries].sort((a, b) => a.order - b.order);
  const line = added.entries.find(entry => !existing.some(previous => previous.id === entry.id));
  assert.equal(line.text, 'New line');
  assert.equal(line.ownedDurationMs, 3000);
  const expected = { ...original, entries: [existing[0], line, ...existing.slice(1)]
    .map((entry, order) => ({ ...entry, order })) };
  assert.deepEqual(content(added), content(expected));

  step = 'verify both upload parts and the single accepted edit at the Worker';
  const deadline = Date.now() + 15_000;
  let requests = await fixture.stagedEditState();
  while (requests.length < 4 && Date.now() < deadline) {
    await delay(50);
    requests = await fixture.stagedEditState();
  }
  assert.equal(requests.length, 4, 'The online edit has uploaded and committed once');
  const [prepare, first, second, commit] = requests;
  const { manifest } = prepare;
  assert.match(manifest.commandID, /^[a-f0-9-]{36}$/i);
  assert.deepEqual([prepare, first, second, commit].map(({ method, route, status }) => [method, route, status]), [
    ['POST', '', 200], ['PUT', `/${manifest.commandID}/parts/0`, 200],
    ['PUT', `/${manifest.commandID}/parts/1`, 200], ['POST', `/${manifest.commandID}/commit`, 200],
  ]);
  assert.deepEqual(prepare.reply, { commandID: manifest.commandID, staged: true });
  assert.deepEqual(commit.manifest, manifest);
  assert.equal(commit.reply.commandID, manifest.commandID);
  assert.ok(Number.isSafeInteger(commit.reply.sequence) && commit.reply.sequence > 0);
  const parts = [first.part, second.part];
  assert.equal(manifest.label, 'Add dialogue');
  assert.equal(manifest.count, expected.entries.length);
  assert.deepEqual(manifest.parts, parts.map(({ bytes, hash, operations }) => ({ bytes, hash, count: operations.length })));
  assert.deepEqual(parts.map(({ operations }) => operations.length), [100, 5]);
  const operations = parts.flatMap(part => part.operations);
  assert.ok(operations.every(operation => operation.op === 'put' && operation.kind === 'entry'));
  assert.deepEqual(operations.map(operation => operation.id).sort(), expected.entries.map(entry => entry.id).sort());
  assert.deepEqual(operations.map(operation => operation.data).sort(byID), [...expected.entries].sort(byID));

  if (dropReceipt) {
    step = 'recover the staged receipt without uploading another part';
    await observePresentedError(session, lostCloudEditReceipt);
    const outbox = join(session.root, 'Outbox');
    const scopes = await readdir(outbox);
    assert.equal(scopes.length, 1);
    assert.match(scopes[0], /^[0-9a-f]{64}$/);
    const directory = join(outbox, scopes[0]);
    const pendingName = manifest.commandID + '.json';
    assert.deepEqual(await readdir(directory), [pendingName]);
    const pending = JSON.parse(await readFile(join(directory, pendingName), 'utf8'));
    assert.equal(pending.endpoint, 'batches');
    assert.equal(pending.projectId, original.cloudProjectId);
    assert.equal(pending.payload.manifest.commandId, manifest.commandID);
    assert.deepEqual(pending.payload.manifest.parts, manifest.parts);
    assert.deepEqual(pending.payload.parts.map(part => JSON.parse(part)), parts.map(part => part.operations));
    assert.deepEqual(await session.command('acknowledge-cloud-save-error', { message: lostCloudEditReceipt }), { acknowledged: true });
    await control(workspaceProject, true);
    assert.deepEqual(await readdir(directory), [pendingName]);
    await openWorkspacePanel('Scriv account…');
    await click('Retry saved cloud commands', true);
    await control(node => node.title === 'Sync this script', true);
    await session.command('key', { input: 'Escape', modifiers: [] });
    await control(workspaceProject, true);
    const afterRetry = await fixture.stagedEditState();
    assert.deepEqual(afterRetry, [...requests, { ...commit, route: '' }], 'The preparation lookup returns the original receipt');
    assert.deepEqual(await readdir(directory), []);
    requests = afterRetry;
  }

  step = 'reopen the complete staged edit in a fresh native workspace';
  const firstRoot = session.root;
  await session.close();
  session = await ScrivSession.launch(process.env.SCRIV_E2E_APP, { cloudFixtureOrigin: fixture.origin });
  assert.notEqual(session.root, firstRoot);
  await control(workspaceProject);
  await signIn(3);
  await openCloudFromProjects(original.title);
  const downloaded = await waitForSavedProject(session, candidate => candidate.cloudProjectId === original.cloudProjectId);
  assert.notEqual(downloaded.id, original.id);
  assert.deepEqual(newReplicaContent(downloaded), newReplicaContent(expected));
  assert.deepEqual((await session.command('loaded-project')).project, downloaded);
  assert.deepEqual(await fixture.stagedEditState(), requests, 'Reopening sends no duplicate upload');
  assert.deepEqual(await session.command('presented-alerts'), []);
}

const openingComment = 'Does the revised question work better in this scene?';
const replyComment = 'Yes, it makes the invoice discussion clearer.';
async function openDiscussion() {
  const actions = await control(node => node.label === 'Workspace actions');
  const menu = await session.command('menu', { target: actions.path });
  assert.ok(menu.primary[0].children.some(group => group.children?.some(action => action.title === 'Discussion' && !action.disabled)));
  assert.deepEqual(await session.command('menu-action', {
    target: actions.path, scope: 'workspace-discussion', action: 'Discussion',
  }), { dispatched: true, coverage: 'semantic-menu-action' });
}
function discussionState(nodes) {
  const rows = nodes.filter(node => node.type === 'DiscussionMessageCell');
  const hasText = (row, text, type) => nodes.some(node => node.path.startsWith(row.path + '.')
    && node.type === type && node.text === text);
  return rows.length === 2
    && rows.some(row => hasText(row, openingComment, 'DiscussionReadOnlyTextView'))
    && rows.some(row => hasText(row, replyComment, 'DiscussionReadOnlyTextView') && hasText(row, openingComment, 'UILabel'));
}
async function compose(text, useShortcut = false) {
  const isComposer = node => node.type === 'DiscussionComposerTextView' && node.editable && node.hittable;
  const nodes = await session.waitFor(nodes => nodes.some(isComposer));
  await session.command('text', { target: nodes.find(isComposer).path, text });
  await session.waitFor(nodes => nodes.some(node => node.type === 'DiscussionComposerTextView' && node.text === text)
    && nodes.some(node => node.label === 'Send message' && node.enabled && node.hittable));
  if (useShortcut) {
    const send = (await session.command('keys')).find(command => command.responderType === 'DiscussionComposerTextView'
      && keyIs(command, '\r', ['command']));
    assert.ok(send, 'The real focused discussion composer offers Command–Return to send');
    await session.command('key', { input: send.input, modifiers: send.modifiers });
  } else await click('Send message');
  await session.waitFor(nodes => nodes.some(node => node.type === 'DiscussionComposerTextView' && node.text === '')
    && nodes.some(node => node.type === 'DiscussionReadOnlyTextView' && node.text === text));
}

async function selectActivityRow(text) {
  const rows = nodes => nodes.filter(row => row.type === 'UITableViewCell' && row.hittable
    && nodes.some(child => child.path.startsWith(row.path + '.') && child.type === 'UILabel' && child.text === text));
  const nodes = await session.waitFor(nodes => rows(nodes).length === 1);
  const target = rows(nodes)[0].path;
  await assert.rejects(session.command('activate', { target, unexpected: true }), /Discussion picker row cannot be selected/);
  assert.deepEqual(await session.command('activate', { target }), { dispatched: true });
}
async function browseProjectActivity(lineTitle) {
  await click('Project activity, 0 unread mentions', true);
  const activity = await control(node => node.type === 'UISegmentedControl'
    && node.segments?.join(',') === 'Mentions,Conversations', true);
  assert.equal(activity.selected, 0);
  const mentions = await session.waitFor(nodes => nodes.some(node => node.text === 'No one has mentioned you in this project yet.'));
  assert.ok(mentions.some(node => node.text === 'In-app only. No email or push notification is sent.'));
  await session.command('select', { target: activity.path, index: 1 });
  const resolvedProject = nodes => nodes.some(node => node.text === 'Project · Resolved')
    && !nodes.some(node => node.text === 'Loading activity…' || node.text === 'Couldn’t load activity');
  await session.waitFor(resolvedProject);
  await click('Refresh');
  await session.waitFor(resolvedProject);
  await selectActivityRow(lineTitle);
  await session.waitFor(nodes => nodes.some(node => node.text === 'Comments stay with this line.')
    && lineOnly(nodes, lineComment));
  await selectDiscussionScope(0);
  await control(node => node.title === 'Reopen conversation');
  await session.waitFor(discussionState);
}
async function browseDiscussionMembers() {
  await click('Mention a project member', true);
  const search = await control(node => node.placeholder === 'Search project members', true);
  const owner = nodes => nodes.some(node => node.text === 'Scriv user (you)')
    && nodes.some(node => node.text === 'Owner');
  const members = await session.waitFor(owner);
  assert.ok(members.some(node => node.text === '0 / 20'));
  assert.ok(members.some(node => node.text === 'Mentions appear in this conversation. No email is sent.'));
  await session.command('text', { target: search.path, text: 'No matching synthetic writer' });
  await session.waitFor(nodes => nodes.some(node => node.text === 'No matching members.') && !owner(nodes));
  await session.command('text', { target: search.path, text: 'oWnEr' });
  await session.waitFor(owner);
  for (const [label, count] of [
    ['Mention Scriv user, owner', '1 / 20'],
    ['Remove mention of Scriv user, owner', '0 / 20'],
    ['Mention Scriv user, owner', '1 / 20'],
  ]) {
    const matches = nodes => nodes.filter(node => node.type === 'UITableViewCell' && node.label === label && node.hittable);
    const nodes = await session.waitFor(nodes => matches(nodes).length === 1);
    assert.deepEqual(await session.command('activate', { target: matches(nodes)[0].path }), { dispatched: true });
    await session.waitFor(nodes => nodes.some(node => node.text === count));
  }
  await click('Done');
  await control(node => node.label === 'Remove mention of Scriv user');
}

const lineComment = 'Keep this note with the revised dialogue line.';
async function selectDiscussionScope(index) {
  const scope = await control(node => node.type === 'UISegmentedControl'
    && node.segments?.length === 2 && node.segments[0] === 'Project');
  await session.command('select', { target: scope.path, index });
  await session.waitFor(nodes => nodes.some(node =>
    node.text === (index === 0 ? 'Comments stay with this project.' : 'Comments stay with this line.')));
}
const lineOnly = (nodes, body) => {
  const messages = nodes.filter(node => node.type === 'DiscussionReadOnlyTextView');
  return messages.length === 1 && messages[0].text === body;
};

async function runProjectJourney() {
  step = 'set up the original free team through the owned Worker';
  assert.deepEqual(await fixture.createFreeTeam(), { name: nativeFixtureTeam, role: 'owner', plan: 'free', billingCustomer: false });
  session = await ScrivSession.launch(process.env.SCRIV_E2E_APP, { cloudFixtureOrigin: fixture.origin });
  const capabilities = await session.command('capabilities');
  assert.equal(capabilities.cloudIsolation.network, 'loopback-only');
  assert.ok(capabilities.syntheticFixtureCommands.includes('receive-fixture-email-code'), 'The owned synthetic mailbox action is missing');
  assert.ok(capabilities.semanticMenuActionScopes.includes('workspace-discussion'), 'The workspace discussion menu route is missing');
  await verifyPanelRefusals();
  await assert.rejects(session.command('receive-fixture-email-code'), /synthetic sign-in mailbox is unavailable/);
  await control(workspaceProject);
  await session.command('key', { input: 's', modifiers: ['command'] });
  const sample = await waitForSavedProject(session, candidate => candidate.title === 'YAM MAN');
  const original = stagedGroup ? await importDenseScene() : sample;
  assert.equal(original.cloudProjectId ?? null, null);
  assert.deepEqual(await fixture.projects(), []);

  step = 'verify the owned email challenge';
  await signIn(2);
  await click('Close Projects', true);
  await control(workspaceProject, true);

  step = 'create and seed the cloud project through Discussion';
  await openDiscussion();
  await click('Save script to cloud');
  const synced = await waitForSavedProject(session, candidate => candidate.id === original.id && Boolean(candidate.cloudProjectId));
  assert.deepEqual(await fixture.projects(), [{ id: synced.cloudProjectId, title: original.title }]);
  await session.waitFor(nodes => nodes.some(node => node.type === 'DiscussionComposerTextView' && node.editable && node.hittable));
  await click('Close discussion');
  assert.deepEqual(await session.command('presented-alerts'), []);

  if (args[1] === 'lease-renewal') {
    await verifyEditingLeaseRenewal(synced);
    await fixture.assertNoOutbound();
    return;
  }
  if (stagedGroup) {
    await verifyStagedEdit(synced);
    await fixture.assertNoOutbound();
    return;
  }

  step = 'edit an already-linked script through the native editor';
  const line = synced.entries.find(entry => entry.id === 'line-01');
  const revisedText = await appendToCloudDialogue(line, ' Ask about the invoice.', () => fixture.loseNextEditReceipt(synced.cloudProjectId));
  const edited = await waitForSavedProject(session, candidate => candidate.id === synced.id
    && candidate.entries.some(entry => entry.id === line.id && entry.text === revisedText));
  assert.equal(edited.cloudProjectId, synced.cloudProjectId);
  assert.equal(edited.entries.length, synced.entries.length);
  for (const previous of synced.entries.filter(entry => entry.id !== line.id)) {
    assert.equal(edited.entries.find(entry => entry.id === previous.id)?.text, previous.text);
  }
  await verifySavedCloudEditRetry(edited);
  await scriptAuthoringSteps(session).displayed(line.id, revisedText, { finished: true });

  step = 'open the cloud project after switching to a distinct local project';
  await session.command('key', { input: 'n', modifiers: ['command'] });
  const other = await waitForSavedProject(session, candidate => candidate.id !== original.id);
  assert.equal(other.cloudProjectId ?? null, null);
  const browser = await control(node => workspaceProject(node) && node.title === other.title, true);
  await session.command('activate', { target: browser.path });
  await openCloudFromProjects(original.title);
  const reopened = await waitForSavedProject(session, candidate => candidate.id === original.id && candidate.revision > edited.revision);
  assert.deepEqual(content(reopened), content(edited), 'The cloud snapshot contains the committed edit and complete synchronized model');
  assert.deepEqual((await session.command('loaded-project')).project, reopened);
  assert.deepEqual(await session.command('presented-alerts'), []);
  assert.deepEqual(await fixture.projects(), [{ id: reopened.cloudProjectId, title: reopened.title }]);
  assert.deepEqual((await session.command('persisted-projects')).find(candidate => candidate.id === other.id), other);

  await verifyCloudRevisions(line.text, revisedText);

  step = 'post, reply to and resolve a project discussion';
  await openDiscussion();
  await session.waitFor(nodes => nodes.some(node => node.text === 'No comments yet')
    && nodes.some(node => node.label === 'Send message' && node.enabled === false));
  await compose(openingComment);
  await click('Reply to Scriv user');
  await session.waitFor(nodes => nodes.some(node => node.text === 'Replying to Scriv user'));
  await compose(replyComment, true);
  await session.waitFor(discussionState);
  await click('Mark resolved');
  await control(node => node.title === 'Reopen conversation');

  step = 'post a note scoped to the selected dialogue line';
  await selectDiscussionScope(1);
  await session.waitFor(nodes => nodes.some(node => node.text === 'No comments yet')
    && !nodes.some(node => node.type === 'DiscussionReadOnlyTextView'));
  await compose(lineComment);
  await session.waitFor(nodes => lineOnly(nodes, lineComment));
  await selectDiscussionScope(0);
  await session.waitFor(discussionState);
  await control(node => node.title === 'Reopen conversation');
  assert.deepEqual((await session.command('loaded-project')).project, reopened);
  assert.deepEqual(await session.command('presented-alerts'), []);

  step = 'read the committed edit from a fresh native workspace';
  const firstRoot = session.root;
  await session.close();
  session = await ScrivSession.launch(process.env.SCRIV_E2E_APP, { cloudFixtureOrigin: fixture.origin });
  assert.notEqual(session.root, firstRoot);
  await control(workspaceProject);
  const localBefore = await session.command('persisted-projects');
  assert.ok(localBefore.every(project => project.id !== edited.id && !project.cloudProjectId), 'The new workspace has no cloud replica');
  await signIn(3);
  await openCloudFromProjects(original.title);
  const downloaded = await waitForSavedProject(session, candidate => candidate.cloudProjectId === edited.cloudProjectId);
  assert.notEqual(downloaded.id, edited.id, 'Opening the remote script creates a separate local replica');
  assert.deepEqual(newReplicaContent(downloaded), newReplicaContent(edited), 'A fresh workspace downloads the complete edited cloud script');
  assert.deepEqual((await session.command('loaded-project')).project, downloaded);
  assert.deepEqual(await session.command('presented-alerts'), []);
  assert.deepEqual(await fixture.projects(), [{ id: downloaded.cloudProjectId, title: downloaded.title }]);

  step = 'download the thread and reopen it in the fresh workspace';
  await openDiscussion();
  await session.waitFor(discussionState);
  step = 'browse the saved conversation in Project activity';
  await browseProjectActivity(revisedText);
  await click('Reopen conversation');
  await control(node => node.title === 'Mark resolved');
  await session.waitFor(discussionState);
  step = 'search the real discussion member list';
  await browseDiscussionMembers();
  step = 'verify the project and line threads remain separate after download';
  await selectDiscussionScope(1);
  await session.waitFor(nodes => lineOnly(nodes, lineComment));
  await selectDiscussionScope(0);
  await session.waitFor(discussionState);
  step = 'send a mention and jump to it from a separate line thread';
  await control(node => node.label === 'Remove mention of Scriv user');
  const mention = 'Please check the revised line in this project.';
  await compose(mention);
  const posted = await session.waitFor(nodes => nodes.some(node => node.label === 'You were mentioned'));
  assert.ok(!posted.some(node => node.label === 'Remove mention of Scriv user'), 'Posting clears the selected member from the draft');
  await selectDiscussionScope(1);
  await session.waitFor(nodes => lineOnly(nodes, lineComment));
  const activity = await control(node => node.label.startsWith('Project activity, '), true);
  await session.command('activate', { target: activity.path });
  await control(node => node.type === 'UISegmentedControl' && node.segments?.[0] === 'Mentions', true);
  await selectActivityRow(mention);
  await session.waitFor(nodes => nodes.some(node => node.text === 'Comments stay with this project.')
    && nodes.some(node => node.type === 'DiscussionReadOnlyTextView' && node.text === mention)
    && nodes.some(node => node.label === 'You were mentioned'));
  assert.deepEqual((await session.command('loaded-project')).project, downloaded);
  assert.deepEqual(await session.command('presented-alerts'), []);
  await click('Close discussion');
  await verifyDiscussionHistory();
  await verifyFreeTeam();
  await verifyGenerationHistory();
  await verifyAccountReconnectAndSignOut(await verifyInterruptedCloudEditRecovery(downloaded));
  await fixture.assertNoOutbound();
  console.log('PASS: native sync, linked edit, discussions and fresh cloud replica');
}

async function verifyFailedLogout() {
  step = 'sign in to the owned Worker and save the local script';
  session = await ScrivSession.launch(process.env.SCRIV_E2E_APP, { cloudFixtureOrigin: fixture.origin });
  assert.equal((await session.command('capabilities')).cloudIsolation.network, 'loopback-only');
  await control(workspaceProject);
  await session.command('key', { input: 's', modifiers: ['command'] });
  const saved = await waitForSavedProject(session, project => project.title === 'YAM MAN');

  await signIn(1);
  await click('Close Projects', true);
  await control(workspaceProject, true);
  const signedIn = await session.waitFor(nodes => nodes.some(node => node.text?.endsWith(' · Signed in')));
  assert.ok(signedIn.some(node => workspaceProject(node) && node.hittable));
  await openWorkspacePanel('Scriv account…');
  assert.deepEqual(await fixture.sessionStates(), [{ revoked: false }]);

  step = 'sign out locally when the server cannot revoke the session';
  assert.equal(await fixture.refuseNextLogout(), true);
  await click('Sign out', true);
  const { nodes } = await observePresentedError(session,
    'Signed out on this Mac. The server could not confirm session revocation; reconnect to review your active sessions.');
  assert.ok(nodes.some(node => node.text?.endsWith(' · Local only')), 'The workspace returned to local-only state');
  assert.deepEqual(await fixture.sessionStates(), [{ revoked: false }], 'The Worker did not confirm revocation');
  assert.deepEqual((await session.command('loaded-project')).project, saved);
  assert.deepEqual(await session.command('persisted-projects'), [saved]);
  await fixture.assertNoOutbound();
  console.log('PASS: native sign-out retains the local script when server revocation fails');
}

try {
  if (args[1] === 'logout-revocation-failure') await verifyFailedLogout();
  else await runProjectJourney();
} catch (error) {
  throw new Error('Native cloud project journey failed during ' + step, { cause: error });
} finally {
  try { await session?.close(); }
  finally { await fixture.close(); }
}

async function verifyEditingLeaseRenewal(project) {
  step = 'hold the native editor open through the first genuine lease renewal';
  const line = project.entries.find(entry => entry.id === 'line-01');
  assert.equal(await fixture.watchEditingLease(project.cloudProjectId, line.id), true);
  const { script, editorID } = await openCloudDialogue(line);
  async function waitForLease(predicate) {
    const deadline = Date.now() + 15000;
    do {
      const lease = await fixture.editingLeaseState();
      if (predicate(lease)) return lease;
      await new Promise(resolve => setTimeout(resolve, 75));
    } while (Date.now() < deadline);
    throw new Error('Expected the real Worker editing lease state');
  }
  let lease = await waitForLease(lease => lease.renewals.length > 0);
  assert.equal(lease.renewals.length, 1);
  assert.equal(lease.renewals[0].status, 200);
  assert.ok(lease.renewals[0].expiresAt > lease.initialExpiresAt, 'The real Worker extended this editing lease');

  step = 'let autosave accept an edit with the renewed lease';
  const beforeEdit = await waitForSavedProject(session, candidate => candidate.id === project.id);
  const addition = ' Keep the accepted revision.';
  const text = line.text + addition;
  await session.command('type', { target: editorID, text: addition });
  await script.waitEditor(editorID, text, text.length);
  assert.equal((await waitForLease(lease => lease.acceptedEdits > 0)).acceptedEdits, 1, 'The Worker accepted the edit under the same renewed lease');
  const saved = await waitForSavedProject(session, candidate => candidate.id === project.id && candidate.revision > beforeEdit.revision
    && candidate.entries.some(entry => entry.id === line.id && entry.text === text));

  step = 'show the rejected renewal and preserve the accepted edit';
  await observePresentedError(session, 'Editing lease expired. Your local draft is kept; reacquire the line before saving.');
  lease = await fixture.editingLeaseState();
  assert.deepEqual(lease.renewals.map(renewal => renewal.status), [200, 423]);
  assert.equal(lease.acceptedEdits, 1);
  assert.deepEqual((await session.command('loaded-project')).project, saved);
  assert.deepEqual((await session.command('persisted-projects')).find(candidate => candidate.id === saved.id), saved);
  console.log('PASS: native editor renews its lease, saves under it and preserves the edit after renewal fails');
}

async function verifySavedCloudEditRetry(edited) {
  step = 'retain the edit while its cloud receipt is unavailable';
  const { alert } = await observePresentedError(session, lostCloudEditReceipt);
  assert.deepEqual(alert.actions, [{ title: 'OK', enabled: true, style: 'default' }]);
  const first = await fixture.editReceiptState();
  assert.equal(first.attempts, 1, 'The edit was sent once and committed by the real Worker');
  assert.ok(Number.isSafeInteger(first.sequence) && first.sequence > 0);

  const outbox = join(session.root, 'Outbox');
  const [scope, ...others] = await readdir(outbox);
  assert.match(scope, /^[0-9a-f]{64}$/);
  assert.deepEqual(others, []);
  const directory = join(outbox, scope);
  const pendingName = first.commandID + '.json';
  assert.deepEqual(await readdir(directory), [pendingName]);
  const pending = JSON.parse(await readFile(join(directory, pendingName), 'utf8'));
  assert.equal(pending.projectId, edited.cloudProjectId);
  assert.equal(pending.endpoint, 'commands');
  assert.equal(pending.payload.commandId, first.commandID);
  assert.equal(await fixture.matchesPendingEdit(pending.payload), true, 'Outbox contains the exact submitted edit');

  step = 'acknowledge the saved cloud edit error and retry via the native account sheet';
  assert.ok((await session.command('capabilities')).semanticApplicationCommands.includes('acknowledge-cloud-save-error'));
  await assert.rejects(session.command('acknowledge-cloud-save-error', { message: 'Different cloud error' }), /Cloud save error acknowledgement is unavailable/);
  assert.deepEqual(await session.command('presented-alerts'), [alert]);
  assert.deepEqual(await session.command('acknowledge-cloud-save-error', { message: lostCloudEditReceipt }), { acknowledged: true });
  await control(workspaceProject, true);
  assert.deepEqual(await session.command('presented-alerts'), []);
  assert.deepEqual((await session.command('loaded-project')).project, edited);
  assert.deepEqual(await readdir(directory), [pendingName], 'Acknowledgement alone leaves the edit pending');
  await assert.rejects(session.command('acknowledge-cloud-save-error', { message: lostCloudEditReceipt }), /Cloud save error acknowledgement is unavailable/);

  await openWorkspacePanel('Scriv account…');
  await click('Retry saved cloud commands', true);
  await control(node => node.title === 'Sync this script', true);
  await session.command('key', { input: 'Escape', modifiers: [] });
  await control(workspaceProject, true);
  assert.deepEqual(await session.command('presented-alerts'), []);
  assert.deepEqual(await fixture.editReceiptState(), { ...first, attempts: 2 });
  assert.deepEqual(await readdir(directory), [], 'The original receipt clears the exact pending edit');
  assert.deepEqual((await session.command('loaded-project')).project, edited);
  assert.deepEqual((await session.command('persisted-projects')).find(project => project.id === edited.id), edited);
  console.log('PASS: native reconnect retries the exact saved edit and receives the original cloud receipt');
}

async function verifyInterruptedCloudEditRecovery(project) {
  step = 'save a local cloud edit interrupted before its first commit';
  const line = project.entries.find(entry => entry.id === 'line-01');
  const text = await appendToCloudDialogue(line, ' Keep the invoice on file.', () => fixture.interruptNextEdit(project.cloudProjectId));
  const saved = await waitForSavedProject(session, candidate => candidate.id === project.id
    && candidate.entries.find(entry => entry.id === line.id)?.text === text);
  assert.equal(saved.revision, project.revision + 1);
  assert.deepEqual(saved.entries.filter(entry => entry.id !== line.id), project.entries.filter(entry => entry.id !== line.id));
  await observePresentedError(session, interruptedCloudEdit);
  const interrupted = await fixture.interruptedEditState();
  assert.equal(interrupted.phase, 'interrupted');
  const outbox = join(session.root, 'Outbox');
  const [scope, ...others] = await readdir(outbox);
  assert.match(scope, /^[0-9a-f]{64}$/);
  assert.deepEqual(others, []);
  const directory = join(outbox, scope);
  const pendingName = interrupted.commandID + '.json';
  assert.deepEqual(await readdir(directory), [pendingName]);
  const original = await readFile(join(directory, pendingName));
  assert.deepEqual(await session.command('acknowledge-cloud-save-error', { message: interruptedCloudEdit }), { acknowledged: true });
  await control(workspaceProject, true);
  assert.equal((await fixture.interruptedEditState()).leaseReleased, true, 'Closing the editor released the original lease through the Worker');

  step = 'reconcile a rejected saved edit through the same Account retry control';
  await openWorkspacePanel('Scriv account…');
  await click('Retry saved cloud commands', true);
  await control(node => node.title === 'Sync this script', true);
  await session.command('key', { input: 'Escape', modifiers: [] });
  await control(workspaceProject, true);
  const recovered = await fixture.interruptedEditState();
  assert.equal(recovered.phase, 'reconciled');
  assert.equal(recovered.commandID, interrupted.commandID);
  assert.equal(recovered.retryStatus, 423);
  assert.equal(recovered.retryCode, 'lease_required');
  assert.ok(recovered.replacementID && recovered.replacementID !== recovered.commandID);
  assert.ok(Number.isSafeInteger(recovered.sequence) && recovered.sequence > 0);
  const rejectedName = interrupted.commandID + '.rejected';
  assert.deepEqual(await readdir(directory), [rejectedName]);
  assert.ok(original.equals(await readFile(join(directory, rejectedName))), 'The rejected command retains its exact original bytes');
  assert.deepEqual(await session.command('presented-alerts'), []);
  assert.deepEqual((await session.command('loaded-project')).project, saved);
  assert.deepEqual((await session.command('persisted-projects')).find(candidate => candidate.id === saved.id), saved);
  console.log('PASS: native recovery preserves a definitively rejected command and synchronizes the same local edit under a new command');
  return saved;
}

async function verifyAccountReconnectAndSignOut(downloaded) {
  step = 'resync the existing cloud script through the native account sheet';
  await openWorkspacePanel('Scriv account…');
  await click('Sync this script', true);
  // The account sheet briefly disables Sync while the linked copy reattaches.
  await session.waitFor(nodes => nodes.some(node => node.title === 'Sync this script' && node.enabled === false));
  await control(node => node.title === 'Sync this script', true);
  await session.command('key', { input: 'Escape', modifiers: [] });
  await control(workspaceProject, true);
  assert.deepEqual(await session.command('presented-alerts'), []);
  assert.deepEqual((await session.command('loaded-project')).project, downloaded);
  assert.deepEqual((await session.command('persisted-projects')).find(candidate => candidate.id === downloaded.id), downloaded);
  assert.deepEqual(await fixture.projects(), [{ id: downloaded.cloudProjectId, title: downloaded.title }]);

  step = 'sign out and verify cloud revocation with the saved script intact';
  assert.deepEqual(await fixture.sessionStates(), [{ revoked: true }, { revoked: false }, { revoked: false }]);
  await openWorkspacePanel('Scriv account…');
  await click('Sign out', true);
  await control(workspaceProject, true);
  await session.command('activate', { target: (await control(workspaceProject)).path });
  await control(node => node.title === 'Sign in to Scriv…' || node.label === 'Sign in to Scriv…', true);
  assert.deepEqual(await fixture.sessionStates(), [{ revoked: true }, { revoked: false }, { revoked: true }],
    'Only the newer session belonging to the signed-out workspace was revoked');
  await click('Close Projects', true);
  await control(workspaceProject, true);
  assert.deepEqual((await session.command('loaded-project')).project, downloaded);
  assert.deepEqual((await session.command('persisted-projects')).find(candidate => candidate.id === downloaded.id), downloaded);
  assert.deepEqual(await session.command('presented-alerts'), []);
  console.log('PASS: native account reconnect and sign-out preserves the saved replica');
}


async function openWorkspacePanel(title) {
  const button = await control(node => node.label === 'Workspace actions', true);
  const menu = await session.command('menu', { target: button.path });
  assert.ok(menu.primary[0].children.some(group => group.children?.some(action => action.title === title && !action.disabled)));
  assert.deepEqual(await session.command('menu-action', { target: button.path, scope: 'workspace-panels', action: title }),
    { dispatched: true, coverage: 'semantic-menu-action' });
}

async function verifyPanelRefusals() {
  step = 'refuse unsupported or mismatched workspace menu requests';
  assert.ok((await session.command('capabilities')).semanticMenuActionScopes.includes('workspace-panels'));
  const menu = await control(node => node.label === 'Workspace actions');
  const project = await control(workspaceProject);
  const select = { target: menu.path, scope: 'workspace-panels', action: 'History…' };
  for (const args of [
    { ...select, action: 'Scriv account…' }, { ...select, action: 'New project' },
    { ...select, unexpected: true }, { ...select, target: project.path },
  ]) await assert.rejects(session.command('menu-action', args), /Workspace panel action is unavailable/);
  assert.deepEqual(await session.command('presented-alerts'), []);
}

function historyRows(nodes, title) {
  return nodes.filter(row => row.type === 'HistoryEventCell' && row.hittable
    && nodes.some(child => child.path.startsWith(row.path + '.') && child.text === title));
}
async function selectSegment(labels, index) {
  const segment = await control(node => node.type === 'UISegmentedControl' && node.segments?.join('|') === labels, true);
  await session.command('select', { target: segment.path, index });
}
function assertReadOnlyScript(text) {
  return session.waitFor(nodes => nodes.some(node => node.type === 'ScriptTextView' && node.text === text && node.editable === false && node.hittable));
}

async function verifyCloudRevisions(original, edited) {
  step = 'compare the prior import and edited script in native cloud history';
  const before = await session.command('loaded-project');
  await openWorkspacePanel('History…');
  await selectSegment('This Mac|Cloud', 1);
  await selectSegment('Changes|Revision preview', 1);
  for (const [title, text] of [['Import project', original], ['Edit script', edited]]) {
    const nodes = await session.waitFor(nodes => historyRows(nodes, title).length === 1);
    const { path: target } = historyRows(nodes, title)[0];
    await assert.rejects(session.command('activate', { target, unexpected: true }), /History row cannot be selected/);
    assert.deepEqual(await session.command('activate', { target }), { dispatched: true });
    await assertReadOnlyScript(text);
  }
  await click('Close', true);
  await control(workspaceProject, true);
  assert.deepEqual(await session.command('loaded-project'), before);
}

async function verifyDiscussionHistory() {
  step = 'review a discussion event without offering script restore';
  await openWorkspacePanel('History…');
  await selectSegment('This Mac|Cloud', 1);
  const nodes = await session.waitFor(nodes => historyRows(nodes, 'Send message').length > 0);
  const target = historyRows(nodes, 'Send message').reduce((a, b) => a.frame.y < b.frame.y ? a : b).path;
  assert.deepEqual(await session.command('activate', { target }), { dispatched: true });
  const activity = await session.waitFor(nodes => nodes.some(node => node.text === 'This event is not a script restore point. Restoring never rewinds the conversation.'));
  assert.ok(activity.some(node => node.title === 'Restore revision…' && node.enabled === false));
  await selectSegment('Changes|Revision preview', 1);
  await session.waitFor(nodes => nodes.some(node => node.text === 'No script snapshot is available for this event.'));
  await click('Close', true);
  await control(workspaceProject, true);
}

async function verifyFreeTeam() {
  step = 'review free-team membership and invitation availability';
  await openWorkspacePanel('Teams and sharing…');
  const owner = nodes => nodes.some(node => node.text === 'Members (1)')
    && nodes.some(node => node.text === 'Scriv user (you)') && nodes.some(node => node.text === 'Owner of this team');
  const members = await session.waitFor(owner);
  assert.ok(members.some(node => node.title === nativeFixtureTeam));
  assert.ok(members.some(node => node.text === 'Not active'));
  await click('Refresh members', true);
  await session.waitFor(owner);
  await selectSegment('Overview|Members|Invitations', 0);
  await session.waitFor(nodes => nodes.some(node => node.text === 'One plan for the whole team')
    && nodes.some(node => node.text === 'This project is not shared with this team'));
  await selectSegment('Overview|Members|Invitations', 2);
  const invitations = await session.waitFor(nodes => nodes.some(node => node.text === 'No invitation links yet.'));
  assert.ok(invitations.some(node => node.text === 'Activate Team first'));
  assert.ok(invitations.some(node => node.title === 'Create & copy link' && node.enabled === false));
  await click('Done', true);
  await control(workspaceProject, true);
}

async function verifyGenerationHistory() {
  step = 'review empty local and shared generation history';
  await openWorkspacePanel('Generation history…');
  await session.waitFor(nodes => nodes.some(node => node.text === 'No generation jobs yet'));
  await selectSegment('This Mac|Shared project', 1);
  await session.waitFor(nodes => nodes.some(node => node.text === 'No shared jobs for this project'));
  await session.command('key', { input: 'Escape', modifiers: [] });
  await control(workspaceProject, true);
}
