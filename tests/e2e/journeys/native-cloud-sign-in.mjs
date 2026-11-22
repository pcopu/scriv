import assert from 'node:assert/strict';
import { ScrivSession } from '../../../cli/scriv.mjs';
import { waitForSavedProject } from '../support/saved-projects.mjs';
import { nativeFixtureEmail, startNativeCloudFixture } from './support/native-cloud-fixture.mjs';

assert.ok(process.env.SCRIV_E2E_APP, 'Requires a verified automation-enabled Catalyst app');
const app = process.env.SCRIV_E2E_APP;
const fixture = await startNativeCloudFixture();

async function exerciseSignIn(session, allowed) {
  const isolation = (await session.command('capabilities')).cloudIsolation;
  assert.deepEqual(isolation, { credentials: 'process-memory', outbox: 'private-run-root',
    network: allowed ? 'loopback-only' : 'disabled', oauth: 'disabled', peerTransport: 'disabled' });
  await session.waitFor(nodes => nodes.some(node => node.identifier === 'workspace-tabs' && node.enabled && node.hittable));
  await session.command('key', { input: 's', modifiers: ['command'] });
  const saved = await waitForSavedProject(session, project => project.title === 'YAM MAN');
  const loaded = await session.command('loaded-project');
  assert.deepEqual(loaded.project, saved);

  const button = title => node => node.type === 'UIButton' && (node.title === title || node.label === title);
  async function control(predicate, settle = false) {
    const matches = nodes => nodes.filter(node => node.hittable && node.enabled && predicate(node));
    let previous = '', stableSince = 0;
    const nodes = await session.waitFor(nodes => {
      const found = matches(nodes);
      if (!settle) return found.length === 1;
      // UIKit can report a modal control as hittable during its presentation.
      const key = found.length === 1 ? JSON.stringify([found[0].path, found[0].frame]) : '';
      if (!key || key !== previous) {
        previous = key;
        stableSince = Date.now();
        return false;
      }
      return Date.now() - stableSince >= 1000;
    });
    return matches(nodes)[0];
  }
  const click = async (title, settle) => session.command('activate', { target: (await control(button(title), settle)).path });
  await session.command('activate', { target: (await control(node => node.identifier === 'workspace-project')).path });
  await click('Sign in to Scriv…', true);
  const field = await control(node => node.type === 'UITextField' && node.label === 'Email address', true);
  await session.command('text', { target: field.path, text: nativeFixtureEmail });
  await click('Continue with email');
  if (allowed) {
    await session.waitFor(nodes => nodes.some(node => node.text === 'Check your email'));
    assert.equal(await fixture.deliveries(), 1, 'The real Worker delivered one message to the private synthetic mailbox');
    await click('Cancel sign-in');
  } else {
    await session.waitFor(nodes => nodes.some(node => node.text === 'Isolated CLI cloud access is unavailable.'));
    assert.equal(await fixture.deliveries(), 0, 'The default launch never contacts the fixture');
    await click('Keep writing locally');
  }
  await session.waitFor(nodes => nodes.some(node => node.placeholder === 'Find a project' && node.hittable));
  await click('Close Projects', true);
  await session.waitFor(nodes => nodes.some(node => node.identifier === 'workspace-project' && node.enabled && node.hittable));
  assert.deepEqual(await session.command('presented-alerts'), []);
  assert.deepEqual(await session.command('loaded-project'), loaded);
  assert.deepEqual(await session.command('persisted-projects'), [saved]);
}

try {
  for (const cloudFixtureOrigin of ['https://127.0.0.1:8765', 'http://localhost:8765', `${fixture.origin}/path`,
    'http://127.0.0.1:65536', 'http://127.0.0.1:0', `${fixture.origin}\n`]) {
    await assert.rejects(ScrivSession.launch(app, { cloudFixtureOrigin }), /Invalid session options/);
  }
  await assert.rejects(ScrivSession.launch(app, { persistent: true, cloudFixtureOrigin: fixture.origin }), /Invalid session options/);
  let session = await ScrivSession.launch(app);
  try { await exerciseSignIn(session, false); }
  finally { await session.close(); }
  session = await ScrivSession.launch(app, { cloudFixtureOrigin: fixture.origin });
  try { await exerciseSignIn(session, true); }
  finally { await session.close(); }
  await fixture.assertNoOutbound();
  console.log('PASS: native email sign-in stays offline by default and requests one code from the owned Worker fixture');
} finally { await fixture.close(); }
