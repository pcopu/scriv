import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
const f = JSON.parse(await readFile(new URL('../design/storyboard-timing-example.json', import.meta.url), 'utf8'));

test('approved excerpt owns 10.2 seconds; coverage creates no sequence time', () => {
  const owned = f.authored_sequence.reduce((sum, e) => sum + e.owned_duration_ms, 0);
  assert.equal(owned, 10200);
  assert.equal(f.sequence_window.duration_ms, owned);
  assert.equal(f.coverage_display_window.span_ms, 10600);
  for (const d of f.direction_cues) {
    assert.equal(d.coverage_start_ms, d.authored_start_ms);
    assert.ok(d.coverage_end_ms >= d.owned_end_ms);
    assert.equal(d.coverage_handle, 'lower_end_only');
  }
});
test('word cut moves preserve all spoken text, timestamps and image duration', () => {
  const edit = f.boundary_edit_example;
  assert.equal(edit.before.reduce((n, c) => n + c.duration_ms, 0), edit.after.reduce((n, c) => n + c.duration_ms, 0));
  assert.equal(edit.before.map(c => c.script_text_fragment).join(' '), edit.after.map(c => c.script_text_fragment).join(' '));
  assert.deepEqual(edit.after.map(c => c.duration_ms), [1400,2400]);
  for (const speech of f.speech_cues) {
    const words = speech.word_ids.map(id => f.word_cues.find(w => w.id === id));
    assert.equal(words.map(w => w.text).join(' '), speech.text);
    assert.equal(words[0].start_ms, speech.start_ms);
    assert.equal(words.at(-1).end_ms, speech.end_ms);
    for (let i=1;i<words.length;i++) assert.equal(words[i-1].end_ms,words[i].start_ms);
  }
});
test('every word is assigned once across the example image sequence', () => {
  const covered = f.image_cues.flatMap(c=>c.covered_word_ids);
  assert.equal(new Set(covered).size, covered.length);
  assert.deepEqual([...covered].sort(),f.word_cues.map(w=>w.id).sort());
  for (let i=1;i<f.image_cues.length;i++) assert.equal(f.image_cues[i-1].end_ms,f.image_cues[i].start_ms);
});
