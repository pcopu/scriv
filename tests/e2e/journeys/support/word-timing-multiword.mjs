import assert from 'node:assert/strict';
import { fixture, wordTimingSteps } from './word-timing.mjs';
import { syntheticPCM, verifyImportedAsset } from './audio-library-fixtures.mjs';
import { ready } from './line-duration-steps.mjs';

export const multiwordKey = 'adjacent-words';
export function multiwordExpected(before) {
  const value = structuredClone(before);
  value.entries[0].words = [
    { id: 'w1', text: 'one', startMs: 0, endMs: 1200, timingSource: 'authored' },
    { id: 'w2', text: 'two', startMs: 1200, endMs: 1600, timingSource: 'authored' },
    { id: 'w3', text: 'three', startMs: 2200, endMs: 2800 },
  ];
  delete value.revision; delete value.modifiedAt; return value;
}
export function multiwordAudit() {
  const input = fixture(), output = multiwordExpected(input);
  assert.deepEqual(input.entries[0].words.map(({ startMs, endMs }) => [startMs, endMs]),
    [[0, 600], [1000, 1600], [2200, 2800]]);
  assert.deepEqual(output.entries[0].words.map(({ startMs, endMs }) => [startMs, endMs]),
    [[0, 1200], [1200, 1600], [2200, 2800]]);
  assert.deepEqual(output.entries[0].words[2], input.entries[0].words[2]);
  assert.deepEqual(output.cues, input.cues);
  assert.deepEqual(input.audioAssets, []); assert.deepEqual(input.audioClips, []);
  return { journey: 'AUT-J15', portion: multiwordKey, status: 'prepared-native-unverified',
    nativeVerified: false, retirementAllowed: false, acceptedMethodCount: 0, wholeMethodCandidateCount: 0,
    optIn: '--case adjacent-words', source: 'apps/catalyst/Tests/AudioTimingDraftTests.swift',
    sha256: '52b0175c308e208d67f5dd5e6729859b54dee1dc0f2e02f773b2b95fef04585b',
    sourceLines: '66–87',
    partialMethods: ['testWordSelectionRetainsEveryPendingDraftAndCancelLeavesProjectUntouched',
      'testNeighborWordDraftsSaveTogetherAndPreserveAudioAndImages'],
    oracle: 'Literal frozen ranges: cancel w1 100–700 and w2 1200–1700; reject w1 0–1200 against w2 1000–1600, then correct w2 to 1200–1600 in the same sheet and save both once.',
    route: 'Existing Layers secondary UIAction > real word timing chip UIButtons > real fields > Cancel/Save timing',
    strengthened: ['noncanonical raw decimal drafts survive repeated selection', 'full saved/loaded/date invariance while drafting and after rejection',
      'Cancel discards both drafts', 'one successful Save applies both words with exactly one revision',
      'untouched w3 retains absent authored marker', 'nonempty decoded audio metadata and measured waveform preserved', 'complete saved model oracle', 'different-document reopen and timing-sheet reopen'],
    fixtureDifference: 'Reuses the accepted interior-word JSON import, then imports real finite synthetic PCM via the existing production decoder boundary. Asset is 4000 ms; scene clip is explicitly clamped to 3000 ms at scene time zero. Frozen source has a second entry and a line-attached offset/trim clip. No literal full-fixture or whole-method equivalence claim.',
    deferred: ['frozen line-attached audio fixture', 'audio playback/byte reread', 'drag-range stimulus', 'preview geometry', 'native menu selection', 'hardware input',
      'stale/lease races', 'transient state between samples', 'process restart'], fixture: input };
}

