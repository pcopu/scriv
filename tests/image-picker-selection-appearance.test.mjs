import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
const source = path => readFile(new URL(`../${path}`, import.meta.url), 'utf8');
const path = 'apps/catalyst/ScrivUIKit/Images/ImagePickerViewController.swift';

test('picker commit action installs a scoped state-aware neutral disabled appearance', async () => {
  const view = await source(path);
  assert.match(view, /ImagePickerSelectionAppearance\.install\(on: useButton\)/);
  assert.match(view, /accessibilityIdentifier = "image-picker-use-selection"/);
  const scoped = view.split('@MainActor enum ImagePickerSelectionAppearance')[1].split('@MainActor private final class ImageChoiceCollectionCell')[0];
  assert.match(scoped, /configurationUpdateHandler = \{ button in/);
  assert.match(scoped, /button\.isEnabled \? ImageUI\.accent : ScrivUIKitTheme\.inset/);
  assert.match(scoped, /button\.isEnabled \? UIColor\.white : ScrivUIKitTheme\.secondary/);
  assert.match(scoped, /configuration\.background\.backgroundColor = background/);
  assert.match(scoped, /backgroundColorTransformer = button\.isEnabled \? nil : UIConfigurationColorTransformer/);
  assert.match(scoped, /outgoing\.foregroundColor = foreground/);
  assert.match(scoped, /button\.setNeedsUpdateConfiguration\(\)/);
  assert.doesNotMatch(scoped, /store\.|chosenID|isEnabled =|removeFromSuperview|addAction|sendActions|setCueImage/);
});

test('selection, version scope, cancelled changes and preservation boundaries remain intact', async () => {
  const view = await source(path);
  assert.match(view, /versionsOf == nil \? "Use image" : "Use version"/);
  assert.match(view, /useButton\.isEnabled = chosenID\.flatMap \{ store\.project\.asset\(\$0\) \} != nil && cue != nil && store\.lockedByOther\(cueID\) == nil/);
  assert.match(view, /chosenID = images\[indexPath\.item\]\.id; collectionView\.reloadData\(\)/);
  assert.match(view, /guard requireCurrentContext\(\), let chosenID, store\.project\.asset\(chosenID\) != nil/);
  assert.match(view, /store\.setCueImage\(cueID, imageId: chosenID\)/);
  assert.match(view, /Only this placement changes\. Other uses and discussions stay intact\./);
  assert.match(view, /contentView\.layer\.borderWidth = selected \? 2 : 0\.5; check\.isHidden = !selected/);
  assert.match(view, /private var images: \[ImageAsset\] = \[\]/);
});

test('native tests cover actual selection, repeated enable transitions, deleted choices and versions', async () => {
  const native = await source('apps/catalyst/Tests/ScrivUIKitTests/ImagePickerSelectionAppearanceTests.swift');
  for (const name of ['testDisabledAndEnabledAppearanceRoundTripWithoutChangingActionOrGeometry', 'testActualPickerSelectionEnablesActionWithoutMutatingTheProject', 'testDeletedSelectedAssetDisablesActionAndPreservesRemainingData', 'testVersionPickerUsesTheSameStateAppearanceAndKeepsVersionTitle']) assert.ok(native.includes(name));
  assert.match(native, /--screenshots/);
  assert.doesNotMatch(native, /XCTSkip|URLSession|\.updateConfiguration\(\)/);
});
