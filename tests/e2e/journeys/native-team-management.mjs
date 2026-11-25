import assert from 'node:assert/strict';
import { ScrivSession } from '../../../cli/scriv.mjs';
import { observePresentedAlert } from '../support/presented-error.mjs';
import { waitForSavedProject } from '../support/saved-projects.mjs';
import { audioLibrarySteps } from './support/audio-library-steps.mjs';
import { nativeFixtureEmail, startNativeCloudFixture } from './support/native-cloud-fixture.mjs';

const groups = ['invitation-link-formats'];
const args = process.argv.slice(2);
if (args.length === 1 && args[0] === '--list-cases') {
  console.log(JSON.stringify({ groups }));
  process.exit(0);
}
assert.ok(args.length === 0 || (args.length === 2 && args[0] === '--group' && groups.includes(args[1])));
const invitationFormats = args[1] === 'invitation-link-formats';

assert.ok(process.env.SCRIV_E2E_APP, 'Requires a signed Catalyst automation build');
const fixture = await startNativeCloudFixture();
const id = value => node => node.identifier === value;
const button = value => node => node.type === 'UIButton' && (node.title === value || node.label === value);
const present = value => nodes => nodes.some(node => node.text === value);
const ready = node => node.hittable && node.enabled;
const dispatched = { dispatched: true, coverage: 'semantic-menu-action' };
const roleScope = 'team-member-actions';
let session;

