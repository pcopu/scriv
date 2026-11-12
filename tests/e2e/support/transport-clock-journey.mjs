import assert from 'node:assert/strict';
import { performance } from 'node:perf_hooks';

// Partial interaction replacement only for PlaybackTests.swift at frozen
// 4d14b29f4fb49891e850fa9a8e5742dc878603c8:
// testSeekDuringPlaybackRebasesNextTick and testPauseResumeClampAndInvalidTimes.
// Real-clock observations cannot replace exact injected timestamps, NaN or
// zero-duration clock assertions. No baseline retirement or physical-input claim.
export const transportClockCases = Object.freeze([{
  id: 'running-seek-pause-resume-end',
  source: 'apps/mac/Tests/ScrivCoreTests/PlaybackTests.swift',
  sourceSHA256: 'aca5a06bca4430afea859c8b1a4b3d53674641b286dd7b43fae999649fb87486',
  baselineCommit: '4d14b29f4fb49891e850fa9a8e5742dc878603c8',
  methods: ['testSeekDuringPlaybackRebasesNextTick', 'testPauseResumeClampAndInvalidTimes'],
  nativeVerified: false, retirementAllowed: false,
  scope: 'Real slider/button dispatch and sampled real-clock trajectories only',
  excluded: ['exact injected clock timestamps', 'NaN seek', 'zero-duration clock', 'physical input'],
}]);
export const transportClockFixture = {
  schemaVersion: 1, id: 'transport-clock-fixture', title: 'Transport clock journey',
  createdAt: 1700000000000, modifiedAt: 1700000000000, revision: 0,
  scenes: [{ id: 's', title: 'Ten second scene', order: 0 }],
  entries: [{ id: 'direction', sceneId: 's', order: 0, kind: 'direction',
    text: 'Watch the clock.', ownedDurationMs: 10000, coverageDurationMs: 10000,
    color: 'purple', words: [] }],
  characters: [], images: [], cues: [], audioAssets: [], audioClips: [], audioVolume: 1,
};
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const seekID = 'scene-playback-position';
const label = (nodes, name) => nodes.filter(n => n.label === name && n.enabled && n.hittable);
const duration = 10000;
// Production schedules 16ms ticks. 150ms allows about nine ticks of UI latency,
// not an arbitrarily widened acceptance range. Each IPC call is capped at 500ms
// and each running observation at 1800ms since its anchor; delayed runs fail as
// inconclusive. The 1000→6000→200 anchors remain disjoint within these bounds.
const slack = 150, maxCommandMs = 500, maxPhaseMs = 1800;

