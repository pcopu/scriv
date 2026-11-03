import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
const source = path => readFile(new URL(`../${path}`, import.meta.url), 'utf8');
const viewPath = 'apps/catalyst/ScrivUIKit/Account/ScrivCodexSetupView.swift';
const controllerPath = 'apps/catalyst/ScrivUIKit/Account/ScrivSettingsController.swift';
const runtimePath = 'apps/mac/Sources/ScrivApp/Services/CodexController.swift';

test('compact popup keeps only everyday actions and sends advanced setup to Settings', async () => {
  const view = await source(viewPath);
  for (const text of ['Connect', 'Cancel connection', 'Advanced…', 'Installation help', 'Manual connection']) assert.ok(view.includes(text));
  assert.match(view, /scroll\.topAnchor\.constraint\(equalTo: header\.bottomAnchor\)/);
  assert.match(view, /scroll\.bottomAnchor\.constraint\(equalTo: footer\.topAnchor\)/);
  assert.match(view, /if surface == \.settings \{ buildSettings\(\) \}/);
  assert.match(view, /self\?\.onAdvanced\?\(\)/);
  assert.match(view, /private var pairingExpanded = false/);
  assert.doesNotMatch(view, /Connect Codex in one click|Get Codex ready|advancedExpanded|SwiftUI/);
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
  assert.doesNotMatch(check, /endpointURL\(|\bconnect\(/);
  assert.match(check, /if let prepareLocalRuntime/);
  assert.match(check, /else if bridgePaired/);
  assert.doesNotMatch(check, /signIn\(|generate\(|turn\/start|account\/login\/start/);
  assert.match(runtime, /CodexAccountReadiness\.validateInitialize\(hello\)/);
  assert.match(runtime, /"initialized"/);
  assert.match(runtime, /"account\/read", \.object\(\["refreshToken":\.bool\(false\)\]\)/);
});
test('cancel, duplicate check, dismissal and stale responses are fenced', async () => {
  const runtime = await source(runtimePath), controller = await source(controllerPath);
  assert.match(runtime, /guard connectionCheck\.accepts\(attempt\), !Task\.isCancelled else/);
  assert.match(runtime, /connectionCheck\.cancel\(\); disconnect\(cancelCheck: false\)/);
  assert.match(controller, /setup\.onDone = .*cancelPendingConnectionCheck\(\).*dismiss\(animated: true\)/);
  assert.match(controller, /presentationControllerDidDismiss.*cancelPendingConnectionCheck\(\)/);
  assert.match(controller, /store\.codex\.connectionCheck\.accepts\(connectionAttempt\)/);
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
  assert.match(view, /Connect needs no server address/);
  assert.match(controller, /if !executable\.isFirstResponder \{ executable\.text = controller\.executablePath \}/);
});
test('native regression coverage checks controls, state, layout and read-only navigation', async () => {
  const native = await source('apps/catalyst/Tests/ScrivUIKitTests/CodexSetupUIKitTests.swift');
  for (const name of ['testPopupHasOneConnectAndNoManualSetup', 'testPopupResizingKeepsAdvancedReachable', 'testSettingsRefreshRetainsFieldIdentityAndDraft', 'testAdvancedOnlyDispatchesNavigation', 'testModelsAndAccountStayTruthful']) assert.ok(native.includes(name));
  assert.doesNotMatch(native, /MacRuntimeBridge\(|XCTSkip/);
});
test('synthetic native verification does not query the saved pairing capability', async () => {
  const runtime = await source(runtimePath);
  assert.match(runtime, /@Published private\(set\) var bridgePaired = false/);
  assert.equal((runtime.match(/MacRuntimeBridge\.isPaired/g) ?? []).length, 1);
  assert.match(runtime, /if !verification \{ bridgePaired = MacRuntimeBridge\.isPaired \}/);
});
test('Settings scene teardown cancels only the controller-owned pending connection', async () => {
  const controller = await source(controllerPath);
  const coordinator = await source('apps/catalyst/ScrivUIKit/Account/ScrivSettingsWindowCoordinator.swift');
  const panel = await source('apps/catalyst/ScrivUIKit/Account/ScrivSettingsPanelController.swift');
  assert.match(controller, /guard let connectionTask else \{ return \}/);
  assert.match(controller, /try Task\.checkCancellation\(\)/);
  assert.match(coordinator, /func sceneDidDisconnect[\s\S]*cancelPendingConnectionCheck\(\)/);
  assert.match(panel, /panes\[selectedPane\]\?\.cancelPendingConnectionCheck\(\)/);
});
