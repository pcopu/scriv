import assert from 'node:assert/strict';
import { setTimeout as delay } from 'node:timers/promises';
import { ScrivSession } from '../../../cli/scriv.mjs';
import { waitForSavedProject } from '../support/saved-projects.mjs';
import { audioLibrarySteps } from './support/audio-library-steps.mjs';
import { invitationLoadFailure, invitationRevokeFailure, nativeFixtureEmail, nativeFixtureTeam, startNativeCloudFixture } from './support/native-cloud-fixture.mjs';

const args = process.argv.slice(2);
const groups = ['inline'];
if (args.length === 1 && args[0] === '--list-cases') {
  console.log(JSON.stringify({ groups, groupActions: {
    inline: [{ id: 'revoke-team-invitation', command: 'activate', trigger: 'Revoke',
      condition: 'active-invitation-in-the-teams-tab-with-a-temporary-revocation-failure', entryPoint: {
        path: 'apps/catalyst/ScrivUIKit/Teams/TeamsController.swift', start: 331, end: 333,
        sha256: '7100f03dc4294f9d6e8f691878609ba3a44a0b2b61126b7598e1234f17cf41c5',
      } }, { id: 'open-team-billing-portal', command: 'activate', trigger: 'Manage billing',
      condition: 'active-owned-team-has-no-billing-customer', entryPoint: {
        path: 'apps/catalyst/ScrivUIKit/Teams/TeamsController.swift', start: 134, end: 134,
        sha256: '253085b646915365e28283284987e7322bc0362b271f90c97c0f4927399f2cc1',
      }, branch: {
        path: 'apps/catalyst/ScrivUIKit/Teams/TeamsController.swift', start: 380, end: 380,
        sha256: '2b19b9533a422c74c5cecf5d152a11da6bf7df7860047d573e626afcec134618',
      } }],
  } }));
  process.exit(0);
}
assert.ok(args.length === 0 || args.length === 2 && args[0] === '--group' && groups.includes(args[1]));
const inline = args[1] === 'inline';
assert.ok(process.env.SCRIV_E2E_APP, 'Requires a signed Catalyst automation build');
const fixture = await startNativeCloudFixture({ billingWithoutCustomer: inline });
const button = (title, windowPath) => node => node.type === 'UIButton'
  && (node.title === title || node.label === title) && (!windowPath || node.windowPath === windowPath);
const hasText = (text, windowPath) => nodes => nodes.some(node => node.text === text && (!windowPath || node.windowPath === windowPath));
let session;
let step = 'sign in to the isolated Team fixture';

