import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
const source = path => readFile(new URL(`../${path}`, import.meta.url), 'utf8');
const base = 'apps/catalyst/ScrivUIKit/';

test('Codex uses a compact native popover anchored to the workspace menu', async () => {
  const view = await source(base + 'Account/ScrivCodexSetupView.swift');
  const router = await source(base + 'Shared/ScrivUIKitRouter.swift');
  const workspace = await source(base + 'App/ScrivWorkspaceController.swift');
  assert.match(view, /preferredPopupSize = CGSize\(width: 360, height: 360\)/);
  assert.match(router, /controller\.modalPresentationStyle = \.popover/);
  assert.match(router, /popup\.sourceView = anchor \?\? front\.view/);
  assert.match(workspace, /showCodexPopup\(from: self\?\.chrome\.moreButton\)/);
  assert.match(router, /topViewController is ScrivCodexController \{ return \}/);
  assert.doesNotMatch(view, /overrideUserInterfaceStyle = \.light|preferredSheetSize|UIImageView/);
});

test('Advanced dismisses the popup and targets the existing Codex Settings pane', async () => {
  const controller = await source(base + 'Account/ScrivSettingsController.swift');
  const router = await source(base + 'Shared/ScrivUIKitRouter.swift');
  const coordinator = await source(base + 'Account/ScrivSettingsWindowCoordinator.swift');
  const panel = await source(base + 'Account/ScrivSettingsPanelController.swift');
  assert.match(controller, /dismiss\(animated: true\) \{\s*ScrivUIKitRouter\.shared\.present\(\.codexSettings/);
  assert.match(router, /case \.codexSettings = route \{ ScrivSettingsWindowCoordinator\.shared\.show\(store: store, pane: \.codex\)/);
  assert.match(coordinator, /if let pane \{ pendingPane = pane \}/);
  assert.match(coordinator, /guard pendingStore == nil else \{ return \}/);
  assert.match(coordinator, /panel\.selectPane\(pane\)/);
  assert.match(panel, /guard selectedPane != pane \|\| panes\[pane\] == nil else \{ return \}/);
  assert.doesNotMatch(controller, /self\?\.show\(\.codex\)/);
});

test('native Settings has one scrolling body with persistent manual fields and no nested header', async () => {
  const view = await source(base + 'Account/ScrivCodexSetupView.swift');
  assert.match(view, /if surface == \.settings \{ buildSettings\(\) \}/);
  assert.match(view, /body\.insertArrangedSubview\(header, at: 0\)/);
  assert.match(view, /scroll\.leadingAnchor\.constraint\(equalTo: safeAreaLayoutGuide\.leadingAnchor\)/);
  assert.match(view, /body\.widthAnchor\.constraint\(equalTo: scroll\.frameLayoutGuide\.widthAnchor/);
  assert.match(view, /surface == \.popup \? \.systemBackground : \.systemGroupedBackground/);
  assert.doesNotMatch(view, /Saved pairing survives restarts|overrideUserInterfaceStyle/);
});

test('native regressions cover popup repetition, settings lifecycle, drafts and synthetic cancellation', async () => {
  const popup = await source('apps/catalyst/Tests/ScrivUIKitTests/CodexNativeModalParityTests.swift');
  const settings = await source('apps/catalyst/Tests/ScrivUIKitTests/SettingsPanelTests.swift');
  for (const name of ['testActualCodexRouteIsOneAnchoredPopoverWithoutConnecting', 'testClosingSettingsCancelsPendingPreparationAndCanRetry', 'testSwitchingPanesCancelsOnlyItsOwnCheck', 'testStalePopupDismissalCannotCancelNewSettingsAttempt']) assert.ok(popup.includes(name));
  assert.ok(settings.includes('testAdvancedSelectsExistingSettingsWithoutLosingAccountDraft'));
  assert.doesNotMatch(popup, /XCTSkip|MacRuntimeBridge\(|URLSession/);
});
