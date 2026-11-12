import assert from 'node:assert/strict';
import { editedContent } from './audio-library-fixtures.mjs';
import { settledTrimObservation } from './audio-attachment-steps.mjs';

export const sourceShrinkCases = ['dialogue-import', 'baseline-trim',
  'source-only-shrink-cancel', 'source-only-shrink-apply', 'reopen-shrink-noop', 'browser-reopen'];

// Source-derived acceptance for AudioClipTimingDraft.setSource, not a copied
// domain implementation. The literal 4-second recording and 3-second Source in
// leave a 1-second duration. Never write Duration during the measured action.
export async function runAudioSourceShrinkSteps({ session, ui, run, saved, unchanged, mutation, current }) {
  let baseline = await session.command('loaded-project');
  let packages = await saved();
  assert.deepEqual(baseline.project, current);
  async function pendingUnchanged() {
    assert.deepEqual(await session.command('loaded-project'), baseline,
      'Draft leaves the entire loaded model and every exact Date witness unchanged');
    await unchanged(packages);
  }
  async function open(expected) {
    await ui.openLibrary();
    await ui.openTrim(current.audioClips[0], expected);
    // Reuse the existing bounded read-only sheet-readiness observation.
    // Mutations, mismatched model assertions, and other errors never retry.
    assert.deepEqual(await settledTrimObservation(session), baseline);
    await unchanged(packages);
  }
  async function cancel() {
    await ui.finishTrim(false);
    await unchanged(packages);
    // Library alone is deliberately not a loaded-project observation scope.
    await ui.closeLibrary();
    await pendingUnchanged();
  }
  async function apply(expected) {
    const before = current;
    await ui.finishTrim();
    current = await mutation(before, expected);
    assert.ok(Number.isFinite(current.modifiedAt) && current.modifiedAt >= before.modifiedAt,
      'Saved modification time is nondecreasing; same-tick edits are valid');
    await ui.closeLibrary();
    const after = await session.command('loaded-project');
    assert.deepEqual(after.project, current, 'Loaded and persisted complete models agree after Apply');
    const { modifiedAt: beforeModified, ...beforeOtherDates } = baseline.dateReferenceTimeBits;
    const { modifiedAt: afterModified, ...afterOtherDates } = after.dateReferenceTimeBits;
    assert.deepEqual(afterOtherDates, beforeOtherDates, 'All unrelated exact Date witnesses survive Apply');
    assert.equal(typeof beforeModified, 'string'); assert.equal(typeof afterModified, 'string');
    baseline = after; packages = await saved();
  }
  async function shrinkSourceOnly() {
    await open(['0.500', '2.500', '0.250']);
    await ui.input('audio-source-in', '3.000');
    await ui.fields(['3.000', '1.000', '0.250']);
    const nodes = await session.command('snapshot');
    assert.ok(!nodes.some(node => node.identifier === 'audio-timing-validation'),
      'Automatic valid shrink must not leave an inline validation error');
    await pendingUnchanged();
  }

  await run('baseline-trim', async () => {
    await open(['0.000', '4.000', '0.000']);
    for (const [id, text] of [['audio-source-in', '0.500'], ['audio-duration', '2.500'], ['audio-placement-offset', '0.250']]) {
      await ui.input(id, text); await pendingUnchanged();
    }
    await ui.fields(['0.500', '2.500', '0.250']);
    await apply(editedContent(current, project => {
      Object.assign(project.audioClips[0], { sourceStartMs: 500, durationMs: 2500, startMs: 250 });
    }));
  });
  await run('source-only-shrink-cancel', async () => {
    await shrinkSourceOnly(); await cancel();
  });
  await run('source-only-shrink-apply', async () => {
    // A fresh editor must still show the original duration after Cancel.
    await shrinkSourceOnly();
    await apply(editedContent(current, project => {
      Object.assign(project.audioClips[0], { sourceStartMs: 3000, durationMs: 1000 });
    }));
  });
  await run('reopen-shrink-noop', async () => {
    await open(['3.000', '1.000', '0.250']);
    await ui.finishTrim(); await unchanged(packages);
    await ui.closeLibrary(); await pendingUnchanged();
  });
  return current;
}
