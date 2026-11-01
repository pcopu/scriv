import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
const source = path => readFile(new URL(`../apps/catalyst/${path}`, import.meta.url), 'utf8');

test('compact missing portraits use an accessible icon rather than a clipped sentence', async () => {
  const ui = await source('ScrivUIKit/Characters/CharacterTeamUI.swift');
  assert.match(ui, /if imageURL == nil, min\(size\.width, size\.height\) < 96/);
  assert.match(ui, /view = compactMissingPortrait\(\)/);
  const fallback = ui.split('static func compactMissingPortrait()')[1]?.split('\n    static func portrait(')[0];
  assert.ok(fallback, 'small missing portrait has a bounded dedicated fallback');
  assert.match(fallback, /person\.fill/);
  assert.match(fallback, /equalToConstant: 26/);
  assert.match(fallback, /isAccessibilityElement = true/);
  assert.match(fallback, /accessibilityTraits = \.image/);
  assert.match(fallback, /accessibilityValue = "No portrait on this device"/);
  assert.match(fallback, /UIToolTipInteraction/);
  assert.doesNotMatch(fallback, /UILabel|label\(/);
  assert.match(ui, /CharacterCropImageView\(source:store\.assetURL\(asset\),sha256:asset\.sha256,region:crop\.region/);
});

test('link appearance never overrides per-word playback foreground', async () => {
  const rows = await source('ScrivUIKit/Script/ScriptTextViews.swift');
  assert.match(rows, /display\.linkTextAttributes = \[\.underlineStyle: 0\]/);
  assert.doesNotMatch(rows, /display\.linkTextAttributes = \[[^\n]*(?:foregroundColor|backgroundColor)/);
  assert.match(rows, /\.link: url, \.foregroundColor: ScrivUIKitTheme\.accent/);
  assert.match(rows, /\.backgroundColor: ScrivUIKitTheme\.accent, \.foregroundColor: UIColor\.white/);
  assert.match(rows, /display\.isEditable = false; display\.isSelectable = true/);
  assert.match(rows, /URL\.scheme == "scriv-character"/);
  assert.match(rows, /editor\.markedTextRange == nil/);
  assert.match(rows, /onSelection\?\(textView\.selectedRange\)/);
});

test('native regression matrix covers exact text, identity, missing portraits and editor selection', async () => {
  const native = await source('Tests/ScrivUIKitTests/CharacterLinkVisualRegressionTests.swift');
  for (const name of [
    'testCompactMissingPortraitHasNoClippedTextAndKeepsAccessibleStatus',
    'testPlaybackWordRetainsWhiteForegroundAndBothCharacterIdentities',
    'testPlaybackRefreshDoesNotReplaceLiveEditorOrSelection',
    'testReviewHighlightKeepsExactSourceAndReadableText'
  ]) assert.ok(native.includes(`func ${name}(`));
});
