import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
const source = path => readFile(new URL(`../${path}`, import.meta.url), 'utf8');
const path = 'apps/catalyst/ScrivUIKit/Account/ScrivCodexSetupView.swift';

test('the 584pt Codex reference sheet keeps its 524pt footer on one row', async () => {
  const view = await source(path);
  assert.match(view, /preferredSheetSize = CGSize\(width: 584, height: 614\)/);
  assert.match(view, /bounds\.width < 440 \? \.vertical : \.horizontal/);
  assert.doesNotMatch(view, /bounds\.width < 560/);
  assert.match(view, /history\.contentHorizontalAlignment = \.leading; jobs\.contentHorizontalAlignment = \.leading/);
  assert.match(view, /spacing = next == \.vertical \? 18 : 48/);
});

test('help section changes reset the viewport but ordinary state refreshes preserve it', async () => {
  const view = await source(path);
  assert.match(view, /previousPhase != phase \|\| previouslyShowingInstallation != showingInstallation/);
  assert.match(view, /pendingScrollToTop = true; pendingRevealTarget = nil/);
  assert.match(view, /scroll\.setContentOffset\(CGPoint\(x: 0, y: -scroll\.adjustedContentInset\.top\), animated: false\)/);
  assert.match(view, /explanation\.isHidden = showingInstallation \|\|/);
  assert.match(view, /scroll\.contentInsetAdjustmentBehavior = \.never/);
});

test('expanded connection details reveal the saved-address field without remounting it', async () => {
  const view = await source(path);
  assert.match(view, /revealAfterLayout\(self\.advancedExpanded \? self\.endpoint : self\.controls\["advanced"\]\)/);
  assert.match(view, /private weak var pendingRevealTarget: UIView\?/);
  assert.match(view, /target\.isDescendant\(of: scroll\)/);
  assert.match(view, /scroll\.scrollRectToVisible\(rect, animated: false\)/);
  assert.match(view, /The installation commands use 127\.0\.0\.1:4500; match that address here/);
});

test('new native regressions cover default, narrow, repeated, disclosure and help navigation', async () => {
  const native = await source('apps/catalyst/Tests/ScrivUIKitTests/CodexNativeModalParityTests.swift');
  for (const name of ['testReferenceWidthFooterDoesNotConsumeAnExtraBodyRow', 'testOpeningHelpAfterScrollingRevealsHeadingAndDoesNotStartRuntime', 'testOpeningAdvancedRevealsAddressAndRepeatedRefreshKeepsDraftAndViewport', 'testNewConnectionPhaseReturnsToHeadingWithoutChangingFields']) assert.ok(native.includes(name));
  assert.doesNotMatch(native, /XCTSkip|MacRuntimeBridge\(|URLSession/);
  const existing = await source('apps/catalyst/Tests/ScrivUIKitTests/CodexSetupUIKitTests.swift');
  assert.match(existing, /XCTAssertEqual\(font\.pointSize, 14, accuracy: 0\.1\)/);
  assert.match(existing, /The desktop .* reference shows every action without scrolling\./);
});
