import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { ScrivSession } from '../../../cli/scriv.mjs';
import { waitForSavedProject } from '../support/saved-projects.mjs';
import { audioProjectFixture } from './support/audio-library-fixtures.mjs';
import { audioLibrarySteps } from './support/audio-library-steps.mjs';
import { nativeFixtureEmail, startNativeCloudFixture } from './support/native-cloud-fixture.mjs';

assert.ok(process.env.SCRIV_E2E_APP, 'Requires a verified automation-enabled Catalyst app');
const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGP4EGADRAwQCgAsbgXx43oYYAAAAABJRU5ErkJggg==', 'base64');
const digest = createHash('sha256').update(png).digest('hex');
const image = { id: 'owned-cloud-image', version: 1, fileName: digest + '.png', sha256: digest,
  mimeType: 'image/png', byteCount: png.length, characterIds: [], prompt: '', createdAt: 1700000000000 };
const project = audioProjectFixture();
project.title = 'Synthetic hosted picture recovery';
project.images.push(image);
project.cues[0].imageId = image.id;
project.cues[0].label = 'Hosted picture';

const fixture = await startNativeCloudFixture();
let session;
let step = 'prepare hosted project';
try {
  const cloud = await fixture.prepareHostedImage({ project, png: png.toString('base64') });
  session = await ScrivSession.launch(process.env.SCRIV_E2E_APP, { cloudFixtureOrigin: fixture.origin });
  const capabilities = await session.command('capabilities');
  assert.equal(capabilities.cloudIsolation.network, 'loopback-only');
  assert.equal(capabilities.cloudIsolation.peerTransport, 'disabled');
  assert.ok(capabilities.semanticMenuActionScopes.includes('workspace-panels'));
  const ui = audioLibrarySteps(session);
  const button = title => node => node.type === 'UIButton' && (node.title === title || node.label === title);
  async function click(title) {
    const filter = nodes => nodes.filter(node => node.enabled && node.hittable && button(title)(node));
    let prior, stableSince;
    const nodes = await session.waitFor(nodes => {
      const [target, second] = filter(nodes);
      const key = target && !second ? JSON.stringify([target.path, target.frame]) : null;
      if (!key || key !== prior) { prior = key; stableSince = Date.now(); return false; }
      return Date.now() - stableSince >= 1000;
    });
    return session.command('activate', { target: filter(nodes)[0].path });
  }

  step = 'sign in and open the owned Team project';
  await ui.activate(node => node.identifier === 'workspace-project');
  await click('Sign in to Scriv…');
  const emailField = node => node.type === 'UITextField' && node.label === 'Email address';
  const fields = await session.waitFor(nodes => nodes.some(emailField));
  const email = fields.find(emailField);
  await session.command('text', { target: email.path, text: nativeFixtureEmail });
  await click('Continue with email');
  await session.waitFor(nodes => nodes.some(node => node.text === 'Check your email'));
  assert.deepEqual(await session.deliverFixtureEmailCode(await fixture.takeCode()), { delivered: true });
  await click('Sign in with code');
  await click('Team projects');
  await session.waitFor(nodes => nodes.some(node => node.text === project.title + ' · Cloud project'));
  await click('Open project');
  const replica = await waitForSavedProject(session, candidate => candidate.cloudProjectId === cloud.projectID && candidate.revision > 0);
  assert.match(replica.id, /^[a-f0-9-]{36}$/i);
  assert.deepEqual(replica.images, project.images);
  assert.deepEqual(replica.scenes, project.scenes);
  assert.deepEqual(replica.entries, project.entries);
  assert.equal(replica.cues.find(cue => cue.id === 'image1')?.imageId, image.id);
  const path = join(session.root, 'Projects', replica.id + '.scriv', 'assets', image.fileName);

  step = 'reject invalid hosted bytes and keep the script intact';
  await ui.tab('Script');
  await session.waitFor(nodes => nodes.some(node => node.text === 'Hosted picture · Version 1')
    && nodes.some(node => node.text === 'Image isn’t on this Mac'));
  const actions = await ui.reveal(node => node.label === 'Workspace actions');
  assert.deepEqual(await session.command('menu-action', { target: actions.path, scope: 'workspace-panels', action: 'Scriv account…' }),
    { dispatched: true, coverage: 'semantic-menu-action' });
  await session.waitFor(nodes => nodes.some(node => node.text?.startsWith('No hosted image or other authorized Mac is available.')));
  assert.deepEqual(await fixture.hostedImageResponses(), [200]);
  await assert.rejects(readFile(path), { code: 'ENOENT' });
  await session.command('key', { input: 'Escape', modifiers: [] });
  await session.waitFor(nodes => nodes.some(node => button('Fetch image')(node) && node.hittable)
    && !nodes.some(node => node.text?.startsWith('No hosted image or other authorized Mac is available.')));
  assert.deepEqual((await session.command('loaded-project')).project, replica);

  step = 'fetch the repaired image using the Preview control';
  await fixture.repairHostedImage();
  assert.deepEqual(await fixture.hostedImageResponses(), [200]);
  await click('Fetch image');
  await session.waitFor(nodes => nodes.some(node => node.identifier === 'preview-picture' && node.hittable)
    && !nodes.some(node => node.text === 'Image isn’t on this Mac'));
  assert.deepEqual(await fixture.hostedImageResponses(), [200, 200]);
  assert.deepEqual(await readFile(path), png, 'The verified original image reached the native replica');
  assert.deepEqual((await session.command('loaded-project')).project, replica);
  assert.deepEqual((await session.command('persisted-projects')).find(candidate => candidate.id === replica.id), replica);
  assert.deepEqual(await session.command('presented-alerts'), []);
  await fixture.assertNoOutbound();
  console.log('PASS: native Team project preserves its script when hosted bytes are corrupt and fetches the repaired image');
} catch (error) { throw new Error(`Native cloud image recovery failed during ${step}`, { cause: error }); }
finally {
  try { await session?.close(); }
  finally { await fixture.close(); }
}
