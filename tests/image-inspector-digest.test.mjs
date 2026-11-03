import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
const read = path => readFile(new URL(`../${path}`, import.meta.url), 'utf8');
function requiresBindings(text) {
  assert.match(text, /picture\.configure\(url: url, title: name, fill: false, expectedDigest: image\.sha256\)/);
  assert.match(text, /picture\.configure\(url: store\.assetURL\(image\), title: "Image being tagged", fill: false, missingText: "Not on this Mac", expectedDigest: image\.sha256\)/);
  assert.match(text, /let portraitAsset = store\.project\.asset\(character\.portraitImageId\)/);
  assert.match(text, /portrait\.configure\(url: portraitAsset\.flatMap \{ store\.assetURL\(\$0\) \}, title: character\.name, missingText: String\(character\.name\.prefix\(1\)\), expectedDigest: portraitAsset\?\.sha256\)/);
}

test('inspector and tag editor bind each displayed image to its own digest', async () => {
  const text = await read('apps/catalyst/ScrivUIKit/Images/ImageInspectorControllers.swift'); requiresBindings(text);
  assert.throws(() => requiresBindings(text.replaceAll(', expectedDigest: image.sha256', '')), /expectedDigest/);
  assert.throws(() => requiresBindings(text.replace('expectedDigest: portraitAsset?.sha256', 'expectedDigest: image.sha256')), /portraitAsset/);
});

test('image inspection retains existing context, tag, placement and shared-loader behavior', async () => {
  const text = await read('apps/catalyst/ScrivUIKit/Images/ImageInspectorControllers.swift');
  assert.doesNotMatch(text, /Data\(contentsOf:|UIImage\(data:|Task\.detached/);
  assert.match(text, /UIKitImageContext\.placement\(imageID: imageID, cueID: cueID, project: store\.project\)/);
  assert.match(text, /self\.store\.setCharacterTags\(imageId: current\.id, characterIds: tags\)/);
  assert.match(text, /guard let self, self\.requireCurrentContext\(\), let current = self\.store\.project\.asset\(self\.imageID\)/);
});

test('native inspector tests use distinct image/portrait identities and real Retry without mutation', async () => {
  const text = await read('apps/catalyst/Tests/ScrivUIKitTests/ImageInspectorDigestTests.swift');
  for (const name of ['testInspectRejectsChangedOriginalAndRetryLoadsTheLabelledVersion', 'testTagEditorVerifiesMainImageAndPortraitAgainstTheirOwnDistinctDigests', 'testMissingTagImageAndPortraitKeepTheirExistingPlaceholders']) {
    assert.ok(text.includes(`func ${name}()`));
  }
  assert.match(text, /XCTAssertNotEqual\(main\.sha256, portraitAsset\.sha256\)/);
  assert.match(text, /XCTAssertEqual\(portrait\.loadedDigest, portraitAsset\.sha256\)/);
  assert.match(text, /XCTAssertEqual\(target\.loadedDigest, main\.sha256\)/);
  assert.match(text, /button\.sendActions\(for: \.touchUpInside\)/);
  assert.match(text, /XCTAssertEqual\(store\.project, original/);
  assert.match(text, /arguments\.contains\("--screenshots"\)/);
  assert.match(text, /environment\["SCRIV_VERIFICATION_ROOT"\] == nil/);
  assert.match(text, /scratch\.lastPathComponent\.hasPrefix\("ScrivVerification-"\)/);
  assert.match(text, /scratch\.deletingLastPathComponent\(\)\.standardizedFileURL == FileManager\.default\.temporaryDirectory\.standardizedFileURL/);
  assert.doesNotMatch(text, /setCharacterTags\(|\.downloadImage\(/);
});
