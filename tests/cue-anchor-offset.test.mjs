import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const source = () => readFile(new URL('../apps/catalyst/ScrivUIKit/Images/CueAnchorViewController.swift', import.meta.url), 'utf8');
const editingAction = text => text.split('offset.addAction(UIAction')[1]?.split('for: .editingChanged)')[0] ?? '';
const synchronization = text => text.split('private func synchronizeOffsetStepper() {')[1]?.split('private func save()')[0] ?? '';
const requiresDraftSynchronization = text => assert.match(editingAction(text), /self\.synchronizeOffsetStepper\(\)/);

test('offset source contract synchronizes the stepper on text events, not just store refresh', async () => {
  const text = await source();
  requiresDraftSynchronization(text);
  const refresh = text.split('override func storeDidChange() {')[1]?.split('private func synchronizeOffsetStepper()')[0] ?? '';
  assert.match(refresh, /stepper\.maximumValue =/);
  assert.match(refresh, /synchronizeOffsetStepper\(\)/);
  assert.throws(() => requiresDraftSynchronization(text.replace('self.synchronizeOffsetStepper()', '')), /synchronizeOffsetStepper/);
});

test('draft synchronization leaves text and model untouched and rejects nonfinite values', async () => {
  const text = await source(), body = synchronization(text).replace(/\/\/[^\n]*/g, '');
  assert.match(body, /guard let seconds = Double\(offset\.text \?\? ""\), seconds\.isFinite else \{ return \}/);
  assert.match(body, /stepper\.value = min\(stepper\.maximumValue, max\(stepper\.minimumValue, seconds\)\)/);
  assert.doesNotMatch(body, /offset\.text\s*=|store\.|dismiss\(|save\(/);
  assert.match(text, /guard current == original/);
  assert.match(text, /guard ms < entry\.ownedDurationMs/);
});

test('native offset regression uses real control events, isolated storage and model invariants', async () => {
  const text = await readFile(new URL('../apps/catalyst/Tests/ScrivUIKitTests/CueAnchorOffsetTests.swift', import.meta.url), 'utf8');
  for (const name of [
    'testTypedOffsetBecomesTheBaseForRepeatedStepperChanges',
    'testInvalidAndNonfiniteDraftsDoNotReplaceTheTextOrPoisonTheStepper',
    'testStepperBoundsDoNotSilentlyRewriteAnOutOfRangeDraft',
    'testChoosingAnotherSourceResetsBothControlsAndZeroOwnedDirectionStaysDisabled'
  ]) assert.ok(text.includes(`func ${name}()`));
  assert.match(text, /arguments\.contains\("--screenshots"\)/);
  assert.match(text, /field\.sendActions\(for: \.editingChanged\)/);
  assert.match(text, /stepper\.sendActions\(for: \.valueChanged\)/);
  assert.match(text, /XCTAssertEqual\(store\.project, original/);
  assert.match(text, /store\.isBootstrapping/);
  assert.match(text, /environment\["SCRIV_VERIFICATION_ROOT"\] == nil/);
  assert.match(text, /scratch\.lastPathComponent\.hasPrefix\("ScrivVerification-"\)/);
  assert.match(text, /scratch\.deletingLastPathComponent\(\)\.standardizedFileURL == FileManager\.default\.temporaryDirectory\.standardizedFileURL/);
  assert.doesNotMatch(text, /synchronizeOffsetStepper\(\)/);
});
