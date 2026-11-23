import assert from 'node:assert/strict';
import { isDeepStrictEqual } from 'node:util';
import { ScrivSession } from '../../../cli/scriv.mjs';
import { waitForSavedProject } from '../support/saved-projects.mjs';
import { audioLibrarySteps, sortedProjects } from './support/audio-library-steps.mjs';
import { audioProjectFixture } from './support/audio-library-fixtures.mjs';
import { nativeFixtureEmail, nativeFixtureTeam, startNativeCloudFixture } from './support/native-cloud-fixture.mjs';

assert.ok(process.env.SCRIV_E2E_APP, 'Requires a signed Catalyst automation build');
const fixture = await startNativeCloudFixture();
const ready = node => node.enabled && node.hittable;
const byID = id => node => node.identifier === id;
const button = title => node => node.type === 'UIButton' && (node.title === title || node.label === title);
const teamHeading = `Share with ${nativeFixtureTeam}?`;
const shareCopy = 'Create a separate team copy. The original project and its history remain unchanged.';
const shareLocal = 'Share the current project with this team. Local files remain on this device.';
const dispatched = { dispatched: true, coverage: 'semantic-menu-action' };
const byTitle = rows => [...rows].sort((a, b) => a.title.localeCompare(b.title));
const byItemID = (a, b) => a.id.localeCompare(b.id);
const documentOf = ({ id, title, cloudProjectId, revision, createdAt, modifiedAt, entries, characters, ...rest }) => ({
  ...rest, entries: [...entries].sort(byItemID), characters: [...characters].sort(byItemID),
});
let session;
let step = 'set up a paid synthetic Team and sign in';

