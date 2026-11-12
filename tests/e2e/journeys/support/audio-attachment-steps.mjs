import assert from 'node:assert/strict';
import { editedContent } from './audio-library-fixtures.mjs';

export const attachmentClamp = 'Moved to the start of this line; negative offsets are not supported.';
export const attachmentOffsetError = 'Enter a valid placement offset before changing which line this clip follows.';
export const attachmentCases = [
  'dialogue-import', 'baseline-trim', 'library-only-observation-rejected',
  'attachment-guard-rejections', 'nan-offset-attachment', 'cancel-invalid-attachment',
  'scene-time-preserves-250', 'line2-clamps-to-3000', 'scene-time-preserves-3000',
  'cancel-attachment', 'repeat-and-apply-scene-time', 'reopen-attachment-noop', 'browser-reopen',
];
export const directionAttachmentCases = [
  'dialogue-import', 'baseline-trim', 'direction-choice-cancel',
  'direction-choice-apply', 'reopen-attachment-noop', 'browser-reopen',
];

// Poll this read-only observation only while UIKit finishes presenting a sheet.
// Dispatch and every other mutation are issued once, never retried.
export async function settledTrimObservation(session) {
  const deadline = Date.now() + 5000;
  let lastError;
  do {
    try { return await session.command('loaded-project'); }
    catch (error) {
      if (error.message !== 'loaded-project: Synthetic loaded-project observation is unavailable or invalid.') throw error;
      lastError = error;
    }
    await new Promise(resolve => setTimeout(resolve, 50));
  } while (Date.now() < deadline);
  throw new Error('Exact audio library/editor observation chain did not settle; no guard is bypassed', { cause: lastError });
}

