import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fixture, modelLayout, report } from '../scripts/profile-playback-render-work.mjs';

const source = path => readFile(new URL(`../${path}`, import.meta.url), 'utf8');

test('rail snapshot reference equivalence includes zero-owned notes, reflow, missing frames and active drag', () => {
  for (let seed = 0; seed < 180; seed += 1) {
    const input = fixture(seed % 61);
    input.anchorOffset = seed % 2 ? 16 : 26;
    input.rowSpacing = seed % 2 ? 5 : 23;
    for (let index = 0; index < input.entries.length; index += 1) {
      const entry = input.entries[index];
      entry.duration = entry.direction ? (seed % 3 === 0 ? 700 : 0) : 500 + (seed * (index + 1) * 71) % 5000;
      entry.coverage = entry.direction ? seed * 153 % 30000 : 0;
      if ((index + seed) % 13 === 0) input.frames.delete(entry.id);
      else input.frames.set(entry.id, { minY: index * 111 + index * index, maxY: index * 111 + index * index + 80 });
    }
    if (seed % 4 === 0 && input.entries.length) input.drag = { id: input.entries[0].id, currentY: seed * 51 };
    assert.deepEqual(modelLayout(input, true).result, modelLayout(input, false).result, `seed ${seed}`);
  }
});

test('one geometry snapshot replaces nested geometry reconstruction without claiming native speed', () => {
  for (const row of report()) {
    assert.equal(row.outputEquivalent, true);
    assert.equal(row.candidate.geometryBuilds, 1);
    assert.equal(row.candidate.endpointCalls, row.directions);
    assert.ok(row.before.geometryBuilds > row.candidate.geometryBuilds);
    assert.ok(row.before.startLookups > row.candidate.startLookups);
  }
  assert.deepEqual(modelLayout(fixture(0), true).counters, { geometryBuilds: 0, startLookups: 0, endpointCalls: 0 });
});

