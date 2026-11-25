import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFile, readdir } from 'node:fs/promises';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { promisify } from 'node:util';
import { ScrivSession } from '../../../cli/scriv.mjs';
import { waitForSavedProject } from '../support/saved-projects.mjs';

const groups = ['startup-trace'];
const args = process.argv.slice(2);
if (args.length === 1 && args[0] === '--list-cases') {
  console.log(JSON.stringify({ groups }));
  process.exit(0);
}
assert.ok(args.length === 0 || (args.length === 2 && args[0] === '--group' && groups.includes(args[1])));
const startupTrace = args[1] === 'startup-trace';

const app = process.env.SCRIV_E2E_APP;
assert.ok(app, 'Requires an isolated Catalyst automation bundle');
const provenance = JSON.parse(await readFile(new URL(
  '../../../apps/mac/Sources/ScrivApp/Resources/SampleImages/provenance.json', import.meta.url,
), 'utf8'));
const assetNames = new Map(provenance.images.map(image => [image.sha256, image.file]));

await assert.rejects(ScrivSession.launch(app, { freshStartup: true, persistent: true }), /Invalid session options/);
await assert.rejects(ScrivSession.launch(app, { freshStartup: true, cloudFixtureOrigin: 'http://127.0.0.1:43210' }), /Invalid session options/);
await assert.rejects(ScrivSession.launch(app, { freshStartup: true, codexAnalysisFixtureOrigin: 'ws://127.0.0.1:43210' }), /Invalid session options/);
await assert.rejects(ScrivSession.launch(app, { startupTrace: true }), /Invalid session options/);
await assert.rejects(ScrivSession.launch(app, { freshStartup: true, startupTrace: 'all' }), /Invalid session options/);

async function verifyStartupTrace(pid) {
  assert.ok(Number.isSafeInteger(pid) && pid > 0);
  const log = promisify(execFile);
  const predicate = `processIdentifier == ${pid} AND subsystem == "app.scriv.startup" AND category == "local-startup"`;
  const deadline = Date.now() + 10000;
  const stages = ['sceneEntered', 'storeConstructionBegin', 'storeConstructionEnd', 'windowCreated',
    'windowVisibilityRequested', 'bootstrapEnd', 'heartbeatSecond'];
  do {
    const { stdout } = await log('/usr/bin/log', ['show', '--last', '1m', '--style', 'ndjson', '--predicate', predicate],
      { maxBuffer: 1024 * 1024, timeout: 8000 });
    const events = stdout.split('\n').filter(Boolean).map(line => JSON.parse(line)).filter(row => row.eventMessage).map(({ eventMessage }) => {
      const match = /^stage=(\w+) sequence=(\d+) elapsed_ms=(\d+) error_family=(?:none|cocoa|posix|url|other) error_code=-?\d+ underlying_family=(?:none|cocoa|posix|url|other) underlying_code=-?\d+$/.exec(eventMessage);
      assert.ok(match, 'Startup diagnostics use only the public stage and numeric error fields');
      return { stage: match[1], sequence: Number(match[2]), elapsed: Number(match[3]) };
    }).sort((a, b) => a.sequence - b.sequence);
    if (stages.every(stage => events.some(event => event.stage === stage))) {
      assert.ok(events.length <= 128);
      assert.ok(events.every((event, i) => event.sequence === i + 1 && event.elapsed >= (events[i - 1]?.elapsed ?? 0)));
      const launch = stages.slice(0, 5).map(stage => events.findIndex(event => event.stage === stage));
      assert.ok(launch.every((index, i) => i === 0 || index > launch[i - 1]));
      return;
    }
    await delay(250);
  } while (Date.now() < deadline);
  throw new Error('Fresh startup did not publish its local stage diagnostics');
}

const session = await ScrivSession.launch(app, { freshStartup: true, startupTrace });
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
  if (startupTrace) await verifyStartupTrace(session.pid);
  console.log('PASS: first startup creates and illustrates the local sample project');
} finally {
  await session.close();
}
