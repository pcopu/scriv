import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
const source = path => readFile(new URL(`../${path}`, import.meta.url), 'utf8');
const viewPath = 'apps/catalyst/ScrivUIKit/Account/ScrivCodexSetupView.swift';
const controllerPath = 'apps/catalyst/ScrivUIKit/Account/ScrivSettingsController.swift';
const runtimePath = 'apps/mac/Sources/ScrivApp/Services/CodexController.swift';

test('one-click sheet retains bounded body, persistent controls and collapsed optional details', async () => {
  const view = await source(viewPath);
  for (const text of ['Connect Codex in one click', 'Check & connect', 'Get Codex ready', 'Codex is ready', 'Sign in to Codex', 'Cancel check']) assert.ok(view.includes(text));
  assert.match(view, /scroll\.topAnchor\.constraint\(equalTo: topRule\.bottomAnchor\)/);
  assert.match(view, /scroll\.bottomAnchor\.constraint\(equalTo: footer\.topAnchor/);
  assert.match(view, /body\.widthAnchor\.constraint\(equalTo: scroll\.frameLayoutGuide\.widthAnchor/);
  assert.match(view, /private var advancedExpanded = false/);
  assert.match(view, /private var pairingExpanded = false/);
  assert.match(view, /stack\.removeArrangedSubview\(child\); child\.removeFromSuperview\(\)/);
  assert.doesNotMatch(view, /Use the Runtime Companion|advancedContent\.isHidden|pairingContent\.isHidden|SwiftUI/);
});
test('saved pairing, protocol readiness and account state remain distinct', async () => {
  const view = await source(viewPath), runtime = await source(runtimePath);
  assert.match(view, /canStart: Bool \{ canEditConnection && paired \}/);
  assert.match(view, /guard connected else \{ return "Not checked yet" \}/);
  assert.match(view, /guard accountChecked else \{ return "Checking existing account…" \}/);
  assert.match(view, /requiresAuthentication \? "Not signed in" : "Not required by this provider"/);
  assert.match(view, /availableModels\.contains\(selectedModel\) \? selectedModel/);
  assert.match(runtime, /requiresAccountAuthentication = readiness\.requiresAuthentication/);
  assert.match(await source("apps/mac/Sources/ScrivCore/CodexConnectionCheck.swift"), /No sign-in conclusion was made/);
});
test('check probes compatible protocol and account without generating or signing in', async () => {
  const runtime = await source(runtimePath);
  const check = runtime.split('func checkAndConnect(')[1].split('func cancelConnectionCheck()')[0];
  assert.match(check, /connectionCheck\.begin\(\)/);
  assert.match(check, /connect\(timeout: \.seconds\(6\)\)/);
  assert.match(check, /bridgePaired && !receivedProtocolReply/);
  assert.doesNotMatch(check, /signIn\(|generate\(|turn\/start|account\/login\/start/);
  assert.match(runtime, /CodexAccountReadiness\.validateInitialize\(hello\)/);
  assert.match(runtime, /"initialized"/);
  assert.match(runtime, /"account\/read", \.object\(\["refreshToken":\.bool\(false\)\]\)/);
});
test('cancel, duplicate check, dismissal and stale responses are fenced', async () => {
  const runtime = await source(runtimePath), controller = await source(controllerPath);
  assert.match(runtime, /guard connectionCheck\.accepts\(attempt\), !Task\.isCancelled else/);
  assert.match(runtime, /connectionCheck\.cancel\(\); disconnect\(cancelCheck: false\)/);
  assert.match(controller, /setup\.onDone = .*cancelConnectionCheck\(\).*dismiss\(animated: true\)/);
  assert.match(controller, /presentationControllerDidDismiss.*cancelConnectionCheck\(\)/);
  assert.match(controller, /setup\.onCancelCheck/);
});
test('copy-only official commands never run inside the app or use global listeners', async () => {
  const view = await source(viewPath), core = await source('apps/mac/Sources/ScrivCore/CodexConnectionCheck.swift');
  assert.match(view, /UIPasteboard\.general\.string = command/);
  assert.match(core, /curl -fsSL https:\/\/chatgpt\.com\/codex\/install\.sh \| sh/);
  assert.match(core, /codex app-server --listen ws:\/\/127\.0\.0\.1:4500/);
  assert.match(view, /WebSocket mode is experimental/);
  assert.doesNotMatch(view, /Process\(|URLSession|generateImage|\.start\(|\.connect\(|importRuntimePairing/);
});
test('optional advanced routes preserve explicit private pairing and ownership', async () => {
  const controller = await source(controllerPath), view = await source(viewPath);
  for (const method of ['openRuntimeCompanion()', 'start()', 'connect()', 'importRuntimePairing(from: url)', 'useExistingGenerationFolder(url)', 'rotateRuntimePairing()', 'forgetRuntimePairing()']) assert.ok(controller.includes(method));
  assert.match(controller, /UIDocumentPickerViewController\(forOpeningContentTypes: \[\.item\], asCopy: false\)/);
  assert.match(view, /managed \? "Stop" : "Disconnect"/);
  assert.match(view, /Check & connect checks only this address, not every app or port/);
  assert.match(controller, /if !executable\.isFirstResponder \{ executable\.text = controller\.executablePath \}/);
});
test('native regression coverage retains route, optical footer, compact state and field identity gates', async () => {
  const native = await source('apps/catalyst/Tests/ScrivUIKitTests/CodexSetupUIKitTests.swift');
  assert.equal((native.match(/func test/g) ?? []).length, 16);
  for (const name of ['testInitialViewHasOneCheckAndCollapsedOptionalDetails', 'testLoadResizeAndExpandedDetailsKeepHeaderAndFooterOutsideScroll', 'testRepeatedDisclosureAndStateUpdatesRetainConnectionFieldDrafts', 'testCancelRetryAndMissingCommandsDoNotDispatchAnInstall', 'testActualCodexRouteHidesChromeBeforeSizingAndPreservesSettings', 'testInstalledFooterLinksKeepOpticalGapAndStackWithoutLosingTitlesOrActions']) assert.ok(native.includes(name));
  assert.doesNotMatch(native, /MacRuntimeBridge\(|XCTSkip/);
});
test('synthetic native verification does not query the saved pairing capability', async () => {
  const runtime = await source(runtimePath);
  assert.match(runtime, /@Published private\(set\) var bridgePaired = false/);
  assert.equal((runtime.match(/MacRuntimeBridge\.isPaired/g) ?? []).length, 1);
  assert.match(runtime, /if !verification \{ bridgePaired = MacRuntimeBridge\.isPaired \}/);
});
test('footer keeps its native optical-spacing correction and normal Settings links the same flow', async () => {
  const view = await source(viewPath), controller = await source(controllerPath);
  assert.match(view, /ScrivCodexFooterLinks\(history: jobs, jobs: history\)/);
  assert.match(view, /addArrangedSubview\(trailingSpace\)/);
  assert.match(view, /spacing = next == \.vertical \? 18 : 48/);
  assert.match(controller, /self\?\.show\(\.codex\)/);
  assert.match(controller, /navigationController\?\.setNavigationBarHidden\(previousNavigationBarHidden, animated: false\)/);
});
