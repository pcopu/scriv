import assert from 'node:assert/strict';
import { ScrivSession } from '../../../cli/scriv.mjs';
import { audioLibrarySteps } from './support/audio-library-steps.mjs';
import { startCodexFixture } from './support/codex-loopback-fixture.mjs';

assert.ok(process.env.SCRIV_E2E_APP, 'Requires an isolated Catalyst automation bundle');
const session = await ScrivSession.launch(process.env.SCRIV_E2E_APP);
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

try {
  const capabilities = await session.command('capabilities');
  assert.equal(capabilities.cloudIsolation.network, 'disabled');
  const projects = await session.command('persisted-projects');
  fixture = await startCodexFixture(session.root, [], { manualAccountCheck: true });
  const ui = audioLibrarySteps(session);

  await fixture.race((async () => {
    await session.waitFor(nodes => nodes.some(byID('workspace-tabs')));
    await session.command('key', { input: ',', modifiers: ['command'] });
    const settingsCell = node => node.identifier === 'scriv.settings.codex' && node.hittable;
    const settings = await session.waitFor(nodes => nodes.filter(settingsCell).length === 1);
    await session.command('activate', { target: settings.find(settingsCell).path });
    await session.waitFor(nodes => connection(nodes) === 'Not connected');

    step = 'connect to the account-required provider';
    const field = await ui.reveal(node => node.type === 'UITextField' && node.label === 'Saved loopback server address');
    await session.command('text', { target: field.path, text: fixture.endpoint });
    await session.command('end-editing');
    await ui.activate(byID('codex-connect'));
    await session.waitFor(needsSignIn);

    step = 'reject an unsafe sign-in response before opening a browser';
    await ui.activate(signIn);
    await session.waitFor(nodes => needsSignIn(nodes) && error(nodes) === 'Codex did not return a valid sign-in URL.');

    step = 'refresh the account and model list from the same connection';
    await ui.activate(refresh);
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
  console.log('PASS: native Codex sign-in response validation and explicit account refresh');
} catch (cause) {
  throw new Error(`Codex account check failed while trying to ${step}`, { cause });
} finally {
  try { if (fixture) await fixture.close().catch(() => {}); }
  finally { await session.close(); }
}