export async function runTransportClockJourney(session) {
  async function timed(command, args = {}) {
    const before = performance.now();
    const result = await session.command(command, args);
    const after = performance.now();
    assert.ok(after - before <= maxCommandMs, `${command}: inconclusive IPC delay exceeds ${maxCommandMs}ms`);
    return { before, after, result };
  }
  function position(nodes, running) {
    const sliders = nodes.filter(n => n.identifier === seekID);
    assert.equal(sliders.length, 1);
    assert.ok(sliders[0].enabled && sliders[0].hittable);
    assert.equal(sliders[0].slider.maximum, duration);
    assert.equal(label(nodes, running ? 'Pause scene' : 'Play scene').length, 1);
    assert.equal(label(nodes, running ? 'Play scene' : 'Pause scene').length, 0);
    const value = sliders[0].slider.value;
    assert.ok(Number.isFinite(value));
    return value;
  }
  async function activate(nodes, name) {
    const buttons = label(nodes, name);
    assert.equal(buttons.length, 1);
    return timed('activate', { target: buttons[0].path });
  }
  function withinTrajectory(value, observation, anchor, origin, name) {
    assert.ok(observation.after - anchor.before <= maxPhaseMs, `${name}: inconclusive delayed observation`);
    const lower = origin + Math.max(0, observation.before - anchor.after - slack);
    const upper = origin + observation.after - anchor.before + slack;
    assert.ok(value >= lower && value <= upper,
      `${name}: ${value} outside monotonic host-time bracket [${lower}, ${upper}]`);
  }
  async function runningSamples(anchor, origin, name) {
    let last = origin, observation;
    for (let index = 0; index < 3; index++) {
      await delay(220); // Multiple observations beyond a production tick.
      observation = await timed('snapshot');
      const value = position(observation.result, true);
      withinTrajectory(value, observation, anchor, origin, name);
      assert.ok(value > last + 20, `${name}: later samples must advance, not freeze or snap back`);
      last = value;
    }
    return observation.result;
  }
  // Existing guarded import-json invokes the production importer. This is a
  // literal synthetic input, never a direct installed-store/model mutation.
  assert.deepEqual(await session.command('import-json', { text: JSON.stringify(transportClockFixture) }),
    { dispatched: true, projectChanged: true });
  let nodes = await session.waitFor(nodes => nodes.some(n => n.identifier === seekID
    && n.slider?.maximum === duration) && label(nodes, 'Play scene').length === 1);
  position(nodes, false);
  await timed('slider', { target: seekID, value: 1000 });
  nodes = (await timed('snapshot')).result;
  assert.equal(position(nodes, false), 1000, 'Paused seek is exact');
  let anchor = await activate(nodes, 'Play scene');
  nodes = await runningSamples(anchor, 1000, 'Start from paused seek');
  for (const origin of [6000, 200]) {
    position(nodes, true);
    anchor = await timed('slider', { target: seekID, value: origin });
    nodes = await runningSamples(anchor, origin, `Running seek ${origin}`);
  }
  const pause = await activate(nodes, 'Pause scene');
  nodes = (await timed('snapshot')).result;
  const paused = position(nodes, false);
  withinTrajectory(paused, pause, anchor, 200, 'Pause preserves rebased position');
  for (let index = 0; index < 3; index++) {
    await delay(220);
    nodes = (await timed('snapshot')).result;
    assert.equal(position(nodes, false), paused, 'Repeated paused observations remain exactly stable');
  }
  anchor = await activate(nodes, 'Play scene');
  nodes = await runningSamples(anchor, paused, 'Resume from paused position');
  // Exercise natural completion after a running near-end seek, not a direct
  // seek to maximum. Use bounded polling, then require repeated exact clamping.
  position(nodes, true);
  anchor = await timed('slider', { target: seekID, value: 9000 });
  await delay(80);
  const nearEnd = await timed('snapshot');
  const nearEndValue = position(nearEnd.result, true);
  withinTrajectory(nearEndValue, nearEnd, anchor, 9000, 'Near-end running seek');
  assert.ok(nearEndValue > 9000 && nearEndValue < duration,
    'Require an advancing, still-running near-end sample; missing this window is inconclusive');
  let ended = false;
  while (performance.now() - anchor.before < maxPhaseMs) {
    await delay(80);
    const observation = await timed('snapshot');
    nodes = observation.result;
    if (label(nodes, 'Play scene').length === 1) {
      assert.equal(position(nodes, false), duration, 'Natural end clamps exactly to scene duration');
      assert.ok(observation.after - anchor.before <= maxPhaseMs, 'End observation must be timely');
      assert.ok(observation.after - anchor.before >= 1000 - slack, 'End cannot occur before the remaining interval');
      assert.ok(observation.after - nearEnd.before >= duration - nearEndValue - slack,
        'End must honor the remaining interval witnessed by the running sample');
      ended = true;
      break;
    }
    withinTrajectory(position(nodes, true), observation, anchor, 9000, 'Near-end running seek');
  }
  assert.ok(ended, 'Natural end must return to Play within the bounded observation window');
  for (let index = 0; index < 2; index++) {
    await delay(220);
    assert.equal(position((await timed('snapshot')).result, false), duration, 'End remains clamped and stopped');
  }
}