try {
  const { memberID, viewerID } = await fixture.prepareInvitations();
  const before = await fixture.invitationState();
  assert.deepEqual(before.links.map(({ id, role, revokedAt }) => ({ id, role, revokedAt })),
    [{ id: memberID, role: 'member', revokedAt: null }, { id: viewerID, role: 'viewer', revokedAt: null }]);
  assert.ok(before.links[0].expiresAt > Date.now() && before.links[1].expiresAt < Date.now());
  assert.deepEqual(before.members, [{ role: 'owner' }]);
  session = await ScrivSession.launch(process.env.SCRIV_E2E_APP, { cloudFixtureOrigin: fixture.origin });
  const capabilities = await session.command('capabilities');
  assert.equal(capabilities.cloudIsolation.network, 'loopback-only');
  assert.equal(capabilities.cloudIsolation.peerTransport, 'disabled');
  assert.ok(capabilities.semanticMenuActionScopes.includes('workspace-panels'));
  const ui = audioLibrarySteps(session);
  async function clickPresented(title, windowPath) {
    const matches = nodes => nodes.filter(node => node.enabled && node.hittable && button(title, windowPath)(node));
    let prior, stableSince;
    const nodes = await session.waitFor(nodes => {
      const [target, second] = matches(nodes);
      const key = target && !second ? JSON.stringify([target.path, target.frame]) : null;
      if (!key || key !== prior) { prior = key; stableSince = Date.now(); return false; }
      return Date.now() - stableSince >= 1000;
    });
    await session.command('activate', { target: matches(nodes)[0].path });
  }
  await ui.tab('Script');
  await session.command('key', { input: 's', modifiers: ['command'] });
  const saved = await waitForSavedProject(session, project => project.title === 'YAM MAN');
  const model = await session.command('loaded-project');
  await ui.activate(node => node.identifier === 'workspace-project');
  await clickPresented('Sign in to Scriv…');
  const email = await ui.reveal(node => node.type === 'UITextField' && node.label === 'Email address');
  assert.deepEqual(await session.command(inline ? 'type' : 'text', { target: email.path, text: nativeFixtureEmail }), { dispatched: true });
  await clickPresented('Continue with email');
  await session.waitFor(hasText('Check your email'));
  assert.deepEqual(await session.deliverFixtureEmailCode(await fixture.takeCode()), { delivered: true });
  await clickPresented('Sign in with code');
  await clickPresented('Close Projects');

  step = 'open the owned paid Team';
  const menu = node => node.label === 'Workspace actions' && node.hittable && node.enabled;
  const workspaceNodes = await session.waitFor(nodes => nodes.filter(menu).length === 1);
  const menuOwner = workspaceNodes.find(menu);
  assert.deepEqual(await session.command('menu-action', { target: menuOwner.path, scope: 'workspace-panels', action: 'Teams and sharing…' }),
    { dispatched: true, coverage: 'semantic-menu-action' });
  await session.waitFor(nodes => hasText('Members (1)')(nodes) && hasText('● Active')(nodes));
  if (inline) {
    step = 'show the owned billing portal refusal and reload the team without changing it';
    const billingBefore = await fixture.billingPortalState();
    assert.equal(billingBefore.team.status, 'active');
    assert.equal(billingBefore.team.customer, null);
    assert.ok(billingBefore.team.paidUntil > Date.now());
    assert.deepEqual(billingBefore.requests, []);
    await ui.activate(node => button('Manage billing')(node) && node.enabled);
    await session.waitFor(nodes => hasText('Start a Team subscription before opening the billing portal.')(nodes)
      && hasText('● Active')(nodes) && nodes.some(node => button('Manage billing')(node) && node.enabled));
    let billingAfter = await fixture.billingPortalState();
    const refreshDeadline = Date.now() + 5000;
    while (billingAfter.teamRefreshes === 0 && Date.now() < refreshDeadline) {
      await delay(50);
      billingAfter = await fixture.billingPortalState();
    }
    assert.deepEqual(billingAfter.team, billingBefore.team);
    assert.deepEqual(billingAfter.requests, [{ status: 409, code: 'billing_customer_required' }]);
    assert.ok(billingAfter.accountRefreshes >= 1 && billingAfter.teamRefreshes >= 1);
    assert.deepEqual(await fixture.invitationState(), before);
    await fixture.assertNoOutbound();
  }
  const heading = 'Invite to ' + nativeFixtureTeam;
  const selector = node => node.type === 'UISegmentedControl'
    && node.segments?.join('|') === 'Overview|Members|Invitations';
  async function selectSection(index) {
    const target = await ui.reveal(selector);
    await session.command('select', { target: target.path, index });
    return target.windowPath;
  }
  const open = async () => {
    if (inline) {
      const windowPath = await selectSection(2);
      await session.waitFor(hasText('Invitation links', windowPath));
      return windowPath;
    }
    await clickPresented('Invite people');
    const nodes = await session.waitFor(hasText(heading));
    return nodes.find(node => node.text === heading).windowPath;
  };
  const close = async windowPath => {
    if (inline) {
      await selectSection(1);
      await session.waitFor(hasText('Members (1)', windowPath));
      return;
    }
    await clickPresented('Done', windowPath);
    await session.waitFor(nodes => !hasText(heading)(nodes) && nodes.some(node => button('Invite people')(node) && node.hittable));
  };

  step = 'show a temporary list failure and reload the invitation list';
  assert.equal(await fixture.interruptInvitationLoad(), true);
  if (inline) {
    await clickPresented('Refresh members');
    await session.waitFor(hasText(invitationLoadFailure));
    assert.deepEqual(await fixture.invitationState(), { ...before, interruptedLoads: 1 });
    await clickPresented('Refresh members');
    await session.waitFor(hasText('Members (1)'));
  } else {
    const failedSheet = await open();
    await session.waitFor(hasText(invitationLoadFailure, failedSheet));
    assert.deepEqual(await fixture.invitationState(), { ...before, interruptedLoads: 1 });
    await close(failedSheet);
  }

  const sheet = await open();
  const list = await session.waitFor(nodes => ['Member invitation', 'Viewer invitation', 'Expired'].every(text => hasText(text, sheet)(nodes))
    && nodes.filter(button('Revoke', sheet)).length === 1);
  assert.ok(list.some(node => node.windowPath === sheet && node.text?.startsWith('Expires ')));
  assert.ok(list.some(node => button('Create & copy link', sheet)(node) && node.enabled));
  assert.ok(!list.some(button('Copy', sheet)));

  step = 'retry a failed revocation and confirm only the active link changes';
  await ui.activate(node => button('Revoke', sheet)(node) && node.enabled);
  await session.waitFor(hasText(invitationRevokeFailure, sheet));
  assert.deepEqual(await fixture.invitationState(), { ...before, interruptedLoads: 1, revocations: [503] });
  await ui.activate(node => button('Revoke', sheet)(node) && node.enabled);
  await session.waitFor(nodes => hasText('Revoked', sheet)(nodes) && hasText('Expired', sheet)(nodes)
    && !nodes.some(button('Revoke', sheet)));
  const after = await fixture.invitationState();
  assert.deepEqual(after.revocations, [503, 200]);
  assert.ok(after.links[0].revokedAt > 0);
  assert.deepEqual(after.links, [{ ...before.links[0], revokedAt: after.links[0].revokedAt }, before.links[1]]);
  assert.deepEqual(after.members, before.members);

  step = 'reopen the saved invitation list and verify the project is intact';
  await close(sheet);
  const reopened = await open();
  await session.waitFor(nodes => hasText('Revoked', reopened)(nodes) && hasText('Expired', reopened)(nodes)
    && !nodes.some(button('Revoke', reopened)));
  assert.deepEqual(await fixture.invitationState(), after);
  await close(reopened);
  await clickPresented('Done');
  await session.waitFor(nodes => nodes.some(node => node.identifier === 'workspace-project' && node.enabled && node.hittable));
  assert.deepEqual(await session.command('loaded-project'), model);
  assert.deepEqual(await session.command('persisted-projects'), [saved]);
  assert.deepEqual(await session.command('presented-alerts'), []);
  await fixture.assertNoOutbound();
} catch (error) { throw new Error(`Native Team invitations failed during ${step}`, { cause: error }); }
finally {
  try { await session?.close(); }
  finally { await fixture.close(); }
}
