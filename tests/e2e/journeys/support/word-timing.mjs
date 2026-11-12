import assert from 'node:assert/strict';
import { authoredFixture } from './line-duration-cases.mjs';
import { lineDurationSteps, ready } from './line-duration-steps.mjs';

const source = 'apps/mac/Tests/ScrivCoreTests/WordTimingEditingTests.swift';
const hash = '90425bbc8b6e97fa0ca74c6da78103ff378c68c85ee1f736d406a1b3afab19c9';
export const action = 'Edit word timing…';
export const fixtureKey = 'interior-word';
export function fixture() {
  // Same constructor defaults as frozen fixture(), including ABSENT optional
  // links, anchors and word markers. Only project identity/date are synthetic.
  const value = authoredFixture(); value.id = 'word-timing-interior'; return value;
}
export function expected(before) {
  const value = structuredClone(before);
  value.entries[0].words[1] = { id: 'w2', text: 'two', startMs: 1700, endMs: 2100, timingSource: 'authored' };
  delete value.revision; delete value.modifiedAt; return value;
}
export function audit() {
  const input = fixture();
  assert.deepEqual(input.entries, [{ id: 'e', sceneId: 's', order: 0, kind: 'dialogue', text: 'one two three',
    ownedDurationMs: 3000, coverageDurationMs: 0, color: 'purple', words: [
      { id: 'w1', text: 'one', startMs: 0, endMs: 600 }, { id: 'w2', text: 'two', startMs: 1000, endMs: 1600 },
      { id: 'w3', text: 'three', startMs: 2200, endMs: 2800 }] }]);
  assert.deepEqual(input.cues, [{ id: 'c1', sceneId: 's', label: '', startMs: 0, endMs: 1500, prompt: '' },
    { id: 'c2', sceneId: 's', label: '', startMs: 1500, endMs: 3000, prompt: '' }]);
  assert.deepEqual(input.scenes, [{ id: 's', title: 'Untitled scene', order: 0 }]);
  assert.deepEqual(input.audioAssets, []); assert.deepEqual(input.audioClips, []);
  const output = expected(input);
  assert.deepEqual(output.entries[0].words.filter(word => word.id !== 'w2'), input.entries[0].words.filter(word => word.id !== 'w2'));
  assert.deepEqual(output.cues, input.cues);
  return { journey: 'AUT-J15', portion: fixtureKey, status: 'prepared-native-unverified', nativeVerified: false,
    retirementAllowed: false, acceptedMethodCount: 0, wholeMethodCandidateCount: 1,
    baselineCommit: '4d14b29f4fb49891e850fa9a8e5742dc878603c8', source, sha256: hash,
    baselineID: source + '::0001', method: 'testInteriorWordRetimesWithoutMovingCutsOrNeighbors',
    exactAssertions: ['w2 1700–2100 authored', 'w1 unchanged', 'w3 unchanged', 'entry text unchanged',
      'complete cues unchanged', 'complete audioAssets unchanged', 'complete audioClips unchanged', 'scene duration unchanged'],
    route: 'Embedded Layers word UIButton > its stored secondary UIAction > direct WordTimingEditorController formSheet > real text fields and Save timing',
    stimulusDifference: 'Frozen test invokes singular setWordTiming; actual editor invokes reviewed plural setWordTimings. Exact observable contract candidate, not singular implementation coverage.',
    strengthened: ['reject extra request key', 'reject wrong owning button', 'cancel draft and reopen', 'invalid overlap rejected by draft UI then corrected in same sheet', 'complete saved and loaded model/date invariance while drafting', 'one revision per save', 'different-document reopen'],
    partialOnly: { 'WordTimingEditingTests.swift::0002': 'Not exercised: its singular stale-neighbor rejection and populated audio fixture are not replaced by this UI validation case.' },
    deferred: ['all other word-timing frozen methods', 'singular core setter rejection branches', 'native menu presentation/selection', 'hardware input', 'dragging', 'audio bytes/playback', 'lease races', 'stale context races', 'transient state between samples', 'process restart'],
    fixture: input };
}