export function multiwordSteps(session) {
  const ui = wordTimingSteps(session);
  const field = which => node => node.identifier === `word-timing-${which}`;
  async function control(predicate) {
    for (let attempt = 0; attempt < 8; attempt++) {
      const nodes = await session.waitFor(nodes => nodes.filter(predicate).length === 1 && nodes.find(predicate).enabled === true);
      const target = nodes.find(predicate);
      if (ready(target)) return target;
      const scroll = nodes.filter(candidate => candidate.scroll && candidate.hittable
        && target.path.startsWith(candidate.path + '.')
        && (target.frame.y < candidate.frame.y || target.frame.y + target.frame.height > candidate.frame.y + candidate.frame.height))
        .sort((a, b) => b.path.length - a.path.length)[0];
      assert.ok(scroll, 'Clipped chip needs a reachable real vertical scrolling ancestor; no covered activation fallback');
      const y = scroll.scroll.y + target.frame.y - scroll.frame.y - scroll.frame.height / 2 + target.frame.height / 2;
      assert.ok(Number.isFinite(y) && Math.abs(y - scroll.scroll.y) > 0.5);
      await session.command('scroll', { target: scroll.path, y });
    }
    throw new Error('Word timing chip remained unreachable after bounded native scrolling');
  }
  async function select(id, start, end) {
    const chip = await control(node => node.identifier === `word-timing-chip-${id}`);
    assert.deepEqual(await session.command('activate', { target: chip.path }), { dispatched: true });
    const text = { w1: 'one', w2: 'two', w3: 'three' }[id]; assert.ok(text);
    for (const [which, expected] of [['start', start], ['end', end]]) {
      const target = await control(field(which));
      assert.equal(target.label, `${which === 'start' ? 'Start' : 'End'} of “${text}”, seconds`);
      assert.equal(target.text, expected, 'Selection preserves the exact pending raw string, not a reformatted range');
    }
  }
  async function pendingUnchanged(packages, loaded) {
    // Same documented v43 read-only presentation readiness exception as the
    // existing helper. Never retry a mutation, assertion mismatch, or other error.
    const deadline = Date.now() + 3000;
    for (;;) {
      try { await ui.unchanged(packages, loaded); return; }
      catch (error) {
        if (error.message !== 'loaded-project: Synthetic loaded-project observation is unavailable or invalid.'
          || Date.now() >= deadline) throw error;
        await new Promise(resolve => setTimeout(resolve, 50));
        if (Date.now() >= deadline) throw error;
      }
    }
  }
  async function importFixture(startup) {
    const before = await ui.importFixture(startup);
    const capabilities = await session.command('capabilities');
    assert.ok(capabilities.commands.includes('import-audio'));
    assert.ok(capabilities.semanticApplicationCommands?.includes('import-audio'));
    await session.waitFor(nodes => nodes.some(node => node.identifier === 'scene-playback-position'
      && node.slider?.value === 0 && node.slider?.maximum === 3000 && ready(node)));
    const bytes = syntheticPCM();
    assert.deepEqual(await session.command('import-audio', { base64: bytes.toString('base64'), attachment: 'scene' }, 30000),
      { dispatched: true, imported: true, cleanupVerified: true });
    const after = await ui.saved(project => project.id === before.id && project.revision > before.revision);
    assert.equal(after.audioAssets.length, 1); assert.equal(after.audioClips.length, 1);
    const asset = after.audioAssets[0], clip = after.audioClips[0];
    verifyImportedAsset(asset, bytes);
    assert.match(clip.id, /^[0-9A-Fa-f-]{36}$/);
    assert.deepEqual(clip, { id: clip.id, sceneId: 's', assetId: asset.id, startMs: 0,
      sourceStartMs: 0, durationMs: 3000, volume: 1, isMuted: false },
    'Four-second source clamps to the three-second scene, not the frozen five-second scene');
    const expected = structuredClone(before);
    expected.audioAssets = [asset]; expected.audioClips = [clip];
    delete expected.revision; delete expected.modifiedAt;
    return ui.savedAfter(before, expected, startup);
  }
  async function pendingCases() {
    const packages = await ui.packages(), loaded = await ui.loaded();
    await ui.open(); await select('w1', '0.000', '0.600');
    await ui.input('start', '0.1000'); await ui.input('end', '0.7000');
    await select('w2', '1.000', '1.600');
    await ui.input('start', '1.2000'); await ui.input('end', '1.7000');
    await select('w1', '0.1000', '0.7000'); await pendingUnchanged(packages, loaded);
    await select('w2', '1.2000', '1.7000'); await pendingUnchanged(packages, loaded);
    await ui.button('Cancel'); await ui.closed(); await ui.unchanged(packages, loaded);

    await ui.open(); await select('w1', '0.000', '0.600');
    await ui.input('end', '1.2000'); await ui.button('Save timing');
    const notice = '“two” would overlap “one”. Shorten the previous word’s end or move this word’s start later. Select either word above to adjust it; all changes save together.';
    await session.waitFor(nodes => nodes.some(node => node.text === notice));
    await pendingUnchanged(packages, loaded);
    await select('w1', '0.000', '1.2000');
    // Correct the adjacent word in this SAME sheet. This is the only successful
    // Save below; the rejected attempt above cannot create a revision.
    await select('w2', '1.000', '1.600'); await ui.input('start', '1.2000');
    await select('w1', '0.000', '1.2000'); await select('w2', '1.2000', '1.600');
    await pendingUnchanged(packages, loaded);
  }
  async function verifyReopened() {
    const packages = await ui.packages(), loaded = await ui.loaded();
    await ui.open('1.200', '1.600'); await select('w1', '0.000', '1.200');
    await select('w3', '2.200', '2.800'); await select('w2', '1.200', '1.600');
    await pendingUnchanged(packages, loaded);
    await ui.button('Cancel'); await ui.closed(); await ui.unchanged(packages, loaded);
  }
  return { ...ui, importFixture, pendingCases, verifyReopened };
}
