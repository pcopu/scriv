import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
const read = p => readFile(new URL('../' + p, import.meta.url), 'utf8');
test('native adapter and XPC are separate macOS targets; Catalyst remains sandboxed', async () => {
  const generator = await read('scripts/generate-catalyst-project.py');
  assert.match(generator, /ScrivRuntimeBootstrapClient\.swift/);
  assert.match(generator, /com\.apple\.product-type\.xpc-service/);
  assert.match(generator, /CONTENTS_FOLDER_PATH\)\/XPCServices/);
  assert.match(generator, /'ENABLE_APP_SANDBOX':'NO'/); // explicit helper-only authority
  const entitlements = await read('apps/catalyst/ScrivUIKit.entitlements');
  assert.match(entitlements, /<key>com.apple.security.app-sandbox<\/key>\s*<true\/>/);
  assert.ok(!entitlements.includes('disable-library-validation'));
  const ui = await read('apps/catalyst/ScrivUIKit/Account/ScrivRuntimeBootstrapCoordinator.swift');
  assert.ok(!ui.includes('NSXPCConnection')); assert.ok(!ui.includes('import AppKit'));
  assert.match(ui, /NSClassFromString\("ScrivRuntimeBootstrapAdapterImpl"\)/);
});
test('guided pairing creates only; inaccessible or raced grants never overwrite', async () => {
  const bridge = await read('apps/catalyst/MacRuntimeBridge/MacRuntimeBridge.swift');
  const guided = bridge.split('static func importBootstrappedPairing')[1].split('static func forgetPairing')[0];
  assert.match(guided, /validateImport\(existing: existing/);
  assert.match(guided, /errSecDuplicateItem/);
  assert.match(guided, /validateImport\(existing: raced/);
  assert.match(guided, /kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly/);
  assert.ok(!guided.includes('SecItemUpdate')); assert.ok(!guided.includes('SecItemDelete'));
  assert.match(guided, /if status == errSecItemNotFound \{ return nil \}/);
});
test('only an absent Keychain entitlement permits a verified in-memory grant', async () => {
  const bridge = await read('apps/catalyst/MacRuntimeBridge/MacRuntimeBridge.swift');
  assert.match(bridge, /else if status == errSecMissingEntitlement \{[\s\S]*?sessionGrant\.retain\(incoming, ownerUID: geteuid\(\)\)/);
  assert.match(bridge, /sessionGrant\.resolve\(persistent: nil, ownerUID: geteuid\(\)\)/);
  assert.match(bridge, /static func forgetPairing\(\) \{\s*sessionGrant\.reset\(\)/);
});
test('guided connection owns XPC lifetime and does not open standalone companion', async () => {
  const controller = await read('apps/mac/Sources/ScrivApp/Services/CodexController.swift');
  assert.ok(controller.includes('if let prepareLocalRuntime'), 'Check & connect must prepare the local helper directly');
  const guided = controller.split('if let prepareLocalRuntime')[1].split('} else if')[0];
  assert.match(guided, /try await prepareLocalRuntime\(\)/);
  assert.match(guided, /start\(preservingBundledRuntime: true\)/);
  assert.ok(!guided.includes('openRuntimeCompanion'));
  assert.match(controller, /owned.stop\(completion: release\)/);
  const coordinator = await read('apps/catalyst/ScrivUIKit/Account/ScrivRuntimeBootstrapCoordinator.swift');
  assert.ok(coordinator.indexOf('guard allowed else') < coordinator.indexOf('let native = try makeAdapter'));
  assert.ok(coordinator.indexOf('guard !cancelled else', coordinator.indexOf('let bytes:')) < coordinator.indexOf('try savePairing(bytes)'));
  assert.match(coordinator, /pending\?\.resume\(throwing: CancellationError\(\)\)/);
});
test('release verifies exact signed helper and adapter; no development identity bypass', async () => {
  const release = await read('updates/scripts/release.py');
  assert.match(release, /Contents\/XPCServices\/com.scriv.runtime-companion.bootstrap.xpc/);
  assert.match(release, /nested_rule/);
  const client = await read('apps/runtime-bridge/Integration/ScrivRuntimeBootstrapClient.swift');
  const service = await read('apps/runtime-bridge/Sources/ScrivRuntimeCompanion/RuntimeBootstrapXPC.swift');
  for (const text of [client, service]) {
    assert.match(text, /setCodeSigningRequirement/); assert.ok(!text.includes('get-task-allow'));
    assert.ok(!text.includes('SCRIV_ALLOW_UNSIGNED'));
  }
});
