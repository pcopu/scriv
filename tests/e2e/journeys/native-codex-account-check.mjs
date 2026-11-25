import assert from 'node:assert/strict';
import { ScrivSession } from '../../../cli/scriv.mjs';
import { observePresentedAlert } from '../support/presented-error.mjs';
import { audioLibrarySteps } from './support/audio-library-steps.mjs';
import { startCodexFixture } from './support/codex-loopback-fixture.mjs';

const groups = ['signed-in-account-menu'];
const args = process.argv.slice(2);
if (args.length === 1 && args[0] === '--list-cases') {
  console.log(JSON.stringify({ groups }));
  process.exit(0);
}
assert.ok(args.length === 0 || args.length === 2 && args[0] === '--group' && groups.includes(args[1]));
assert.ok(process.env.SCRIV_E2E_APP, 'Requires an isolated Catalyst automation bundle');
const session = await ScrivSession.launch(process.env.SCRIV_E2E_APP);
const ui = audioLibrarySteps(session);
const byID = id => node => node.identifier === id;
const statusText = (nodes, id) => nodes.find(byID(id))?.text;
const connection = nodes => statusText(nodes, 'codex-connection-status');
const error = nodes => statusText(nodes, 'codex-setup-error');
const signIn = byID('codex-account');
const refresh = byID('codex-refresh-account');
const needsSignIn = nodes => connection(nodes) === 'Connected · sign-in needed'
  && statusText(nodes, 'codex-account-status') === 'Not signed in'
  && nodes.some(node => signIn(node) && node.label === 'Sign in with ChatGPT' && node.enabled)
  && nodes.some(node => refresh(node) && node.enabled);
let fixture;
let step = 'open Codex Settings in the isolated app';

async function connect(endpoint) {
  const field = await ui.reveal(node => node.type === 'UITextField' && node.label === 'Saved loopback server address');
  await session.command('text', { target: field.path, text: endpoint });
  await session.command('end-editing');
  await ui.activate(byID('codex-connect'));
}

async function verifyAccountConnections(projects) {
  fixture = await startCodexFixture(session.root, [], { manualAccountCheck: true });

  await fixture.race((async () => {
    step = 'connect to the account-required provider';
    await connect(fixture.endpoint);
    await session.waitFor(needsSignIn);

    step = 'reject an unsafe sign-in response before opening a browser';
    await ui.activate(signIn);
    await session.waitFor(nodes => needsSignIn(nodes) && error(nodes) === 'Codex did not return a valid sign-in URL.');

    step = 'refresh the account and model list from the same connection';
    await ui.activate(refresh);
    await session.waitFor(nodes => needsSignIn(nodes) && !error(nodes));

    step = 'show a declined sign-in that completed before the reply';
    await ui.activate(signIn);
    await session.waitFor(nodes => needsSignIn(nodes) && error(nodes) === 'Synthetic sign-in was declined');

    step = 'refresh the signed-in account and its models after early completion';
    await ui.activate(signIn);
    await session.waitFor(nodes => connection(nodes) === 'Connected'
      && statusText(nodes, 'codex-account-status') === 'signed-in-fixture@example.invalid'
      && nodes.some(node => node.identifier === 'codex-model' && node.label === 'Model: scriv-fixture-after-login')
      && !error(nodes));

    step = 'coalesce overlapping provider notices and discard a superseded read error';
    await fixture.notify('account-update');
    await session.waitFor(nodes => needsSignIn(nodes) && !error(nodes));

    step = 'disconnect when the next explicit refresh fails';
    await ui.activate(refresh);
    await session.waitFor(nodes => connection(nodes) === 'Codex needs attention'
      && error(nodes) === 'Synthetic account refresh failed'
      && nodes.every(node => !refresh(node))
      && nodes.some(node => node.identifier === 'codex-check' && node.label === 'Try again' && node.enabled));
    fixture.assertNoTurns();
    assert.deepEqual((await session.command('image-evidence')).jobs, []);
    assert.deepEqual(await session.command('persisted-projects'), projects);
  })());

  await fixture.close();
  fixture = undefined;

  step = 'cancel a pending account refresh and close its transport';
  fixture = await startCodexFixture(session.root, [], { holdAccountRefresh: true });
  await fixture.race((async () => {
    await connect(fixture.endpoint);
    await session.waitFor(needsSignIn);
    await ui.activate(refresh);
    const cancel = byID('codex-cancel-check');
    await session.waitFor(nodes => connection(nodes) === 'Checking local connection…' && nodes.some(cancel));
    const { disconnected } = await fixture.waitForHeldAccountRefresh();
    await Promise.all([disconnected, ui.activate(cancel)]);
    await session.waitFor(nodes => connection(nodes) === 'Check cancelled' && !error(nodes)
      && nodes.every(node => !refresh(node)));
    fixture.assertNoTurns();
  })());
  await fixture.close();
  fixture = undefined;

  step = 'reconnect with a fresh account state after cancellation';
  fixture = await startCodexFixture(session.root, []);
  await fixture.race((async () => {
    await connect(fixture.endpoint);
    await session.waitFor(nodes => connection(nodes) === 'Connected'
      && statusText(nodes, 'codex-account-status') === 'Not required by this provider'
      && nodes.some(node => node.identifier === 'codex-model' && node.label === 'Model: scriv-fixture')
      && !error(nodes));
    step = 'disconnect cleanly from the reconnected provider';
    await ui.activate(byID('codex-stop'));
    await session.waitFor(nodes => connection(nodes) === 'Not connected' && !nodes.some(byID('codex-model')));
    fixture.assertNoTurns();
    assert.deepEqual((await session.command('image-evidence')).jobs, []);
    assert.deepEqual(await session.command('persisted-projects'), projects);
  })());
  await fixture.close();
  fixture = undefined;
  console.log('PASS: native Codex refresh, cancellation and connection recovery');
}