export async function runAudioAttachmentSteps({ session, ui, run, saved, unchanged, mutation, current, direction = false }) {
  const secondTitle = direction ? 'Direction · four' : 'Dialogue · four';
  const titles = ['Scene time', 'Dialogue · one two three', secondTitle];
  let baseline = await session.command('loaded-project');
  let packages = await saved();
  assert.deepEqual(baseline.project, current);

  async function initialTrimUnchanged() {
    assert.deepEqual(await settledTrimObservation(session), baseline,
      'The newly presented exact audio editor chain settles with an unchanged loaded model');
    await unchanged(packages);
  }
  async function pendingUnchanged() {
    assert.deepEqual(await session.command('loaded-project'), baseline,
      'Pending draft retains the entire loaded Swift model and exact Date-bit witnesses');
    await unchanged(packages);
  }
  async function outsideUnchanged() {
    assert.deepEqual(await session.command('loaded-project'), baseline);
    await unchanged(packages);
  }
  async function captureBaseline() {
    baseline = await session.command('loaded-project'); packages = await saved();
    assert.deepEqual(baseline.project, current);
  }
  async function openOriginal() {
    await ui.openLibrary();
    await ui.openTrim(current.audioClips[0], ['0.500', '2.500', '0.250']);
    await initialTrimUnchanged();
    await menuState(1, '0.250', false);
  }
  async function menuState(selected, offset, clamped, { invalid = false } = {}) {
    await ui.fields(['0.500', '2.500', offset]);
    const menu = await session.command('menu', { target: 'audio-anchor' });
    assert.deepEqual(menu, { primary: [{ type: 'menu', title: '', children: titles.map((title, index) =>
      ({ type: 'action', title, disabled: false, hidden: false, state: index === selected ? 'on' : 'off' })) }],
    secondary: [], context: [] }, 'Every ordered stored action and selected state matches the actual draft');
    const nodes = await session.waitFor(nodes => nodes.some(node => node.identifier === 'audio-anchor'
      && node.title === titles[selected]) && nodes.some(node => node.identifier === 'audio-placement-offset'
      && node.text === offset && node.label === (selected === 0 ? 'Scene start, seconds' : 'Offset from line, seconds')));
    assert.equal(nodes.filter(node => node.text === attachmentClamp).length, clamped ? 1 : 0,
      'The exact clamp explanation is visible only for the clamping action');
    const errors = nodes.filter(node => node.identifier === 'audio-timing-validation');
    assert.equal(errors.length, invalid ? 1 : 0, 'No inline error is ignored');
    if (invalid) {
      assert.equal(nodes.filter(node => node.text === attachmentOffsetError).length, 1);
      assert.ok(nodes.some(node => node.text === 'Your changes are still in this editor. Nothing was applied from this draft.'));
    }
  }
  async function choose(title, selected, offset, clamped) {
    await ui.reveal(node => node.identifier === 'audio-anchor');
    assert.deepEqual(await session.command('menu-action', { target: 'audio-anchor', action: title }),
      { dispatched: true, coverage: 'semantic-menu-action' }, 'One public action on the original menu button, not a physical menu gesture');
    await menuState(selected, offset, clamped); await pendingUnchanged();
  }
  async function apply(expected) {
    const previousBits = baseline.dateReferenceTimeBits;
    await ui.finishTrim();
    current = await mutation(current, expected);
    await ui.closeLibrary();
    const after = await session.command('loaded-project');
    assert.deepEqual(after.project, current);
    const { modifiedAt: beforeModified, ...beforeOtherDates } = previousBits;
    const { modifiedAt: afterModified, ...afterOtherDates } = after.dateReferenceTimeBits;
    assert.deepEqual(afterOtherDates, beforeOtherDates, 'Apply preserves every unrelated exact Date witness');
    assert.equal(typeof beforeModified, 'string'); assert.equal(typeof afterModified, 'string');
    await captureBaseline();
  }
  async function cancelAndCheck() {
    await ui.finishTrim(false); await unchanged(packages);
    await ui.closeLibrary(); await outsideUnchanged();
  }

  await run('baseline-trim', async () => {
    await ui.openLibrary();
    await ui.openTrim(current.audioClips[0], ['0.000', '4.000', '0.000']);
    await initialTrimUnchanged();
    for (const [id, text] of [['audio-source-in', '0.500'], ['audio-duration', '2.500'], ['audio-placement-offset', '0.250']]) {
      await ui.input(id, text); await pendingUnchanged();
    }
    await apply(editedContent(current, project => {
      Object.assign(project.audioClips[0], { sourceStartMs: 500, durationMs: 2500, startMs: 250 });
    }));
    assert.equal(current.audioClips[0].entryId, 'line1');
  });

  if (direction) {
    await run('direction-choice-cancel', async () => {
      await openOriginal(); await choose(secondTitle, 2, '0.000', true); await cancelAndCheck();
    });
    await run('direction-choice-apply', async () => {
      await openOriginal(); await choose(secondTitle, 2, '0.000', true);
      await apply(editedContent(current, project => {
        Object.assign(project.audioClips[0], { entryId: 'line2', startMs: 0 });
      }));
      assert.equal(current.audioClips[0].entryId, 'line2');
    });
  } else {
    await run('library-only-observation-rejected', async () => {
      await ui.openLibrary();
      await assert.rejects(session.command('loaded-project'),
        /^Error: loaded-project: Synthetic loaded-project observation is unavailable or invalid\.$/);
      await unchanged(packages);
      await ui.closeLibrary(); await outsideUnchanged();
    });
    await openOriginal();
    await run('attachment-guard-rejections', async () => {
      const anchor = await ui.reveal(node => node.identifier === 'audio-anchor');
      const rejects = [
        { target: 'audio-anchor' }, { target: 'audio-anchor', action: null },
        { target: 'audio-anchor', action: 1 }, { target: 'audio-anchor', action: 'removed' },
        { target: anchor.path, action: 'Scene time' },
        ...['entryId', 'clipID', 'sceneID', 'projectID', 'handler', 'path'].map(key =>
          ({ target: 'audio-anchor', action: 'Scene time', [key]: 'not-an-accepted-input' })),
      ];
      for (const request of rejects) {
        await assert.rejects(session.command('menu-action', request),
          /^Error: menu-action: Audio attachment menu action is outside the supported isolated scope$/);
        await menuState(1, '0.250', false); await pendingUnchanged();
      }
      await session.waitFor(nodes => nodes.some(node => node.identifier === 'audio-import-menu'));
      await assert.rejects(session.command('menu-action', { target: 'audio-import-menu', action: 'Scene time' }),
        /^Error: menu-action: Target is behind the active presentation$/);
      await menuState(1, '0.250', false); await pendingUnchanged();
      // A rejected menu title is adapter validation, never the old draft's
      // removed-entry branch. No slider/alert action, provider resolution or model mutation occurs.
    });
    await run('nan-offset-attachment', async () => {
      await ui.input('audio-placement-offset', 'nan'); await pendingUnchanged();
      await ui.reveal(node => node.identifier === 'audio-anchor');
      assert.deepEqual(await session.command('menu-action', { target: 'audio-anchor', action: 'Scene time' }),
        { dispatched: true, coverage: 'semantic-menu-action' });
      await menuState(1, 'nan', false, { invalid: true }); await pendingUnchanged();
    });
    await run('cancel-invalid-attachment', cancelAndCheck);
    await openOriginal();
    await run('scene-time-preserves-250', () => choose('Scene time', 0, '0.250', false));
    await run('line2-clamps-to-3000', () => choose(secondTitle, 2, '0.000', true));
    await run('scene-time-preserves-3000', async () => {
      await choose('Scene time', 0, '3.000', false);
      await session.waitFor(nodes => nodes.some(node => node.text === 'Source length: 4.0s · Scene placement: 00:03.0 – 00:05.5\nPlayback stops at the scene’s end; the saved source trim is unchanged.'));
    });
    await run('cancel-attachment', cancelAndCheck);
    await run('repeat-and-apply-scene-time', async () => {
      await openOriginal();
      await choose('Scene time', 0, '0.250', false);
      await choose(secondTitle, 2, '0.000', true);
      await choose('Scene time', 0, '3.000', false);
      await apply(editedContent(current, project => {
        delete project.audioClips[0].entryId; project.audioClips[0].startMs = 3000;
      }));
      assert.equal(Object.hasOwn(current.audioClips[0], 'entryId'), false);
    });
  }
  await run('reopen-attachment-noop', async () => {
    const offset = direction ? '0.000' : '3.000';
    await ui.openLibrary(); await ui.openTrim(current.audioClips[0], ['0.500', '2.500', offset]);
    await initialTrimUnchanged();
    await menuState(direction ? 2 : 0, offset, false); await pendingUnchanged();
    await ui.finishTrim(); await unchanged(packages);
    await ui.closeLibrary(); await outsideUnchanged();
  });
  return current;
}
