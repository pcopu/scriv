import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile, readdir } from 'node:fs/promises';
import { join } from 'node:path';
import { ScrivSession } from '../../../cli/scriv.mjs';
import { waitForSavedProject } from '../support/saved-projects.mjs';

const app = process.env.SCRIV_E2E_APP;
assert.ok(app, 'Requires an isolated Catalyst automation bundle');
const provenance = JSON.parse(await readFile(new URL(
  '../../../apps/mac/Sources/ScrivApp/Resources/SampleImages/provenance.json', import.meta.url,
), 'utf8'));
const assetNames = new Map(provenance.images.map(image => [image.sha256, image.file]));

await assert.rejects(ScrivSession.launch(app, { freshStartup: true, persistent: true }), /Invalid session options/);
await assert.rejects(ScrivSession.launch(app, { freshStartup: true, cloudFixtureOrigin: 'http://127.0.0.1:43210' }), /Invalid session options/);
await assert.rejects(ScrivSession.launch(app, { freshStartup: true, codexAnalysisFixtureOrigin: 'ws://127.0.0.1:43210' }), /Invalid session options/);

const session = await ScrivSession.launch(app, { freshStartup: true });
try {
  const capabilities = await session.command('capabilities');
  assert.deepEqual(capabilities.workspace, { persistent: false, resumed: false, freshStartup: true, bootstrapping: false });
  assert.deepEqual(capabilities.cloudIsolation, {
    credentials: 'process-memory', outbox: 'private-run-root', network: 'disabled', oauth: 'disabled', peerTransport: 'disabled',
  });
  const readyTabs = nodes => nodes.find(node => node.identifier === 'workspace-tabs' && node.enabled && node.hittable);
  const tabs = readyTabs(await session.waitFor(readyTabs));
  const sample = await waitForSavedProject(session, project => project.title === 'YAM MAN' && project.images?.length === 3);
  assert.match(sample.id, /^[a-f0-9-]{36}$/i);
  assert.equal(sample.revision, 1);
  assert.ok(!sample.cloudProjectId);
  assert.deepEqual(await session.command('persisted-projects'), [sample]);
  assert.deepEqual((await session.command('loaded-project')).project, sample);

  const packageName = sample.id + '.scriv';
  const projects = join(session.root, 'Projects');
  const assets = join(projects, packageName, 'assets');
  assert.deepEqual(await readdir(projects), [packageName]);
  assert.deepEqual((await readdir(assets)).sort(), [...assetNames.keys()].map(hash => hash + '.jpg').sort());
  assert.deepEqual(sample.images.map(image => image.sha256).sort(), [...assetNames.keys()].sort());
  const namesByID = new Map();
  for (const image of sample.images) {
    assert.equal(image.fileName, image.sha256 + '.jpg');
    assert.equal(image.mimeType, 'image/jpeg');
    const bytes = await readFile(join(assets, image.fileName));
    assert.equal(bytes.length, image.byteCount);
    assert.equal(createHash('sha256').update(bytes).digest('hex'), image.sha256);
    namesByID.set(image.id, assetNames.get(image.sha256));
  }
  assert.deepEqual(Object.fromEntries(sample.characters.map(character => [character.id, namesByID.get(character.portraitImageId)])), {
    'character-randy': 'farm-wide.jpg', 'character-franklin': 'franklin.jpg', 'character-miyazaki': 'miyazaki.jpg',
  });
  assert.equal(sample.cues.length, 19);
  for (const cue of sample.cues) {
    const expected = ['08B', '09A', '10A', '12A'].includes(cue.label) ? 'franklin.jpg'
      : cue.label === '10B' ? 'miyazaki.jpg' : 'farm-wide.jpg';
    assert.equal(namesByID.get(cue.imageId), expected, cue.label);
  }
  const storyboard = tabs.segments.indexOf('Storyboard');
  assert.ok(storyboard >= 0);
  await session.command('select', { target: tabs.identifier, index: storyboard });
  await session.waitFor(nodes => readyTabs(nodes)?.selected === storyboard
    && nodes.some(node => /Label/.test(node.type) && node.text?.startsWith('19 images · ')));
  assert.deepEqual(await session.command('presented-alerts'), []);
  console.log('PASS: first startup creates and illustrates the local sample project');
} finally {
  await session.close();
}
