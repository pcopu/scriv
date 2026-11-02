import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const board = await readFile(new URL('../apps/catalyst/ScrivUIKit/Images/StoryboardViewController.swift', import.meta.url), 'utf8');

test('shared storyboard script is distributed once inside picture rows, never appended after the full grid', () => {
  const rebuild = board.split('private func rebuild() {')[1].split('private func buildSharedScript')[0];
  assert.match(rebuild, /StoryboardSharedScriptLayout\.rowIndices\(wordStarts: sharedWords\.map\(\\\.absoluteStart\), rowStarts: grouped\.map/);
  assert.match(rebuild, /for \(word, rowIndex\) in zip\(sharedWords, wordRows\) \{ wordsByRow\[rowIndex\]\.append\(word\) \}/);
  assert.match(rebuild, /for \(rowIndex, cues\) in grouped\.enumerated\(\)/);
  assert.match(rebuild, /group\.addArrangedSubview\(buildSharedScript\(words: wordsByRow\[rowIndex\], cues: cues, rowIndex: rowIndex\)\)/);
  assert.doesNotMatch(rebuild, /\n        buildSharedScript\(\)/);
  const render = board.split('private func buildSharedScript')[1].split('private func wordCue')[0];
  assert.match(render, /for item in words/);
  assert.match(render, /for cue in cues/);
  assert.doesNotMatch(render, /for item in sharedWords|for cue in store\.sceneCues/);
  assert.match(render, /words: self\.sharedWords\.map\(\\\.word\)/, 'Shift selection must still span the complete source stream');
});

test('row partition has source-order and tie witnesses; playback snapshots once without changing cue transfer', () => {
  const partition = board.split('enum StoryboardSharedScriptLayout')[1].split('@MainActor final class')[0];
  assert.match(partition, /if let previous = boundaries\.last, start <= previous\.start \{ continue \}/);
  assert.match(partition, /while boundary \+ 1 < boundaries\.count, boundaries\[boundary \+ 1\]\.start <= start \{ boundary \+= 1 \}/);
  assert.match(partition, /return boundaries\.isEmpty \? 0 : boundaries\[boundary\]\.row/);
  const update = board.split('private func updateSharedScript()')[1].split('fileprivate func selectWord')[0];
  assert.equal((update.match(/store\.currentWordID/g) ?? []).length, 1);
  assert.match(update, /playing = input\.currentWordID == item\.word\.id/);
  assert.match(board, /return cards\[cue\.id\]\?\.transfer\(wordID: wordID\)/);
  assert.match(board, /payload\.canApply\(to: store\.project, navigation: navigation, destination: cue\)/);
  assert.match(board, /store\.moveWords\(Set\(payload\.wordIDs\), fromCueId: payload\.cueID, toCueId: cue\.id\)/);
});

// Portable preservation witnesses, not native render/performance measurements.
test('inline rows retain current-main render caching while every row clock and rail updates each tick', () => {
  assert.match(board, /private var signature: \[AnyHashable\] = \[\]/);
  assert.match(board, /private struct SharedScriptInput: Equatable/);
  assert.match(board, /if bandFontSize != store\.scriptFontSize \* 1\.35/);
  const rebuild = board.split('private func rebuild() {')[1].split('private func buildSharedScript')[0];
  assert.match(rebuild, /playbackLabels\.removeAll\(\)/);
  assert.match(rebuild, /renderedSharedScript = nil; bandFontSize = nil/);
  const update = board.split('private func updateSharedScript()')[1].split('fileprivate func selectWord')[0];
  const gate = update.indexOf('guard input != renderedSharedScript || sharedMenuCueID != store.selectedCueID else { return }');
  assert.ok(gate > 0);
  for (const token of ['playbackLabels.forEach', 'for rail in coverageRails', 'let input = SharedScriptInput']) {
    const index = update.indexOf(token); assert.ok(index >= 0 && index < gate, token);
  }
  assert.ok(update.indexOf('for item in sharedWords') > gate);
  assert.match(update, /renderedSharedScript = input/);
  assert.match(update, /selected = input\.selectedWords\.contains/);
  assert.match(update, /let covered = input\.selectedCue\.map/);
});

// Reference-model property checks, not execution of UIKit or the Swift helper.
function rowIndices(wordStarts, rowStarts) {
  const boundaries = [];
  for (const [row, start] of rowStarts.entries()) {
    if (boundaries.length && start <= boundaries.at(-1).start) continue;
    boundaries.push({ row, start });
  }
  let boundary = 0;
  return wordStarts.map(start => {
    while (boundary + 1 < boundaries.length && boundaries[boundary + 1].start <= start) boundary++;
    return boundaries.length ? boundaries[boundary].row : 0;
  });
}

test('reference model preserves every word once through ties, gaps, overlaps and narrow reflow', () => {
  assert.deepEqual(rowIndices([-1, 0, 3999, 4000, 8000, 10000], [0, 4000, 4000, 8000]), [0, 0, 0, 1, 3, 3]);
  assert.deepEqual(rowIndices([1, 9000, 1000, 12000], [0, 4000, 8000]), [0, 2, 2, 2]);
  assert.deepEqual(rowIndices([1, 2], []), [0, 0]);
  for (let count = 1; count <= 200; count++) {
    const words = Array.from({ length: count }, (_, i) => ({ id: `w${i}`, text: i % 2 ? 'cafe\u0301' : '日本語👩🏽‍🚀', start: i * 127 }));
    for (const columns of [1, 2, 3]) {
      const starts = Array.from({ length: 20 }, (_, i) => Math.floor(i / 2) * 1500).filter((_, i) => i % columns === 0);
      const indices = rowIndices(words.map(w => w.start), starts);
      const rows = starts.map(() => []);
      words.forEach((word, i) => rows[indices[i]].push(word));
      assert.deepEqual(rows.flat(), words);
      assert.equal(new Set(rows.flat().map(w => w.id)).size, count);
      assert.ok(indices.every((row, i) => row >= (indices[i - 1] ?? 0) && row < starts.length));
    }
  }
});
