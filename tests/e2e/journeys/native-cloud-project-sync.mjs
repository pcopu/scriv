import assert from 'node:assert/strict';
import { ScrivSession } from '../../../cli/scriv.mjs';
import { waitForSavedProject } from '../support/saved-projects.mjs';
import { nativeFixtureEmail, startNativeCloudFixture } from './support/native-cloud-fixture.mjs';

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
try {
  session = await ScrivSession.launch(process.env.SCRIV_E2E_APP, { cloudFixtureOrigin: fixture.origin });
  const capabilities = await session.command('capabilities');
  assert.equal(capabilities.cloudIsolation.network, 'loopback-only');
  assert.ok(capabilities.syntheticFixtureCommands.includes('receive-fixture-email-code'), 'The owned synthetic mailbox action is missing');
  assert.ok(capabilities.semanticMenuActionScopes.includes('workspace-discussion'), 'The workspace discussion menu route is missing');
  await assert.rejects(session.command('receive-fixture-email-code'), /synthetic sign-in mailbox is unavailable/);
  const project = await control(workspaceProject);
  await session.command('key', { input: 's', modifiers: ['command'] });
  const original = await waitForSavedProject(session, candidate => candidate.title === 'YAM MAN');
  assert.equal(original.cloudProjectId ?? null, null);
  assert.deepEqual(await fixture.projects(), []);

  step = 'verify the owned email challenge';
  await session.command('activate', { target: project.path });
  await click('Sign in to Scriv…', true);
  const email = await control(node => node.type === 'UITextField' && node.label === 'Email address', true);
  await session.command('text', { target: email.path, text: nativeFixtureEmail });
  await click('Continue with email');
  await session.waitFor(nodes => nodes.some(node => node.text === 'Check your email'));
  assert.equal(await fixture.deliveries(), 1);
  const codeField = await control(node => node.type === 'UITextField' && node.sensitive && node.text === '<redacted>', true);
  await assert.rejects(session.command('text', { target: codeField.path, text: 'blocked input' }), /Sensitive input is unavailable/);
  assert.equal((await session.command('snapshot')).find(node => node.title === 'Sign in with code')?.enabled, false);
  assert.deepEqual(await session.deliverFixtureEmailCode(await fixture.takeCode()), { delivered: true });
  assert.ok((await session.command('snapshot')).some(node => node.sensitive && node.text === '<redacted>'));
  await click('Sign in with code');
  await assert.rejects(session.deliverFixtureEmailCode('000000'), /owned synthetic sign-in mailbox is unavailable/);
  await click('Close Projects', true);
  await control(workspaceProject, true);

  step = 'create and seed the cloud project through Discussion';
  const actions = await control(node => node.label === 'Workspace actions');
  const menu = await session.command('menu', { target: actions.path });
  assert.ok(menu.primary[0].children.some(group => group.children?.some(action => action.title === 'Discussion' && !action.disabled)));
  assert.deepEqual(await session.command('menu-action', {
    target: actions.path, scope: 'workspace-discussion', action: 'Discussion',
  }), { dispatched: true, coverage: 'semantic-menu-action' });
  await click('Save script to cloud');
  const synced = await waitForSavedProject(session, candidate => candidate.id === original.id && Boolean(candidate.cloudProjectId));
  assert.deepEqual(await fixture.projects(), [{ id: synced.cloudProjectId, title: original.title }]);
  await session.waitFor(nodes => nodes.some(node => node.type === 'DiscussionComposerTextView' && node.editable && node.hittable));
  await click('Close discussion');
  assert.deepEqual(await session.command('presented-alerts'), []);

  step = 'open the cloud project after switching to a distinct local project';
  await session.command('key', { input: 'n', modifiers: ['command'] });
  const other = await waitForSavedProject(session, candidate => candidate.id !== original.id);
  assert.equal(other.cloudProjectId ?? null, null);
  const browser = await control(node => workspaceProject(node) && node.title === other.title, true);
  await session.command('activate', { target: browser.path });
  await control(projectsSearch, true);
  await click('Scriv Cloud');
  await session.waitFor(nodes => nodes.some(node => node.text === original.title + ' · Cloud project'));
  await click('Open project');
  await control(node => workspaceProject(node) && node.title === original.title, true);
  const reopened = await waitForSavedProject(session, candidate => candidate.id === original.id && candidate.revision > synced.revision);
  assert.deepEqual(content(reopened), content(synced), 'Reopening preserves the complete synchronized model');
  assert.deepEqual((await session.command('loaded-project')).project, reopened);
  assert.deepEqual(await session.command('presented-alerts'), []);
  assert.deepEqual(await fixture.projects(), [{ id: reopened.cloudProjectId, title: reopened.title }]);
  assert.deepEqual((await session.command('persisted-projects')).find(candidate => candidate.id === other.id), other);
  await fixture.assertNoOutbound();
  console.log('PASS: native synthetic sign-in, first cloud sync and cloud project reopen');
} catch (error) {
  throw new Error('Native cloud project journey failed during ' + step, { cause: error });
} finally {
  try { await session?.close(); }
  finally { await fixture.close(); }
}
