import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
const root = process.env.SCRIV_SOURCE_ROOT || new URL('../', import.meta.url).pathname;
const read = path => readFile(resolve(root, path), 'utf8');

// Portable source-contract checks complement the actual Objective-C and UIKit
// execution harnesses. They are not proof of native quit/relaunch behavior.
test('relaunch preparation is an explicit Foundation ABI distinction', async () => {
  const bridge = await read('apps/catalyst/UpdateBridge/ScrivUpdateBridge.h');
  assert.match(bridge, /ScrivUpdatePreparation\)\(BOOL willRelaunch,/);
  const plugin = await read('apps/catalyst/UpdatePlugin/ScrivSparklePlugin.m');
  const ready = plugin.split('- (void)showReadyToInstallAndRelaunch:')[1].split('- (void)showInstalling')[0];
  assert.match(ready, /prepareForRelaunch:YES reply:reply/);
  assert.match(ready, /SPUUserUpdateChoiceSkip/);
  assert.match(plugin, /prepareForRelaunch:state.stage == SPUUserUpdateStageInstalling reply:reply/);
});
test('successful save fences surround completed whole-chain modal dismissal', async () => {
  const coordinator = await read('apps/catalyst/ScrivUIKit/Updates/ScrivUpdateCoordinator.swift');
  const first = coordinator.indexOf('try await store.prepareForApplicationUpdate()');
  const dismissal = coordinator.indexOf('try await ScrivUpdatePresentationHandoff.dismissModalChain');
  const second = coordinator.indexOf('try await store.prepareForApplicationUpdate()', first + 1);
  const success = coordinator.indexOf('completion(nil)', second);
  assert.ok(first >= 0 && dismissal > first && second > dismissal && success > second);
  const handoff = await read('apps/catalyst/ScrivUIKit/Updates/ScrivUpdatePresentationHandoff.swift');
  assert.match(handoff, /guard top === update/);
  assert.match(handoff, /root.dismiss\(animated: false\) \{/);
  assert.match(handoff, /root.presentedViewController == nil, update.presentingViewController == nil/);
  assert.doesNotMatch(handoff, /exit\(|forceTerminate|kill\(|preventsApplicationTerminationWhenModal\s*=/);
});
test('termination false is preserved and retry cannot bypass renewed preparation', async () => {
  const plugin = await read('apps/catalyst/UpdatePlugin/ScrivSparklePlugin.m');
  const installing = plugin.split('- (void)showInstallingUpdateWithApplicationTerminated:')[1].split('- (void)showUpdateInstalled')[0];
  assert.match(installing, /self.retryTermination = terminated \? nil : retry/);
  assert.match(installing, /@"waitingToQuit"/);
  assert.doesNotMatch(installing, /retry\(\)/);
  const retry = plugin.split('- (void)retryTerminationAfterSaving')[1].split('- (void)showUpdateInFocus')[0];
  assert.match(retry, /completed \|\| generation != self.eventGeneration \|\| !self.retryTermination/);
  assert.match(retry, /self.prepare\(YES, finish\)/);
  assert.match(retry, /@"retryBlocked"/);
  assert.doesNotMatch(retry, /cancelUpdateWithReply|SPUUserUpdateChoiceSkip|forceTerminate|exit\(/);
  const dismiss = plugin.split('- (void)dismissUpdateInstallation')[1].split('- (void)retryTerminationAfterSaving')[0];
  assert.match(dismiss, /self.retryTermination = nil/);
});
test('non-progress phases have no fabricated percentage and pending quit is disclosed', async () => {
  const model = await read('apps/catalyst/ScrivUIKit/Updates/ScrivUpdatePresentation.swift');
  assert.match(model, /showsProgress = \["downloading", "verifying"\]\.contains\(phase\)/);
  assert.match(model, /case "retryQuit", "waitingToQuit"/);
  assert.match(model, /may install when you quit/);
  assert.match(model, /case "retryBlocked".*still prepared/);
  const coordinator = await read('apps/catalyst/ScrivUIKit/Updates/ScrivUpdateCoordinator.swift');
  assert.match(coordinator, /if event\["phase"\] as\? String == "waitingToQuit" \{ return \}/);
});
test('native harness exercises final-vs-download save, retry, stale completion and failed retry', async () => {
  const harness = await read('scripts/test-update-plugin-policy.m');
  for (const fn of ['FinalInstallWaitsForRelaunchPreparation', 'FinalRelaunchFailureCancelsImmediately', 'DownloadPreparationDoesNotDismissWindows', 'TerminationRetryIsExplicitAndOneShot', 'LateTerminationRetryIsInvalidated', 'RetrySaveFailureDoesNotPretendToCancelPendingInstall']) {
    assert.equal((harness.match(new RegExp(fn + '\\(', 'g')) || []).length, 2, fn + ' must be defined and executed');
  }
});
test('Escape reaches only the current visible enabled secondary updater choice', async () => {
  const source = await read('apps/catalyst/ScrivUIKit/Updates/ScrivUpdateController.swift');
  assert.match(source, /override var canBecomeFirstResponder: Bool \{ true \}/);
  assert.match(source, /override func viewDidAppear[\s\S]*?becomeFirstResponder\(\)/);
  assert.match(source, /UIKeyCommand\(input: UIKeyCommand.inputEscape, modifierFlags: \[\], action: #selector\(cancelFromEscape\)\)/);
  assert.match(source, /escape.wantsPriorityOverSystemBehavior = true/);
  assert.match(source, /if action == #selector\(cancelFromEscape\) \{ return canCancelFromEscape \}/);
  const eligibility = source.split('private var canCancelFromEscape: Bool {')[1].split('@objc private func cancelFromEscape()')[0];
  for (const guard of ['presentingViewController != nil', 'viewIfLoaded?.window != nil', 'presentedViewController == nil', '!isBeingPresented', '!isBeingDismissed', '!secondary.isHidden', 'secondary.isEnabled', 'reply != nil']) {
    assert.ok(eligibility.includes(guard), `Missing Escape safety condition: ${guard}`);
  }
  const action = source.split('@objc private func cancelFromEscape() {')[1].split('override func viewDidLoad()')[0];
  assert.match(action, /guard canCancelFromEscape else \{ return \}/);
  assert.match(action, /chooseSecondary\(\)/);
  assert.doesNotMatch(action, /dismiss\(|closeIfIdle\(|consume\(|choosePrimary\(/);
  const secondary = source.split('private func chooseSecondary() {')[1].split('private func consume(')[0];
  assert.match(secondary, /guard !secondary.isHidden, secondary.isEnabled, reply != nil else \{ return \}/);
  assert.match(secondary, /consume\("cancel"\)/);
  assert.doesNotMatch(secondary, /closeIfIdle\(|dismiss\(/);
  assert.match(source, /isModalInPresentation = true/);
});

test('native Escape coverage retains cancellation and unsafe-phase regressions', async () => {
  const tests = await read('apps/catalyst/Tests/ScrivUIKitTests/UpdateKeyboardTests.swift');
  for (const name of [
    'testEscapeUsesTheVisibleSecondaryActionOnceAndWaitsForThePlugin',
    'testEscapeCannotCancelHiddenActionsOrPhasesWithoutAReply',
    'testEscapeRechecksTheLatestPhaseRatherThanUsingAStaleCommand',
    'testSynchronousCancellationErrorStaysVisible',
    'testProgressDoesNotLoseOrReenableTheCancellationReply',
    'testEscapeCannotActAfterThePrimaryChoice',
    'testEscapeDoesNotAffectAnUpdateBehindAnotherModal',
    'testDetachedUpdateCannotReplyToEscape',
  ]) assert.ok(tests.includes(`func ${name}(`), name);
});

// UIKeyCommand.action imports as Selector? on the supported Catalyst SDK. A
// missing selector must fail the native test, not be skipped or force-unwrapped.
test('native Escape tests unwrap each optional action before eligibility and dispatch', async () => {
  const native = await read('apps/catalyst/Tests/ScrivUIKitTests/UpdateKeyboardTests.swift');
  assert.equal((native.match(/let action = try XCTUnwrap\(command\.action\)/g) || []).length, 8);
  assert.doesNotMatch(native, /canPerformAction\(command\.action|perform\(command\.action/);
  assert.doesNotMatch(native, /command\.action!|command\.action\s*\?\?/);
  assert.match(native, /canPerformAction\(action, withSender: command\)/);
  assert.match(native, /perform\(action, with: command\)/);
});
