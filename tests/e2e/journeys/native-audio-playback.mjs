import assert from 'node:assert/strict';
import { constants } from 'node:fs';
import { open, realpath } from 'node:fs/promises';
import { join } from 'node:path';
import { ScrivSession } from '../../../cli/scriv.mjs';
import { waitForSavedProject } from '../support/saved-projects.mjs';
import { audioProjectFixture, syntheticFilename, syntheticPCM } from './support/audio-library-fixtures.mjs';
import { audioLibrarySteps } from './support/audio-library-steps.mjs';

assert.ok(process.env.SCRIV_E2E_APP, 'Requires an isolated Catalyst automation bundle');
const session = await ScrivSession.launch(process.env.SCRIV_E2E_APP);
const ui = audioLibrarySteps(session);
const input = audioProjectFixture();
const audio = syntheticPCM({ silence: true });
const timeline = nodes => nodes.find(node => node.identifier === 'scene-playback-position' && node.hittable)?.slider;
const clipStart = 1250;
let step = 'import a silent scene clip into the isolated package';

try {
  assert.equal((await session.command('capabilities')).cloudIsolation.network, 'disabled');
  await ui.tab('Script');
  await session.command('key', { input: 's', modifiers: ['command'] });
  await waitForSavedProject(session, project => project.title === 'YAM MAN');
  assert.deepEqual(await session.command('import-json', { text: JSON.stringify(input) }),
    { dispatched: true, projectChanged: true });
  const initial = await waitForSavedProject(session, project => project.title === input.title);
  await ui.slider('Playback position', clipStart);
  assert.deepEqual(await session.command('import-audio', { base64: audio.toString('base64'), attachment: 'scene' }),
    { dispatched: true, imported: true, cleanupVerified: true });
  const project = await waitForSavedProject(session, item => item.id === initial.id && item.audioClips.length === 1);
  const [clip] = project.audioClips;
  const [asset] = project.audioAssets;
  assert.equal(clip.startMs, clipStart);
  const saved = await session.command('persisted-projects');
  const button = node => node.identifier === 'audio-clip-play-' + clip.id;
  const play = node => button(node) && node.label === 'Play scene from ' + syntheticFilename;
  const pause = node => button(node) && node.label === 'Pause scene playback';

  step = 'reject changed recording bytes before playback and restore the fixture';
  assert.match(project.id, /^[0-9a-f-]{36}$/i);
  assert.match(asset.fileName, /^[0-9a-f]{64}\.wav$/);
  const path = join(session.root, 'Projects', project.id + '.scriv', 'audio', asset.fileName);
  assert.equal(await realpath(path), path, 'Only the owned package audio is eligible');
  const file = await open(path, constants.O_RDWR | constants.O_NOFOLLOW);
  try {
    assert.deepEqual(await file.readFile(), audio);
    const sampleOffset = 44;
    assert.equal((await file.write(Buffer.from([1]), 0, 1, sampleOffset)).bytesWritten, 1);
    try {
      await ui.openLibrary();
      await ui.activate(play);
      await session.waitFor(nodes => nodes.some(pause) && nodes.some(node => node.text?.includes('The local audio failed its integrity check.')));
      await ui.activate(pause);
      await session.waitFor(nodes => nodes.some(play));
    } finally {
      await file.write(audio.subarray(sampleOffset, sampleOffset + 1), 0, 1, sampleOffset);
    }
  } finally {
    await file.close();
  }

  step = 'seek to the repaired clip from its Library card and pause the scene';
  await ui.closeLibrary();
  await ui.slider('Playback position', 300);
  await ui.openLibrary();
  await ui.activate(play);
  await session.waitFor(nodes => nodes.some(pause));
  await ui.activate(pause);
  await session.waitFor(nodes => nodes.some(play));
  await ui.closeLibrary();
  await session.waitFor(nodes => timeline(nodes)?.value >= clipStart && timeline(nodes)?.value < 5000);

  step = 'retry the repaired clip and let the scene clock reach the end';
  await ui.openLibrary();
  await ui.activate(play);
  await session.waitFor(nodes => nodes.some(pause));
  await session.waitFor(nodes => nodes.some(play));
  await ui.closeLibrary();
  await session.waitFor(nodes => timeline(nodes)?.value === 5000);
  assert.deepEqual(await session.command('persisted-projects'), saved);
  assert.deepEqual(await session.command('presented-alerts'), []);
  console.log('PASS: native local audio seek, pause, integrity failure and playback through scene end');
} catch (cause) {
  throw new Error(`Local audio playback failed while trying to ${step}`, { cause });
} finally {
  await session.close();
}
