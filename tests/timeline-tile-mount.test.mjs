import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
const read = path => readFile(new URL(`../${path}`, import.meta.url), 'utf8');
const source = 'apps/catalyst/ScrivUIKit/Images/LayerTimelineViewController.swift';
// These statements contain no string literals. Strip line comments before
// checking them so text swallowed by a trailing // cannot satisfy this guard.
const codeLines = text => text.split('\n').map(line => line.split('//')[0]).join('\n');
function requiresMountedTiles(text) {
  const code = codeLines(text);
  assert.match(code, /canvas\.addSubview\(tile\); imageButtons\[cue\.id\] = tile/);
  const mount = code.indexOf('canvas.addSubview(tile); imageButtons[cue.id] = tile');
  assert.ok(mount > code.indexOf('for row in imageRows {'));
  assert.ok(mount < code.indexOf('installTimingDrag(surface: tile'));
}

test('timeline cue tiles are mounted and registered as executable statements', async () => {
  const text = await read(source); requiresMountedTiles(text);
  const broken = text.replace('canvas.addSubview(tile); imageButtons[cue.id] = tile', '// canvas.addSubview(tile); imageButtons[cue.id] = tile');
  assert.throws(() => requiresMountedTiles(broken), /canvas/);
  assert.throws(() => requiresMountedTiles(text.replace('imageButtons[cue.id] = tile', '// imageButtons[cue.id] = tile')), /canvas/);
});

test('timeline previews bind the same resolved cue asset URL and digest', async () => {
  const text = await read(source);
  assert.match(text, /let asset = store\.project\.asset\(cue\.imageId\)/);
  const binding = 'image.configure(url: asset.flatMap { store.assetURL($0) }, title: cue.label, missingText: "No local image", expectedDigest: asset?.sha256)';
  assert.ok(text.includes(binding)); assert.ok(!text.replace(', expectedDigest: asset?.sha256', '').includes(binding));
  assert.doesNotMatch(text, /Data\(contentsOf:|UIImage\(data:|Task\.detached/);
});

test('timeline keeps reuse, navigation fences, secondary menus and drag ownership', async () => {
  const text = await read(source);
  assert.match(text, /if signature != next, !dragInProgress \{ signature = next; rebuild\(\) \}/);
  assert.match(text, /imageButtons\.removeAll\(\)/);
  assert.match(text, /canvas\.subviews\.forEach \{ \$0\.removeFromSuperview\(\) \}/);
  assert.match(text, /for \(id, button\) in imageButtons/);
  assert.match(text, /button\.layer\.borderWidth = id == store\.selectedCueID \? 2\.5 : id == store\.currentCue\?\.id \? 1 : 0/);
  assert.match(text, /guard let self, self\.store\.navigationContext == navigation else \{ return \}/);
  assert.match(text, /ScrivSecondaryMenu\.set\(UIMenu\(children: pictureActions\(cue\)\), on: tile\)/);
  assert.match(text, /installTimingDrag\(surface: tile, tile: tile, cueID: cue\.id, mode: \.offset/);
  assert.match(text, /installTimingDrag\(surface: coverageGrip, tile: tile, cueID: cue\.id, mode: \.coverage/);
});

test('native view tests cover mounting, live registration, repeated refresh, rebuilding and verified bytes', async () => {
  const text = await read('apps/catalyst/Tests/ScrivUIKitTests/TimelineTileMountTests.swift');
  for (const name of [
    'testEverySceneCueMountsItsTileWithImageMenuAndDragRecognizer',
    'testOverlappingCuesMountInSeparateLanesOnTheSameCanvas',
    'testRegisteredTilesTrackSelectionAndPlayheadWithoutReplacementOrDuplicates',
    'testMountedTileActionPausesAndSeeksWithoutChangingTheProject',
    'testZoomAndSceneRebuildRemoveOldTilesAndRegisterOnlyTheNewScene',
    'testMountedImageRejectsWrongCachedBytesAndRebuildLoadsItsExactDigest',
    'testMissingAndUnassignedImagesStillMountSelectablePlaceholderTiles',
  ]) assert.ok(text.includes(`func ${name}()`));
  assert.match(text, /for expanded in \[false, true\]/);
  assert.match(text, /Set\(tiles\(in: controller\.view\)\.map\(ObjectIdentifier\.init\)\), identities/);
  assert.match(text, /XCTAssertTrue\(old\.allSatisfy \{ \$0\.superview == nil \}\)/);
  assert.match(text, /XCTAssertEqual\(rebuilt\.loadedDigest, main\.sha256\)/);
  assert.match(text, /XCTAssertEqual\(otherPicture\.loadedDigest, other\.sha256\)/);
  assert.match(text, /XCTAssertEqual\(store\.project, original\)/);
  assert.match(text, /arguments\.contains\("--screenshots"\)/);
  assert.match(text, /environment\["SCRIV_VERIFICATION_ROOT"\] == nil/);
  assert.match(text, /scratch\.lastPathComponent\.hasPrefix\("ScrivVerification-"\)/);
  assert.match(text, /scratch\.deletingLastPathComponent\(\)\.standardizedFileURL == FileManager\.default\.temporaryDirectory\.standardizedFileURL/);
  assert.doesNotMatch(text, /\.present\(|\.downloadImage\(|\.generateImage\(|\.setCueAnchor\(|\.setCueDuration\(|\.beginEdit\(/);
});
