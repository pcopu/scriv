import assert from 'node:assert/strict';
import { fixture, wordTimingSteps } from './word-timing.mjs';
import { ready } from './line-duration-steps.mjs';

export const boundaryKey = 'line-boundaries';
export function boundaryFixture() {
  const value = fixture();
  value.id = 'word-timing-line-boundaries';
  value.title = 'Word timing line boundaries';
  value.entries.push({ id: 'following', sceneId: 's', order: 1, kind: 'dialogue',
    text: 'next line', ownedDurationMs: 1000, coverageDurationMs: 0, color: 'purple',
    words: [{ id: 'next-1', text: 'next', startMs: 0, endMs: 500 },
      { id: 'next-2', text: 'line', startMs: 500, endMs: 1000 }] });
  value.cues.push({ id: 'following-cue', sceneId: 's', label: '', startMs: 3000, endMs: 4000, prompt: '' });
  return value;
}
export function boundaryExpected(before) {
  const value = structuredClone(before);
  value.entries[0].words = [
    { id: 'w1', text: 'one', startMs: 0, endMs: 1000, timingSource: 'authored' },
    { id: 'w2', text: 'two', startMs: 1000, endMs: 1600 },
    { id: 'w3', text: 'three', startMs: 1600, endMs: 3000, timingSource: 'authored' },
  ];
  delete value.revision; delete value.modifiedAt;
  return value;
}
export function boundaryAudit() {
  const input = boundaryFixture(), output = boundaryExpected(input);
  assert.deepEqual(input.entries.map(entry => entry.ownedDurationMs), [3000, 1000]);
  assert.deepEqual(output.entries[0].words.map(word => [word.id, word.startMs, word.endMs]),
    [['w1', 0, 1000], ['w2', 1000, 1600], ['w3', 1600, 3000]]);
  assert.deepEqual(output.entries[1], input.entries[1]);
  assert.deepEqual(output.cues, input.cues);
  return { journey: 'AUT-J15', portion: boundaryKey, status: 'prepared-native-unverified', nativeVerified: false,
    route: 'Existing embedded Layers word secondary UIAction, word chips, timing fields and Save timing',
    assertions: ['negative start, zero length and end beyond owning line refused without saved/loaded byte changes',
      'first/last words meet literal 0 and 3000 ms line bounds and untouched middle word',
      'adjacent entry, cue cuts, IDs and full model preserved with one revision', 'different-document reopen'],
    deferred: ['singular setter', 'split/merge/distribution', 'ProjectEditing', 'stale snapshots', 'hardware input'], fixture: input };
}
export async function runBoundaryCase(session) {
  const ui = wordTimingSteps(session), startup = await ui.initialize(), input = boundaryFixture();
  assert.deepEqual(await session.command('import-json', { text: JSON.stringify(input) }), { dispatched: true, projectChanged: true });
  const before = await ui.saved(project => project.title === input.title && project.id !== startup.id);
  assert.notEqual(before.id, input.id); assert.equal(before.revision, 0);
  const actual = structuredClone(before), authored = structuredClone(input);
  for (const key of ['id', 'createdAt', 'modifiedAt']) { delete actual[key]; delete authored[key]; }
  assert.deepEqual(actual, authored);
  assert.deepEqual((await ui.loaded()).project, before);
  await ui.othersUnchanged(startup, before.id);
  const packages = await ui.packages(), loaded = await ui.loaded();
  const serialized = { packages: JSON.stringify(packages), loaded: JSON.stringify(loaded) };
  async function unchanged() {
    // Existing v43 sheet readiness can briefly reject this read. Retry only that
    // exact observer rejection. Never repeat mutations or assertion mismatches.
    const deadline = Date.now() + 3000;
    for (;;) {
      try {
        const current = await ui.loaded();
        assert.equal(JSON.stringify(current), serialized.loaded);
        assert.equal(JSON.stringify(await ui.packages()), serialized.packages);
        assert.deepEqual(await session.command('presented-alerts'), []);
        return;
      } catch (error) {
        if (error.message !== 'loaded-project: Synthetic loaded-project observation is unavailable or invalid.' || Date.now() >= deadline) throw error;
        await new Promise(resolve => setTimeout(resolve, 50));
      }
    }
  }
  async function select(id, start, end) {
    const nodes = await session.waitFor(nodes => nodes.filter(node => node.identifier === `word-timing-chip-${id}` && ready(node)).length === 1);
    const chip = nodes.find(node => node.identifier === `word-timing-chip-${id}`);
    assert.deepEqual(await session.command('activate', { target: chip.path }), { dispatched: true });
    for (const [which, text] of [['start', start], ['end', end]]) {
      await session.waitFor(nodes => nodes.some(node => node.identifier === `word-timing-${which}` && node.text === text && ready(node)));
    }
  }
  await ui.open();
  await select('w1', '0.000', '0.600');
  for (const [start, end] of [['-0.001', '0.600'], ['0.600', '0.600']]) {
    await ui.input('start', start); await ui.input('end', end); await ui.button('Save timing');
    await session.waitFor(nodes => nodes.some(node => node.text === 'Enter a start and end for “one” within this dialogue, with end after start. Times are in seconds.'));
    await unchanged();
  }
  await ui.input('start', '0.000'); await ui.input('end', '1.000');
  await select('w3', '2.200', '2.800');
  await ui.input('end', '3.001'); await ui.button('Save timing');
  await session.waitFor(nodes => nodes.some(node => node.text === 'Enter a start and end for “three” within this dialogue, with end after start. Times are in seconds.'));
  await unchanged();
  await ui.input('start', '1.600'); await ui.input('end', '3.000');
  await unchanged(); await ui.button('Save timing'); await ui.closed();
  const after = await ui.savedAfter(before, boundaryExpected(before), startup);
  assert.deepEqual(after.entries[1], before.entries[1]); assert.deepEqual(after.cues, before.cues);
  assert.deepEqual(after.entries.map(entry => entry.ownedDurationMs), [3000, 1000]);
  assert.deepEqual(after.entries[0].words.map(word => word.id), ['w1', 'w2', 'w3']);
  await ui.runtimeAndStarts(after, { runtimeMs: 4000, starts: { following: 3000 } });
  await ui.reopen(after, startup);
  const finalPackages = await ui.packages(), finalLoaded = await ui.loaded();
  await ui.open(); await select('w1', '0.000', '1.000'); await select('w3', '1.600', '3.000');
  await ui.button('Cancel'); await ui.closed(); await ui.unchanged(finalPackages, finalLoaded);
}
