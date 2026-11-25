import assert from 'node:assert/strict';
import { settledTrimObservation } from './audio-attachment-steps.mjs';
import { editedContent } from './audio-library-fixtures.mjs';
import { wordTimingSteps } from './word-timing.mjs';

export const timingGestureCases = ['scene-import', 'cancel-gesture-draft', 'apply-gesture-draft', 'word-timeline-gestures'];

export async function runTimingGestureSteps({ session, ui, run, saved, unchanged, mutation, current }) {
  const drag = (surface, fromMs, toMs) => session.command('timing-drag', { surface, fromMs, toMs });
  const trimAction = action => session.command('audio-trim-action', { action });
  const tap = (timeMs, region) => session.command('timing-tap', { timeMs, region });
  const applied = { dispatched: true };
  const noHandle = { dispatched: false };

  await ui.openLibrary();
  await run('cancel-gesture-draft', async () => {
    const packages = await saved();
    await ui.openTrim(current.audioClips[0], ['0.000', '4.000', '0.000']);
    assert.deepEqual((await settledTrimObservation(session)).project, current);
    await ui.draft('0.500', '2.500', '0.250');
    assert.deepEqual(await drag('audio-trim', 1700, 2200), noHandle);
    await ui.fields(['0.500', '2.500', '0.250']);
    assert.deepEqual(await drag('audio-trim', 500, 800), applied);
    await ui.fields(['0.800', '2.200', '0.250']);
    assert.deepEqual(await drag('audio-trim', 3000, 3400), applied);
    await ui.fields(['0.800', '2.600', '0.250']);
    assert.deepEqual(await trimAction('Move source in earlier'), applied);
    await ui.fields(['0.700', '2.700', '0.250']);
    assert.deepEqual(await trimAction('Move source out earlier'), applied);
    await ui.fields(['0.700', '2.600', '0.250']);
    assert.deepEqual((await session.command('loaded-project')).project, current);
    await unchanged(packages);
    await ui.finishTrim(false);
    await unchanged(packages);
  });
  await run('apply-gesture-draft', async () => {
    const before = current;
    await ui.openTrim(current.audioClips[0], ['0.000', '4.000', '0.000']);
    assert.deepEqual((await settledTrimObservation(session)).project, before);
    assert.deepEqual(await drag('audio-trim', 0, 500), applied);
    assert.deepEqual(await trimAction('Move source out earlier'), applied);
    await ui.fields(['0.500', '3.400', '0.000']);
    await ui.finishTrim();
    current = await mutation(before, editedContent(before, project => {
      Object.assign(project.audioClips[0], { sourceStartMs: 500, durationMs: 3400 });
    }));
  });
  await ui.closeLibrary();

  const words = wordTimingSteps(session);
  async function wordFields(start, end) {
    await session.waitFor(nodes => nodes.some(node => node.identifier === 'word-timing-start' && node.text === start)
      && nodes.some(node => node.identifier === 'word-timing-end' && node.text === end));
  }
  await run('word-timeline-gestures', async () => {
    const before = current, packages = await saved();
    await words.open();
    assert.deepEqual((await settledTrimObservation(session)).project, before);
    assert.deepEqual(await tap(300, 'track'), applied);
    await wordFields('0.000', '0.600');
    assert.deepEqual(await drag('word-timing', 300, 450), noHandle);
    assert.deepEqual(await drag('word-timing', 600, 900), applied);
    await wordFields('0.000', '0.900');
    assert.deepEqual(await tap(1250, 'ruler'), applied);
    await wordFields('0.000', '0.900');
    assert.deepEqual(await tap(1250, 'track'), applied);
    await wordFields('1.000', '1.600');
    assert.deepEqual(await drag('word-timing', 1000, 1100), applied);
    await wordFields('1.100', '1.600');
    assert.deepEqual((await session.command('loaded-project')).project, before);
    await unchanged(packages);
    await words.button('Save timing');
    await words.closed();
    current = await mutation(before, editedContent(before, project => {
      Object.assign(project.entries[0].words[0], { endMs: 900, timingSource: 'authored' });
      Object.assign(project.entries[0].words[1], { startMs: 1100, timingSource: 'authored' });
    }));
    assert.deepEqual((await session.command('loaded-project')).project, current);
  });
  return current;
}
