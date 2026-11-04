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
  const policy = await read('apps/mac/Sources/ScrivCore/RuntimeBridgeBootstrap.swift');
  assert.match(guided, /sessionGrant\.importBootstrapped\(incoming, ownerUID: geteuid\(\), readPersistent: persistentPairing\)/);
  assert.match(policy, /validateImport\(existing: existing/);
  assert.match(guided, /errSecDuplicateItem/);
  assert.match(policy, /validateImport\(existing: raced/);
  assert.match(guided, /kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly/);
  assert.ok(!guided.includes('SecItemUpdate')); assert.ok(!guided.includes('SecItemDelete'));
  assert.match(guided, /if status == errSecItemNotFound \{ return nil \}/);
});
test('only an absent Keychain entitlement permits a verified in-memory grant', async () => {
  const bridge = await read('apps/catalyst/MacRuntimeBridge/MacRuntimeBridge.swift');
  const guided = bridge.split('static func importBootstrappedPairing')[1].split('private static var pairingQuery')[0];
  const policy = (await read('apps/mac/Sources/ScrivCore/RuntimeBridgeBootstrap.swift')).split('public mutating func importBootstrapped')[1].split('public mutating func retain')[0];
  assert.match(guided, /case errSecMissingEntitlement: return \.missingEntitlement/);
  assert.match(guided, /default: throw/);
  assert.match(policy, /let existing = try resolve\(persistent: readPersistent\(\), ownerUID: ownerUID\)[\s\S]*?validateImport\(existing: existing[\s\S]*?if existing != nil \{ return \}/);
  assert.match(policy, /case \.missingEntitlement:[\s\S]*?let raced = try readPersistent\(\)[\s\S]*?validateImport\(existing: raced[\s\S]*?if raced == nil \{ try retain\(incoming, ownerUID: ownerUID\) \}/);
  assert.ok(!guided.includes('try?'), 'A failed read must never be treated as an absent grant');
  assert.ok(!policy.includes('try?'));
  assert.equal(bridge.match(/sessionGrant\.importBootstrapped\(/g)?.length, 1, 'Only authenticated create-only bootstrap may retain an in-memory grant');
  assert.match(bridge, /static func forgetPairing\(\) throws \{\s*sessionGrant\.reset\(\)/);
});
test('forget clears session authority and reports persistent deletion failures', async () => {
  const bridge = await read('apps/catalyst/MacRuntimeBridge/MacRuntimeBridge.swift');
  const forget = bridge.split('static func forgetPairing()')[1].split('private static func loadPairing()')[0];
  assert.match(forget, /sessionGrant\.reset\(\)[\s\S]*?let status = SecItemDelete/);
  assert.match(forget, /status == errSecMissingEntitlement, try persistentPairing\(\) == nil/);
  assert.match(forget, /guard status == errSecSuccess \|\| status == errSecItemNotFound else \{\s*throw/);
  const controller = await read('apps/mac/Sources/ScrivApp/Services/CodexController.swift');
  const action = controller.split('func forgetRuntimePairing()')[1].split('func openRuntimeCompanion()')[0];
  assert.match(action, /try MacRuntimeBridge\.forgetPairing\(\)[\s\S]*?bridgePaired = false/);
  assert.match(action, /catch \{ lastError = error.localizedDescription \}/);
});
test('session grants never hide locked, unreadable, invalid or conflicting persistent grants', async () => {
  const bridge = await read('apps/catalyst/MacRuntimeBridge/MacRuntimeBridge.swift');
  const resolve = bridge.split('static func savedPairing()')[1].split('private static func persistentPairing()')[0];
  assert.match(resolve, /let persistent = try persistentPairing\(\)[\s\S]*?return try sessionGrant\.resolve\(persistent: persistent, ownerUID: geteuid\(\)\)/);
  const persistent = bridge.split('private static func persistentPairing()')[1].split('static func forgetPairing()')[0];
  assert.match(persistent, /if status == errSecItemNotFound \{ return nil \}/);
  assert.match(persistent, /guard status == errSecSuccess, let data = raw as\? Data, data.count <= 4096 else \{ throw/);
  assert.match(persistent, /try pairing.validate\(ownerUID: geteuid\(\)\)/);
  assert.ok(!persistent.includes('errSecMissingEntitlement'));
  assert.ok(!persistent.includes('sessionGrant'));
  assert.ok(!persistent.includes('try?'));
  const load = bridge.split('private static func loadPairing()')[1].split('static func openCompanion()')[0];
  assert.match(load, /guard let pairing = try savedPairing\(\)/);
  assert.ok(!bridge.includes('UserDefaults'), 'Pairing must not fall back to plaintext preferences');
});
test('manual replacement resets process-local authority only after Keychain save succeeds', async () => {
  const bridge = await read('apps/catalyst/MacRuntimeBridge/MacRuntimeBridge.swift');
  const manual = bridge.split('static func importPairing(from url: URL)')[1].split('static func importBootstrappedPairing')[0];
  assert.match(manual, /guard result == errSecSuccess else \{ throw[\s\S]*?sessionGrant\.reset\(\)/);
  assert.ok(!manual.includes('sessionGrant.retain'));
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
  assert.ok(coordinator.includes('guard userApproved else'));
  assert.ok(coordinator.indexOf('guard userApproved else') < coordinator.indexOf('let native = try makeAdapter'));
  assert.ok(!coordinator.includes('UIAlertController'), 'The Connect action authorizes startup without a second prompt');
  const settings = await read('apps/catalyst/ScrivUIKit/Account/ScrivSettingsController.swift');
  assert.match(settings, /try await bootstrap\.prepare\(userApproved: true\)/);
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
