import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

// Source contracts supplement the native policy regression; they do not prove
// physical Escape delivery or an in-flight durable save on macOS.
test('sheet Escape honors the effective navigation or direct dismissal policy', async () => {
  const source = await readFile(new URL('../apps/catalyst/ScrivUIKit/Shared/ScrivScreenController.swift', import.meta.url), 'utf8');
  const handler = source.split('@objc func scrivEscapeSheet() {')[1].split('func closeFromEscape()')[0];
  assert.match(handler, /guard !\(navigationController \?\? self\)\.isModalInPresentation,/);
  assert.match(handler, /presentedViewController == nil else \{ return \}/);
  assert.match(handler, /closeFromEscape\(\)/);
  const review = await readFile(new URL('../apps/catalyst/ScrivUIKit/Characters/CharacterImageReviewController.swift', import.meta.url), 'utf8');
  assert.match(review, /isModalInPresentation = value/);
  const native = await readFile(new URL('../apps/catalyst/Tests/ScrivUIKitTests/CharacterImageReviewTests.swift', import.meta.url), 'utf8');
  const regression = native.split('func testNavigationWrappedSheetEscapeHonorsBothChildAndContainerSaveLocks()')[1].split('func testDerivedCropLeavesOriginalBytesUntouchedAndCachesByRegion()')[0];
  assert.match(regression, /for lockChild in \[true, false\]/);
  assert.match(regression, /XCTAssertTrue\(navigation\.isModalInPresentation,/);
  assert.match(regression, /XCTAssertEqual\(screen\.closeCount, 0,/);
  assert.match(regression, /XCTAssertEqual\(screen\.closeCount, 1,/);
  assert.match(regression, /XCTAssertEqual\(unwrapped\.closeCount, 0\)/);
  assert.match(regression, /XCTAssertEqual\(unwrapped\.closeCount, 1\)/);
});
