import test from 'node:test'; import assert from 'node:assert/strict'; import { readFile } from 'node:fs/promises';
const read = p => readFile(new URL('../' + p, import.meta.url), 'utf8');
test('Catalyst uses Foundation ABI while native bundle owns Sparkle', async () => {
  const coordinator = await read('apps/catalyst/ScrivUIKit/Updates/ScrivUpdateCoordinator.swift');
  assert.ok(!coordinator.includes('import Sparkle')); assert.ok(!coordinator.includes('import AppKit'));
  const plugin = await read('apps/catalyst/UpdatePlugin/ScrivSparklePlugin.m');
  assert.ok(plugin.includes('#import <Sparkle/Sparkle.h>')); assert.ok(plugin.includes('SecStaticCodeCheckValidity'));
  assert.ok(plugin.includes('SPUUserUpdateChoiceSkip')); assert.ok(plugin.includes('generation != self.eventGeneration'));
  assert.ok(plugin.includes('prepareAndReply'));
});
test('project keeps stable bundle and module identity, user-facing name is Scriv', async () => {
  const generator = await read('scripts/generate-catalyst-project.py');
  assert.ok(generator.includes("PRODUCT_NAME='Scriv',PRODUCT_MODULE_NAME='ScrivUIKit'"));
  assert.ok(generator.includes("PRODUCT_BUNDLE_IDENTIFIER='app.scriv.uikit'"));
  assert.ok(generator.includes("'version':'2.10.1'"));
  assert.ok(generator.includes("'SDKROOT':'macosx','SUPPORTED_PLATFORMS':'macosx','SUPPORTS_MACCATALYST':'NO'"));
});
test('update fence verifies persisted project and pending journal without deleting user data', async () => {
  const source = await read('apps/mac/Sources/ScrivApp/Services/WorkspaceStore.swift');
  const fence = source.split('func prepareForApplicationUpdate()')[1].split('#endif')[0];
  assert.ok(fence.includes('pendingSaveJournal().load(package: package).isEmpty'));
  assert.ok(fence.includes('saved == snapshot')); assert.ok(fence.includes('await commitTask?.value'));
  assert.ok(!fence.includes('removeItem')); assert.ok(!fence.includes('discardGenerationPrompt()'));
});
test('generated update policy has no unsigned-feed expiry fallback and no silent install', async () => {
  const plist = await read('apps/catalyst/Info.plist');
  for (const key of ['SURequireSignedFeed', 'SUVerifyUpdateBeforeExtraction', 'SUEnableInstallerLauncherService']) assert.match(plist, new RegExp(`<key>${key}</key>\\s*<true/>`));
  for (const key of ['SUEnableAutomaticChecks', 'SUAutomaticallyUpdate', 'SUAllowsAutomaticUpdates', 'SUEnableSystemProfiling']) assert.match(plist, new RegExp(`<key>${key}</key>\\s*<false/>`));
  assert.match(plist, /<key>SUSignedFeedFailureExpirationInterval<\/key>\s*<integer>0<\/integer>/);
  assert.match(plist, /<key>CFBundleName<\/key>\s*<string>Scriv<\/string>/);
  const plugin = await read('apps/catalyst/UpdatePlugin/ScrivSparklePlugin.m');
  assert.ok(plugin.includes('SPUAppcastSigningValidationStatusSucceeded'));
  assert.ok(plugin.includes('check == SPUUpdateCheckUpdates'));
});
