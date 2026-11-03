import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
const read = path => readFile(new URL('../' + path, import.meta.url), 'utf8');

test('physical Escape observation is debug-only, opt-in, isolated, and follows UIKit dispatch', async () => {
  const source = await read('apps/catalyst/ScrivUIKit/Shared/ScrivPlaybackKeyboardRouter.swift');
  assert.match(source, /#if DEBUG[\s\S]*?static var onVerificationEscapeEnded: \(\(\) -> Void\)\?[\s\S]*?#endif/);
  const dispatch = source.split('override func sendEvent(_ event: UIEvent) {')[1].split('@objc private func togglePlaybackFromKeyboard')[0];
  const hook = dispatch.split('#if DEBUG')[1].split('#endif')[0];
  assert.ok(dispatch.indexOf('super.sendEvent(event)') < dispatch.indexOf('#if DEBUG'));
  assert.match(hook, /arguments.contains\("--screenshots"\)/);
  assert.match(hook, /environment\["SCRIV_PHYSICAL_ESCAPE_ACCEPTANCE"\] == "1"/);
  assert.match(hook, /press.phase == \.ended && press.key\?\.keyCode == \.keyboardEscape/);
  assert.doesNotMatch(hook, /characters|keyCode.rawValue|print\(/);
});

test('interactive fixture requires observed OS events and never invokes keyboard actions itself', async () => {
  const source = await read('apps/catalyst/Tests/ScrivUIKitTests/UpdatePhysicalEscapeAcceptanceTests.swift');
  assert.match(source, /guard ProcessInfo.processInfo.environment\["SCRIV_PHYSICAL_ESCAPE_ACCEPTANCE"\] == "1" else/);
  assert.match(source, /throw XCTSkip\(/);
  assert.match(source, /arguments.contains\("--screenshots"\)/);
  assert.match(source, /onVerificationEscapeEnded = \{ if window.isKeyWindow \{ escapeEnds \+= 1 \} \}/);
  assert.match(source, /onVerificationEscapeEnded = nil/);
  assert.match(source, /escapeEnds > before/);
  assert.match(source, /XCTAssertEqual\(escapeEnds, 8\)/);
  assert.match(source, /attachment.lifetime = \.keepAlways/);
  for (const phase of ['ready', 'downloading', 'progress', 'verifying', 'saving', 'installing']) assert.ok(source.includes('"' + phase + '"'));
  assert.match(source, /XCTAssertEqual\(alertCancels, 1\)/);
  assert.doesNotMatch(source, /\.perform\(|sendActions\(|pressesBegan\(|checkForUpdates\(|ScrivUpdateCoordinator|WorkspaceStore\(|\.becomeFirstResponder\(/);
});


test('fixture publishes only its own identity and restores the original scene presentation', async () => {
  const source = await read('apps/catalyst/Tests/ScrivUIKitTests/UpdatePhysicalEscapeAcceptanceTests.swift');
  assert.match(source, /let token = UUID\(\)\.uuidString/);
  assert.match(source, /ProcessInfo\.processInfo\.processIdentifier/);
  assert.match(source, /Bundle\.main\.bundleIdentifier/);
  assert.match(source, /Bundle\.main\.bundleURL\.resolvingSymlinksInPath\(\)\.path/);
  assert.match(source, /SCRIV_PHYSICAL_ESCAPE_IDENTITY/);
  assert.match(source, /scene\.title = fixtureTitle/);
  assert.match(source, /scene\.title = previousSceneTitle/);
  assert.match(source, /#if targetEnvironment\(macCatalyst\)[\s\S]*?titlebar\?\.titleVisibility = \.visible[\s\S]*?#endif/);
  assert.match(source, /titlebar\?\.titleVisibility = previousTitleVisibility/);
  const conditionals = [];
  for (const line of source.split('\n')) {
    const opening = line.match(/^#if (.+)$/);
    if (opening) conditionals.push(opening[1]);
    if (/^#endif/.test(line)) conditionals.pop();
    if (/\b(titlebar|previousTitleVisibility)\b/.test(line)) {
      assert.ok(conditionals.includes('targetEnvironment(macCatalyst)'), `Unguarded Catalyst titlebar reference: ${line}`);
    }
  }
  assert.ok(source.indexOf('defer {') < source.indexOf('scene.title = fixtureTitle'));
  assert.ok(source.indexOf('guard ProcessInfo.processInfo.environment') < source.indexOf('scene.title = fixtureTitle'));
  assert.doesNotMatch(source, /NSWorkspace|NSRunningApplication|CGWindowList|Process\(\)|system\(/);
});

test('operator readiness is an explicit visible handshake before the unchanged OS-key steps', async () => {
  const source = await read('apps/catalyst/Tests/ScrivUIKitTests/UpdatePhysicalEscapeAcceptanceTests.swift');
  assert.match(source, /begin\.setTitle\("Begin eight Escape checks"/);
  assert.match(source, /begin\.addAction\(UIAction/);
  assert.match(source, /guard let window, let scene, window\.isKeyWindow && scene\.activationState == \.foregroundActive else/);
  assert.match(source, /armed = true; begin\?\.isEnabled = false/);
  assert.match(source, /settled\(timeout: 300, \{ armed \}\)/);
  assert.match(source, /guard escapeEnds == 0 else/);
  assert.ok(source.indexOf('settled(timeout: 300') < source.indexOf('root.present(update'));
  assert.ok(source.indexOf('SCRIV_PHYSICAL_ESCAPE_ARMED') < source.indexOf('try await waitForEscape('));
  assert.match(source, /settled\(timeout: 90, \{ escapeEnds > before \}\)/);
  assert.match(source, /XCTAssertEqual\(escapeEnds, 8\)/);
  assert.match(source, /"Physical Escape check .*fixtureTitle/);
  assert.match(source, /No physical Escape acceptance was attempted/);
});