async function verifySignedInAccountMenu(projects) {
  step = 'open the signed-in account menu using the real Codex Account control';
  const email = 'signed-in-fixture@example.invalid';
  fixture = await startCodexFixture(session.root, [], { signedInAccount: true });
  await fixture.race((async () => {
    await connect(fixture.endpoint);
    await session.waitFor(nodes => connection(nodes) === 'Connected' && statusText(nodes, 'codex-account-status') === email);
    await ui.activate(signIn);
    await observePresentedAlert(session, { title: 'ChatGPT on this Mac', message: email, actions: [
      { title: 'Refresh account', enabled: true, style: 'default' },
      { title: 'Sign out of ChatGPT', enabled: true, style: 'destructive' },
      { title: 'Cancel', enabled: true, style: 'cancel' },
    ] });
    fixture.assertNoTurns();
    assert.deepEqual(await session.command('persisted-projects'), projects);
  })());
  await fixture.close();
  fixture = undefined;
  console.log('PASS: native signed-in Codex Account control offers refresh, sign out and cancel');
}

try {
  const capabilities = await session.command('capabilities');
  assert.equal(capabilities.cloudIsolation.network, 'disabled');
  const projects = await session.command('persisted-projects');
  await session.waitFor(nodes => nodes.some(byID('workspace-tabs')));
  await session.command('key', { input: ',', modifiers: ['command'] });
  const settingsCell = node => node.identifier === 'scriv.settings.codex' && node.hittable;
  const settings = await session.waitFor(nodes => nodes.filter(settingsCell).length === 1);
  await session.command('activate', { target: settings.find(settingsCell).path });
  await session.waitFor(nodes => connection(nodes) === 'Not connected');
  if (args[1] === 'signed-in-account-menu') await verifySignedInAccountMenu(projects);
  else await verifyAccountConnections(projects);
} catch (cause) {
  throw new Error(`Codex account check failed while trying to ${step}`, { cause });
} finally {
  try { if (fixture) await fixture.close().catch(() => {}); }
  finally { await session.close(); }
}