export function wordTimingSteps(session) {
  const base = lineDurationSteps(session);
  async function node(predicate) {
    for (let attempt = 0; attempt < 8; attempt++) {
      // Requery identity/path/layout after every native scroll or rebuild.
      const nodes = await session.waitFor(nodes => nodes.filter(predicate).length === 1
        && nodes.find(predicate).enabled === true);
      const target = nodes.find(predicate);
      if (ready(target)) return target;
      const scroll = nodes.filter(candidate => candidate.scroll && candidate.hittable
        && target.path.startsWith(candidate.path + '.')
        && (target.frame.y < candidate.frame.y
          || target.frame.y + target.frame.height > candidate.frame.y + candidate.frame.height))
        .sort((a, b) => b.path.length - a.path.length)[0];
      assert.ok(scroll, 'Clipped word timing control requires a reachable native scrolling ancestor; covered controls have no activation fallback');
      const y = scroll.scroll.y + target.frame.y - scroll.frame.y
        - scroll.frame.height / 2 + target.frame.height / 2;
      assert.ok(Number.isFinite(y) && Math.abs(y - scroll.scroll.y) > 0.5,
        'Native scrolling must make vertical progress toward the clipped control');
      await session.command('scroll', { target: scroll.path, y });
    }
    throw new Error('Word timing control remained unreachable after bounded native scrolling');
  }
  async function activate(predicate) {
    const target = await node(predicate);
    assert.deepEqual(await session.command('activate', { target: target.path }), { dispatched: true });
  }
  async function expand() {
    const disclosure = await node(node => node.identifier === 'preview-layers-disclosure');
    if (disclosure.label === 'Expand Layers') await activate(node => node.identifier === 'preview-layers-disclosure');
    await session.waitFor(nodes => nodes.some(node => node.identifier === 'preview-layers-disclosure' && node.label === 'Collapse Layers'));
    // Keep default scale: the 600ms word has a useful hit area. Reveal clipped
    // controls only through their real UIScrollView; no covered activation,
    // drag-handle or model fallback.
  }
  async function target() {
    await expand();
    const button = await node(node => node.title === 'two' && node.label === 'two');
    const menu = await session.command('menu', { target: button.path });
    assert.deepEqual(menu.primary, []); assert.deepEqual(menu.context, []);
    assert.equal(menu.secondary.length, 1); assert.equal(menu.secondary[0].type, 'menu'); assert.equal(menu.secondary[0].title, '');
    assert.deepEqual(menu.secondary[0].children, [{ type: 'action', title: action, disabled: false, hidden: false, state: 'off' }]);
    return button;
  }
  const field = which => node => node.identifier === `word-timing-${which}`;
  async function open(start = '1.000', end = '1.600') {
    const button = await target();
    assert.deepEqual(await session.command('menu-action', { target: button.path, action }),
      { dispatched: true, coverage: 'semantic-menu-action' });
    assert.equal((await node(field('start'))).text, start);
    assert.equal((await node(field('end'))).text, end);
    await node(node => node.identifier === 'word-timing-save');
    assert.deepEqual(await session.command('presented-alerts'), []);
  }
  async function input(which, text) {
    const target = await node(field(which));
    await session.command('text', { target: target.path, text });
    await session.waitFor(nodes => nodes.some(node => field(which)(node) && node.text === text && ready(node)));
  }
  async function closed() {
    await session.waitFor(nodes => nodes.every(node => !field('start')(node) && !field('end')(node))
      && nodes.some(node => node.identifier === 'workspace-tabs' && ready(node)));
    assert.deepEqual(await session.command('presented-alerts'), []);
  }
  async function importFixture(startup) {
    const input = fixture();
    assert.deepEqual(await session.command('import-json', { text: JSON.stringify(input) }), { dispatched: true, projectChanged: true });
    const project = await base.saved(project => project.title === input.title && project.id !== startup.id);
    assert.notEqual(project.id, input.id); assert.equal(project.revision, 0);
    const actual = structuredClone(project), authored = structuredClone(input);
    for (const key of ['id', 'createdAt', 'modifiedAt']) { delete actual[key]; delete authored[key]; }
    assert.deepEqual(actual, authored, 'Complete constructor defaults retained on import');
    assert.deepEqual((await base.loaded()).project, project);
    await base.othersUnchanged(startup, project.id); return project;
  }
  async function guardChecks() {
    const packages = await base.packages(), loaded = await base.loaded();
    const word = await target();
    await assert.rejects(session.command('menu-action', { target: word.path, action, unexpected: true }), /outside the supported isolated scope/);
    await base.unchanged(packages, loaded);
    const dialogue = await node(node => node.title === 'Dialogue\none two three' && node.label === node.title);
    await assert.rejects(session.command('menu-action', { target: dialogue.path, action }), /outside the supported isolated scope/);
    await base.unchanged(packages, loaded);
  }
  async function pendingUnchanged(packages, loaded) {
    // Native v43 evidence: the exact sheet may expose its enabled fields before
    // the strict read-only presentation scope is ready. Retry only that read
    // rejection, never an action or an invariance assertion.
    // Soft retry window; each existing read retains its transport timeout.
    const deadline = Date.now() + 3000;
    for (;;) {
      try { await base.unchanged(packages, loaded); return; }
      catch (error) {
        if (error.message !== 'loaded-project: Synthetic loaded-project observation is unavailable or invalid.'
          || Date.now() >= deadline) throw error;
        await new Promise(resolve => setTimeout(resolve, 50));
        if (Date.now() >= deadline) throw error;
      }
    }
  }
  async function pendingCases() {
    const packages = await base.packages(), loaded = await base.loaded();
    await open(); await input('start', '1.1'); await input('end', '1.9');
    await pendingUnchanged(packages, loaded); await base.button('Cancel'); await closed();
    await pendingUnchanged(packages, loaded); await open();
    await input('start', '0.5'); await base.button('Save timing');
    const notice = '“two” would overlap “one”. Shorten the previous word’s end or move this word’s start later. Select either word above to adjust it; all changes save together.';
    await session.waitFor(nodes => nodes.some(node => node.text === notice));
    assert.equal((await node(field('start'))).text, '0.5');
    await pendingUnchanged(packages, loaded);
    // Correction is in the SAME sheet. No direct core rejection is claimed.
    await input('start', '1.7'); await input('end', '2.1'); await pendingUnchanged(packages, loaded);
  }
  return { ...base, open, input, closed, importFixture, guardChecks, pendingCases };
}
