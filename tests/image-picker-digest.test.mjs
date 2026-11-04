import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
const read = path => readFile(new URL(`../${path}`, import.meta.url), 'utf8');
function requiresDigest(text) {
  assert.match(text, /picture\.configure\(url: url, title: UIKitImageContext\.title\(imageID: image\.id, project: store\.project\), missingText: "Not on this Mac", expectedDigest: image\.sha256\)/);
}

test('image picker cards bind their decoded bytes to the labelled asset digest', async () => {
  const text = await read('apps/catalyst/ScrivUIKit/Images/ImagePickerViewController.swift');
  requiresDigest(text);
  assert.throws(() => requiresDigest(text.replace(', expectedDigest: image.sha256', '')), /expectedDigest/);
  assert.match(text, /versionsOf\.map \{ ProjectEditing\.imageVersions/);
  assert.match(text, /cell\.configure\(image: image, store: store, selected: chosenID == image\.id\)/);
});

test('picker delegates verification and retry to the existing asynchronous image loader', async () => {
  const text = await read('apps/catalyst/ScrivUIKit/Images/ImagePickerViewController.swift');
  assert.doesNotMatch(text, /Data\(contentsOf:|UIImage\(contentsOfFile:|UIImage\(data:|Task\.detached/);
  assert.match(text, /store\.setCueImage\(cueID, imageId: chosenID\)/);
  const loader = await read('apps/catalyst/ScrivUIKit/Images/UIKitAssetImageView.swift');
  assert.match(loader, /expected == nil \|\| ScrivDigest\.sha256\(bytes\) == expected/);
  assert.match(loader, /let cacheDigest: String = currentDigest \?\? "unverified"/);
});

test('native picker regression covers mismatched bytes, cache separation, Retry and missing assets', async () => {
  const text = await read('apps/catalyst/Tests/ScrivUIKitTests/ImagePickerDigestTests.swift');
  for (const name of [
    'testChooseImageAndVersionCardsRejectChangedBytesEvenWithAnUnverifiedCacheEntry',
    'testRetryRecoversTheExactImageWithoutChangingProjectOrRecoveredBytes',
    'testMissingAssetStaysAnEmptyPlaceholderWithoutChangingSelection'
  ]) assert.ok(text.includes(`func ${name}()`));
  assert.match(text, /\[nil, asset\.id\] as \[String\?\]/);
  assert.match(text, /XCTAssertEqual\(picture\.loadPhase, \.failed/);
  assert.match(text, /retry\.sendActions\(for: \.touchUpInside\)/);
  assert.match(text, /XCTAssertEqual\(picture\.loadedDigest, asset\.sha256\)/);
  assert.match(text, /XCTAssertEqual\(store\.project, original/);
  assert.match(text, /arguments\.contains\("--screenshots"\)/);
  assert.match(text, /environment\["SCRIV_VERIFICATION_ROOT"\] == nil/);
  assert.match(text, /scratch\.lastPathComponent\.hasPrefix\("ScrivVerification-"\)/);
  assert.match(text, /scratch\.deletingLastPathComponent\(\)\.standardizedFileURL == FileManager\.default\.temporaryDirectory\.standardizedFileURL/);
  assert.doesNotMatch(text, /setCueImage\(|\.useSelection\(/);
});