try {
  const { memberID, invitedTeamID, invitation } = await fixture.prepareTeamManagement();
  session = await ScrivSession.launch(process.env.SCRIV_E2E_APP, { cloudFixtureOrigin: fixture.origin });
  const capabilities = await session.command('capabilities');
  assert.equal(capabilities.cloudIsolation.network, 'loopback-only');
  assert.equal(capabilities.cloudIsolation.peerTransport, 'disabled');
  const ui = audioLibrarySteps(session);

  async function click(match, settleFor = 100) {
    const matches = nodes => nodes.filter(node => match(node) && ready(node));
    let prior, since;
    const nodes = await session.waitFor(nodes => {
      const [node, other] = matches(nodes);
      const key = node && !other ? JSON.stringify([node.path, node.frame]) : undefined;
      if (!key || key !== prior) { prior = key; since = Date.now(); return false; }
      return Date.now() - since >= settleFor;
    });
    assert.deepEqual(await session.command('activate', { target: matches(nodes)[0].path }), { dispatched: true });
  }
  const waitButton = match => session.waitFor(nodes => nodes.filter(node => match(node) && ready(node)).length === 1);
  const selectedTeam = name => waitButton(button(name));
  async function openTeams() {
    const workspaceActions = node => node.label === 'Workspace actions' && ready(node);
    const nodes = await waitButton(workspaceActions);
    assert.deepEqual(await session.command('menu-action', { scope: 'workspace-panels', action: 'Teams and sharing…',
      target: nodes.find(workspaceActions).path }), dispatched);
  }
  const action = id('team-operation-submit');
  const cancel = id('team-operation-cancel');
  async function form(title, stimulus) {
    await click(stimulus);
    try {
      await session.waitFor(nodes => present(title)(nodes) && nodes.some(node => action(node) && ready(node)), 4000);
    } catch (error) {
      if ((await session.command('presented-alerts')).some(item => item.title === title)) {
        throw new Error('Team operation needs an actionable native form', { cause: error });
      }
      throw error;
    }
  }
  async function input(text) {
    const field = await ui.reveal(id('team-operation-field'));
    await session.command('text', { target: field.path, text });
  }
  const teamsState = () => fixture.teamManagementState();

  await ui.tab('Script');
  await session.command('key', { input: 's', modifiers: ['command'] });
  const packageBefore = await waitForSavedProject(session, project => project.title === 'YAM MAN');
  const loadedBefore = await session.command('loaded-project');
  await click(id('workspace-project'), 1000);
  await click(button('Sign in to Scriv…'), 1000);
  const email = await ui.reveal(node => node.type === 'UITextField' && node.label === 'Email address');
  await session.command('text', { target: email.path, text: nativeFixtureEmail });
  await click(button('Continue with email'), 1000);
  await session.waitFor(present('Check your email'));
  assert.deepEqual(await session.deliverFixtureEmailCode(await fixture.takeCode()), { delivered: true });
  await click(button('Sign in with code'), 1000);
  await click(button('Close Projects'), 1000);

  await openTeams();
  await session.waitFor(present('Make room for collaborators'));
  const original = await teamsState();
  assert.ok(original.selfID);
  assert.deepEqual(original.teams, [{ id: invitedTeamID, name: 'Synthetic guest Team', status: 'active' }]);
  assert.deepEqual(original.members, [{ teamID: invitedTeamID, memberID, role: 'owner' }]);

  if (invitationFormats) {
    const otherServer = new URL(fixture.origin);
    otherServer.port = String(Number(otherServer.port) === 65535 ? 65534 : Number(otherServer.port) + 1);
    const invalid = [
      ['not-an-invitation', 'Paste a valid Scriv team invitation link or token.'],
      ['scriv://invalid-host/' + invitation, 'This is not a Scriv team invitation.'],
      [new URL('/join/' + invitation, otherServer).href, 'This invitation belongs to a different Scriv server. Check the server in Settings.'],
      ['file:///join/' + invitation, 'This is not a Scriv team invitation.'],
      ['scriv://join/incomplete', 'This invitation token is incomplete or invalid.'],
    ];
    for (const [value, error] of invalid) {
      await form('Join a team', button('Join'));
      await input(value);
      await click(action);
      await session.waitFor(nodes => !nodes.some(action) && present(error)(nodes));
      assert.deepEqual(await teamsState(), original);
    }
    for (const value of ['scriv://join/' + invitation, fixture.origin + '/join/' + invitation]) {
      await form('Join a team', button('Join'));
      await input(value);
      await click(action);
      await selectedTeam('Synthetic guest Team');
      const joined = await teamsState();
      assert.deepEqual(joined.teams, original.teams);
      assert.deepEqual(joined.members.filter(member => member.memberID === original.selfID),
        [{ teamID: invitedTeamID, memberID: original.selfID, role: 'viewer' }]);
      await form('Leave this team?', button('Leave team…'));
      await click(action);
      await session.waitFor(nodes => !nodes.some(action) && nodes.some(button('No teams yet')));
      assert.deepEqual(await teamsState(), original);
    }
  } else {
    await form('Create a team', button('New team'));
    await input('   ');
    await click(action);
    await session.waitFor(present('Enter a team name of 1–100 characters.'));
    assert.deepEqual(await teamsState(), original);
    await click(cancel);
    await form('Create a team', button('New team'));
    await input('  Synthetic new Team  ');
    await click(action);
    await selectedTeam('Synthetic new Team');
    const createdState = await teamsState();
    const created = createdState.teams.find(team => team.id !== invitedTeamID);
    assert.ok(created?.id);
    assert.deepEqual(created, { id: created.id, name: 'Synthetic new Team', status: 'free' });
    assert.deepEqual(createdState.members.find(member => member.teamID === created.id),
      { teamID: created.id, memberID: original.selfID, role: 'owner' });

    await form('Rename team', button('Rename team'));
    await input('Synthetic renamed Team');
    await click(action);
    await selectedTeam('Synthetic renamed Team');
    const renamed = await teamsState();
    assert.deepEqual(renamed, { ...createdState, teams: createdState.teams.map(team =>
      team.id === created.id ? { ...team, name: 'Synthetic renamed Team' } : team) });

    assert.equal(await fixture.addTeamManagementMember(created.id), true);
    await click(button('Refresh members'));
    await session.waitFor(present('Members (2)'));
    assert.ok(capabilities.semanticMenuActionScopes.includes(roleScope));
    const roleButton = id('team-member-role-' + memberID);
    const memberActions = id('team-member-options-' + memberID);
    async function memberAction(target, title, extra) {
      const control = await ui.reveal(target);
      return session.command('menu-action', { target: control.path, scope: roleScope, action: title,
        teamID: created.id, memberID, ...extra });
    }
    const roleControl = await ui.reveal(roleButton);
    const roleMenu = await session.command('menu', { target: roleControl.path });
    const viewer = roleMenu.primary[0].children.find(item => item.title.startsWith('Viewer · '));
    assert.equal(viewer?.state, 'off');
    const withMember = await teamsState();
    await assert.rejects(memberAction(roleButton, viewer.title, { teamID: invitedTeamID }), /outside the supported isolated scope/);
    await assert.rejects(memberAction(roleButton, viewer.title, { memberID: original.selfID }), /outside the supported isolated scope/);
    assert.deepEqual(await teamsState(), withMember);
    assert.deepEqual(await memberAction(roleButton, viewer.title), dispatched);
    await waitButton(node => roleButton(node) && node.title === 'Viewer');
    const afterRole = await teamsState();
    assert.deepEqual(afterRole, { ...withMember, members: withMember.members.map(member =>
      member.teamID === created.id && member.memberID === memberID ? { ...member, role: 'viewer' } : member) });
    for (const confirm of [false, true]) {
      assert.deepEqual(await memberAction(memberActions, 'Remove member…'), dispatched);
      await session.waitFor(present('Remove Synthetic collaborator?'));
      await click(confirm ? action : cancel);
      await session.waitFor(nodes => !nodes.some(action) && present(confirm ? 'Members (1)' : 'Members (2)')(nodes));
      assert.deepEqual(await teamsState(), confirm ? renamed : afterRole);
    }

    await form('Join a team', button('Join'));
    await input('x'.repeat(43));
    await click(action);
    await session.waitFor(present('This invite has expired or been revoked.'));
    assert.deepEqual(await teamsState(), renamed);
    await form('Join a team', button('Join'));
    await input(invitation);
    await click(action);
    await selectedTeam('Synthetic guest Team');
    const joined = await teamsState();
    assert.deepEqual(joined.members.filter(member => member.memberID === original.selfID).map(member => member.role).sort(), ['owner', 'viewer']);
    assert.deepEqual(joined.teams, renamed.teams);
    await form('Leave this team?', button('Leave team…'));
    await click(action);
    await selectedTeam('Synthetic renamed Team');
    assert.deepEqual(await teamsState(), renamed);
  }
  await click(button('Done'));
  await waitButton(id('workspace-project'));
  assert.deepEqual(await session.command('loaded-project'), loadedBefore);
  assert.deepEqual(await session.command('persisted-projects'), [packageBefore]);
  assert.deepEqual(await fixture.projectTeams(), []);
  if (!invitationFormats) {
    const beforeCheckout = await teamsState();
    const freeTeam = beforeCheckout.teams.find(team => team.name === 'Synthetic renamed Team');
    assert.equal(freeTeam?.status, 'free');
    assert.ok(beforeCheckout.members.some(member => member.teamID === freeTeam.id
      && member.memberID === beforeCheckout.selfID && member.role === 'owner'));
    await openTeams();
    await selectedTeam(freeTeam.name);
    await ui.activate(button('Subscribe…'));
    await observePresentedAlert(session, {
      title: 'Open Team subscription checkout?',
      message: '$9.99/month for the whole team, with no per-seat charge. Checkout opens in your browser; this button does not complete a payment.',
      actions: [
        { title: 'Cancel', style: 'cancel', enabled: true },
        { title: 'Open checkout', style: 'default', enabled: true },
      ],
    });
    assert.deepEqual(await teamsState(), beforeCheckout);
    assert.deepEqual(await session.command('persisted-projects'), [packageBefore]);
  }
  await fixture.assertNoOutbound();
} finally {
  try { await session?.close(); }
  finally { await fixture.close(); }
}
