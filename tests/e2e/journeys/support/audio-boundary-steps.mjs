import assert from 'node:assert/strict';
import { editedContent, syntheticFilename } from './audio-library-fixtures.mjs';

export const audioBoundaryCases = ['dialogue-import', 'reject-submillisecond-duration',
  'reject-offset-above-maximum', 'accept-rounded-final-millisecond-at-maximum-offset',
  'outside-scene-library', 'restore-in-scene-placement', 'clip-volume-zero',
  'clip-volume-one', 'browser-reopen'];

export async function runAudioBoundarySteps({ session, ui, run, saved, unchanged, mutation, current }) {
  await ui.openLibrary();
  await ui.openTrim(current.audioClips[0], ['0.000', '4.000', '0.000']);
  const initial = await saved();
  for (const test of [
    { name: 'reject-submillisecond-duration', duration: '0.00049', offset: '0.000' },
    { name: 'reject-offset-above-maximum', duration: '0.0005', offset: '86400.001' },
  ]) {
    await run(test.name, async () => {
      await ui.draft('3.999', test.duration, test.offset);
      await ui.activate(node => node.identifier === 'audio-apply');
      await session.waitFor(nodes => nodes.some(node => node.identifier === 'audio-timing-validation')
        && nodes.some(node => node.text === 'Your changes are still in this editor. Nothing was applied from this draft.'));
      await ui.fields(['3.999', test.duration, test.offset]);
      await unchanged(initial);
    });
  }
  await run('accept-rounded-final-millisecond-at-maximum-offset', async () => {
    const before = current;
    await ui.draft('3.999', '0.0005', '86400.000');
    await session.waitFor(nodes => nodes.some(node => node.text?.includes('This starts after the scene ends. Move it earlier or extend the scene to hear it.')));
    await ui.finishTrim();
    current = await mutation(before, editedContent(before, project => {
      Object.assign(project.audioClips[0], { sourceStartMs: 3999, durationMs: 1, startMs: 86400000 });
    }));
    await ui.closeLibrary();
    assert.deepEqual((await session.command('loaded-project')).project, current);
    await ui.openLibrary();
  });
  await run('outside-scene-library', async () => {
    const before = await saved();
    const nodes = await session.waitFor(nodes => nodes.some(node => node.identifier === 'audio-clip-play-' + current.audioClips[0].id && node.enabled === false)
      && nodes.some(node => node.text === 'Outside scene')
      && nodes.some(node => node.text === 'This placement is outside the scene’s current duration. Adjust timing to hear it.'));
    assert.equal(nodes.filter(node => node.identifier === 'audio-clip-play-' + current.audioClips[0].id).length, 1);
    await unchanged(before);
  });
  await run('restore-in-scene-placement', async () => {
    const before = current;
    await ui.openTrim(current.audioClips[0], ['3.999', '0.001', '86400.000']);
    await ui.input('audio-placement-offset', '0.000');
    await ui.finishTrim();
    current = await mutation(before, editedContent(before, project => { project.audioClips[0].startMs = 0; }));
    await session.waitFor(nodes => nodes.some(node => node.identifier === 'audio-clip-play-' + current.audioClips[0].id && node.enabled === true));
  });
  for (const value of [0, 1]) {
    await run(value === 0 ? 'clip-volume-zero' : 'clip-volume-one', async () => {
      const before = current;
      await ui.slider('Clip volume for ' + syntheticFilename, value);
      current = await mutation(before, editedContent(before, project => { project.audioClips[0].volume = value; }));
      assert.equal(current.audioClips[0].isMuted, false, 'A zero volume preserves the independent mute flag');
    });
  }
  await ui.closeLibrary();
  return current;
}