test('candidate source snapshots only within each pass, and preserves accessible direction controls', async () => {
  const rails = await source('apps/catalyst/ScrivUIKit/Script/ScriptDirectionRails.swift');
  const layout = rails.split('override func layoutSubviews() {')[1].split('override func draw(')[0];
  assert.equal((layout.match(/let rows = geometry/g) ?? []).length, 1);
  assert.match(layout, /directions\.map \{ \(\$0\.id, endpoint\(\$0, rows: rows\)\) \}/);
  const overlap = layout.split('let overlap = directions.filter')[1].split('pair.1.overlapMenu')[0];
  assert.doesNotMatch(overlap, /endpoint\(/);
  assert.match(overlap, /end >= frame\.minY \+ 12 && end <= candidateEnd \+ 14/);
  for (const value of ['pair.0.accessibilityLabel', 'pair.1.accessibilityLabel', 'pair.1.accessibilityValue', 'pair.1.overlapMenu', 'pair.1.isEnabled']) assert.ok(layout.includes(value));
  assert.match(rails, /drag\?\.id == entry\.id \? drag!\.currentY/);
  assert.match(rails, /old\.navigation == store\.navigationContext/);
  assert.match(rails, /store\.project\.entries\.first\(where: \{ \$0\.id == id \}\) == old\.entry/);
});

test('script computes one current-word snapshot outside the row loop without changing the scene clock', async () => {
  const controller = await source('apps/catalyst/ScrivUIKit/Script/ScriptScreenController.swift');
  const snapshot = controller.indexOf('let currentWordID = store.currentWordID');
  const loop = controller.indexOf('for entry in entries {', snapshot);
  assert.ok(snapshot >= 0 && snapshot < loop);
  assert.equal((controller.match(/store\.currentWordID/g) ?? []).length, 1);
  assert.match(controller, /currentWordID: currentWordID, peers:/);
  const store = await source('apps/mac/Sources/ScrivApp/Services/WorkspaceStore.swift');
  assert.match(store, /try\? await Task\.sleep\(for:\.milliseconds\(16\)\)/);
  assert.match(store, /playbackClock\.position\(nowMs:ProcessInfo\.processInfo\.systemUptime \* 1000/);
});

test('native diagnostics are isolated and independently test heartbeat, pause, output equivalence and timing', async () => {
  const native = await source('apps/catalyst/Tests/ScrivUIKitTests/PlaybackResponsivenessTests.swift');
  for (const name of [
    'testNoAudioPlaybackYieldsToMainQueueAndRepeatedPauseStopsClock',
    'testRailEndpointsAndOverlapMenusMatchUncachedReferenceAfterEditsAndReflow',
    'testWordHighlightRefreshesAcrossSeeksWithoutReplacingRows',
    'testProfileSyntheticScriptPlaybackRenderPasses',
  ]) assert.ok(native.includes(`func ${name}(`));
  assert.match(native, /arguments\.contains\("--screenshots"\)/);
  assert.match(native, /DispatchQueue\.main\.asyncAfter/);
  assert.match(native, /await fulfillment\(of: \[heartbeat\], timeout: 3\)/);
  assert.match(native, /XCTAssertEqual\(store\.project, original/);
});

test('native fixed-work playback profile retains every sample and semantic invariant without XCTest metric reporting', async () => {
  const native = await source('apps/catalyst/Tests/ScrivUIKitTests/PlaybackResponsivenessTests.swift');
  const profile = native.split('func testProfileSyntheticScriptPlaybackRenderPasses() async throws {')[1]?.split('private func isolatedStore()')[0];
  assert.ok(profile, 'The profile remains an async XCTest, not an excluded diagnostic');
  assert.doesNotMatch(profile, /XCTSkip|measure\(|XCTClockMetric|XCTMeasureOptions/);
  assert.match(profile, /let bootstrapDeadline = ProcessInfo\.processInfo\.systemUptime \+ 5/);
  assert.match(profile, /while store\.isBootstrapping && ProcessInfo\.processInfo\.systemUptime < bootstrapDeadline/);
  assert.match(profile, /guard !store\.isBootstrapping else \{\s*XCTFail/);
  assert.ok(profile.indexOf('guard !store.isBootstrapping') < profile.indexOf('store.project = fixture(count: 96)'));
  assert.match(profile, /CGRect\(x: 0, y: 0, width: 800, height: 900\)/);
  assert.match(profile, /store\.isPlaying = true\s*defer \{ store\.isPlaying = false \}/);
  assert.match(profile, /for batch in 0\.\.<11 \{/);
  const timed = profile.split('let started = ProcessInfo.processInfo.systemUptime')[1]?.split('let elapsed = ProcessInfo.processInfo.systemUptime - started')[0];
  assert.ok(timed, 'Each complete batch must use monotonic elapsed time');
  assert.match(timed, /for tick in 0\.\.<12 \{\s*store\.playheadMs = Double\(tick \* 16\)\s*controller\.storeDidChange\(\)\s*controller\.view\.layoutIfNeeded\(\)\s*completedTicks \+= 1\s*\}/);
  assert.doesNotMatch(timed, /await|XCTAssert|print\(|JSONSerialization|XCTAttachment|FileManager|Data\(/);
  for (const invariant of [
    'XCTAssertEqual(completedTicks, 12)',
    'XCTAssertEqual(store.project, original',
    'XCTAssertEqual(store.sceneEntries.map(\\.id), entryIDs)',
    'XCTAssertEqual(store.sceneEntries.flatMap { $0.words.map(\\.id) }, wordIDs)',
    'XCTAssertEqual(rowIdentities(), originalRows',
    'XCTAssertEqual(store.selectedSceneID, "scene")',
    'XCTAssertEqual(store.selectedEntryID, selectedEntryID)',
    'XCTAssertEqual(store.playheadMs, 176)',
    'XCTAssertEqual(store.currentWordID, expectedWord.id)',
    'XCTAssertTrue(store.isPlaying)',
    'XCTAssertEqual(durations.count, 11)',
    'XCTAssertEqual(batchTickCounts.reduce(0, +), 132)',
    'XCTAssertEqual(measured.count, 10)',
  ]) assert.ok(profile.includes(invariant), invariant);
  assert.match(profile, /elapsed\.isFinite && elapsed > 0/);
  assert.match(profile, /let measured = Array\(durations\.dropFirst\(\)\)/);
  for (const field of ['coldSeconds', 'measuredSeconds', 'rawBatchSeconds', 'batchTickCounts', 'sampleCount', 'totalTicks', 'operatingSystem', 'processorCount', 'appVersion', 'appBuild']) assert.ok(profile.includes(`"${field}":`), field);
  assert.match(profile, /"coldSeconds": durations\[0\], "measuredSeconds": measured/);
  assert.match(profile, /"rawBatchSeconds": durations, "batchTickCounts": batchTickCounts/);
  assert.match(profile, /attachment\.lifetime = \.keepAlways\s*add\(attachment\)/);
  assert.match(profile, /print\("Playback fixed-work profile:/);
  assert.match(profile, /underlying file-open cause remains unknown/);
});