try {
  const team = await fixture.createPaidTeam();
  assert.match(team.id, /^[a-f0-9-]{36}$/i);
  session = await ScrivSession.launch(process.env.SCRIV_E2E_APP, { cloudFixtureOrigin: fixture.origin });
  const caps = await session.command('capabilities');
  assert.equal(caps.cloudIsolation.network, 'loopback-only');
  assert.equal(caps.cloudIsolation.peerTransport, 'disabled');
  const ui = audioLibrarySteps(session);
  const packages = async () => sortedProjects(await session.command('persisted-projects'));
  const projectButton = byID('workspace-project');
  async function readyControl(matches, settle = false) {
    const select = nodes => nodes.filter(node => matches(node) && ready(node));
    let last, since;
    const nodes = await session.waitFor(nodes => {
      const [node, other] = select(nodes);
      if (!settle) return !!node && !other;
      const key = node && !other ? JSON.stringify([node.path, node.frame]) : undefined;
      if (!key || key !== last) { last = key; since = Date.now(); return false; }
      return Date.now() - since >= 1000;
    });
    return select(nodes)[0];
  }
  async function click(matches) {
    const target = (await readyControl(matches, true)).path;
    await session.command('activate', { target });
  }
  async function openPanel(scope, action) {
    const menu = await readyControl(node => node.label === 'Workspace actions');
    assert.deepEqual(await session.command('menu-action', { target: menu.path, scope, action }), dispatched);
  }
  async function openTeams() {
    await openPanel('workspace-panels', 'Teams and sharing…');
    await session.waitFor(nodes => nodes.some(node => node.text === 'Members (1)')
      && nodes.some(node => node.text === '● Active'));
  }
  async function openConfirmation(message) {
    await ui.activate(button('Share team copy'));
    const active = await session.waitFor(nodes => nodes.some(node => node.text === teamHeading)
      && nodes.some(node => node.text === message)
      && nodes.some(node => byID('team-share-confirm')(node) && ready(node)), 5000).catch(async error => {
      const alerts = await session.command('presented-alerts');
      const legacy = alerts.find(item => item.title === teamHeading && item.message === message);
      if (legacy) throw new Error(`The native alert presents ${legacy.actions.map(action => action.title).join(' and ')} without the expected public share control`, { cause: error });
      throw error;
    });
    const confirm = active.find(byID('team-share-confirm'));
    assert.equal(confirm.title, 'Share');
    assert.ok(active.some(node => byID('team-share-cancel')(node) && node.windowPath === confirm.windowPath));
  }

  await ui.tab('Script');
  await session.command('key', { input: 's', modifiers: ['command'] });
  const sample = await waitForSavedProject(session, project => project.title === 'YAM MAN');
  await click(projectButton);
  await click(button('Sign in to Scriv…'));
  const email = await ui.reveal(node => node.type === 'UITextField' && node.label === 'Email address');
  await session.command('text', { target: email.path, text: nativeFixtureEmail });
  await click(button('Continue with email'));
  await session.waitFor(nodes => nodes.some(node => node.text === 'Check your email'));
  assert.deepEqual(await session.deliverFixtureEmailCode(await fixture.takeCode()), { delivered: true });
  await click(button('Sign in with code'));
  await click(button('Close Projects'));
  await readyControl(projectButton);
  assert.deepEqual(await fixture.projectTeams(), []);

  step = 'create a personal cloud project without Team membership';
  await openPanel('workspace-discussion', 'Discussion');
  await click(button('Save script to cloud'));
  await waitForSavedProject(session, project => project.id === sample.id && !!project.cloudProjectId);
  await click(button('Close discussion'));
  await readyControl(projectButton);
  const personalLoaded = await session.command('loaded-project');
  const personal = await waitForSavedProject(session, project => isDeepStrictEqual(project, personalLoaded.project));
  const personalCloud = { id: personal.cloudProjectId, title: personal.title, teamId: null };
  assert.deepEqual(await fixture.projectTeams(), [personalCloud]);

  step = 'cancel the Team copy confirmation without changing either store';
  await openTeams();
  await openConfirmation(shareCopy);
  await click(byID('team-share-cancel'));
  await readyControl(button('Share team copy'));
  assert.deepEqual(await packages(), [personal]);
  assert.deepEqual(await fixture.projectTeams(), [personalCloud]);

  step = 'create an independent Team copy of the personal project';
  await openConfirmation(shareCopy);
  await click(byID('team-share-confirm'));
  await waitForSavedProject(session, project => project.title === `${personal.title} — Team copy` && !!project.cloudProjectId);
  await session.waitFor(nodes => nodes.some(node => node.text === 'Shared with this team'));
  await click(button('Open project'));
  await readyControl(projectButton);
  const loadedCopy = (await session.command('loaded-project')).project;
  const copy = await waitForSavedProject(session, project => isDeepStrictEqual(project, loadedCopy));
  assert.notEqual(copy.id, personal.id);
  assert.notEqual(copy.cloudProjectId, personal.cloudProjectId);
  assert.equal(copy.title, `${personal.title} — Team copy`);
  assert.deepEqual(documentOf(copy), documentOf(personal));
  const teamCopy = { id: copy.cloudProjectId, title: copy.title, teamId: team.id };
  assert.deepEqual(byTitle(await fixture.projectTeams()), byTitle([personalCloud, teamCopy]));
  assert.deepEqual(await packages(), sortedProjects([personal, copy]));
  step = 'share an unsynced local project without making a copy';
  const input = { ...audioProjectFixture(), title: 'Synthetic local Team project' };
  assert.deepEqual(await session.command('import-json', { text: JSON.stringify(input) }), { dispatched: true, projectChanged: true });
  const local = await waitForSavedProject(session, project => project.title === input.title);
  assert.equal(local.cloudProjectId, undefined);
  await openTeams();
  await openConfirmation(shareLocal);
  await click(byID('team-share-confirm'));
  await waitForSavedProject(session, project => project.id === local.id && !!project.cloudProjectId);
  await click(button('Open project'));
  await readyControl(projectButton);
  const loadedShared = (await session.command('loaded-project')).project;
  const shared = await waitForSavedProject(session, project => isDeepStrictEqual(project, loadedShared));
  assert.equal(shared.id, local.id);
  assert.equal(shared.title, local.title);
  assert.deepEqual(documentOf(shared), documentOf(local));
  assert.deepEqual(await packages(), sortedProjects([personal, copy, shared]));
  const sharedCloud = { id: shared.cloudProjectId, title: shared.title, teamId: team.id };
  assert.deepEqual(byTitle(await fixture.projectTeams()), byTitle([personalCloud, teamCopy, sharedCloud]));
  assert.deepEqual(await ui.openProject(personal), personalLoaded);
  assert.deepEqual(await session.command('presented-alerts'), []);
  await fixture.assertNoOutbound();
} catch (error) { throw new Error(`Native Team sharing failed during ${step}`, { cause: error }); }
finally {
  try { await session?.close(); }
  finally { await fixture.close(); }
}
