import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import { join } from 'node:path';
import { ScrivSession } from '../../../cli/scriv.mjs';
import { observePresentedError } from '../support/presented-error.mjs';
import { waitForSavedProject } from '../support/saved-projects.mjs';
import { nativeFixtureEmail, nativeFixtureTeam, lostCloudEditReceipt, startNativeCloudFixture } from './support/native-cloud-fixture.mjs';
import { byID as nodesByID, keyIs, scriptAuthoringSteps } from './support/script-authoring-steps.mjs';

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

try {
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
  const original = await waitForSavedProject(session, candidate => candidate.title === 'YAM MAN');
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

  step = 'edit an already-linked script through the native editor';
  const script = scriptAuthoringSteps(session);
  await script.selectTab('Script');
  const line = synced.entries.find(entry => entry.id === 'line-01');
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
  const addition = ' Ask about the invoice.';
  const revisedText = line.text + addition;
  await fixture.loseNextEditReceipt(synced.cloudProjectId);
  await session.command('type', { target: editorID, text: addition });
  await script.waitEditor(editorID, revisedText, revisedText.length);
  await script.finishEditor();
  const edited = await waitForSavedProject(session, candidate => candidate.id === synced.id
    && candidate.entries.some(entry => entry.id === line.id && entry.text === revisedText));
  assert.equal(edited.cloudProjectId, synced.cloudProjectId);
  assert.equal(edited.entries.length, synced.entries.length);
  for (const previous of synced.entries.filter(entry => entry.id !== line.id)) {
    assert.equal(edited.entries.find(entry => entry.id === previous.id)?.text, previous.text);
  }
  await verifySavedCloudEditRetry(edited);
  await script.displayed(line.id, revisedText, { finished: true });

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
  await verifyAccountReconnectAndSignOut(downloaded);
  await fixture.assertNoOutbound();
  console.log('PASS: native sync, linked edit, discussions and fresh cloud replica');
} catch (error) {
  throw new Error('Native cloud project journey failed during ' + step, { cause: error });
} finally {
  try { await session?.close(); }
  finally { await fixture.close(); }
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
