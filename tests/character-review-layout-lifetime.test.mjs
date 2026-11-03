import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
const source = () => readFile(new URL('../apps/catalyst/ScrivUIKit/Characters/CharacterImageReviewController.swift', import.meta.url), 'utf8');
const rule = 'save.heightAnchor.constraint(greaterThanOrEqualToConstant:44).isActive = true';
const renderBody = text => text.split('private func render() {')[1]?.split('private func renderChoices()')[0] ?? '';
function assertOneTimeRule(text) {
  const load = text.split('override func viewDidLoad() {')[1]?.split('override func storeDidChange()')[0] ?? '';
  assert.ok(load.includes(rule), 'The retained save control is sized once during view loading');
  assert.ok(!renderBody(text).includes(rule), 'Repeated rendering must not append a height constraint');
  assert.equal(text.split(rule).length - 1, 1);
}

test('character review source creates the retained save height constraint once', async () => {
  const text = await source(); assertOneTimeRule(text);
  const repeated = text.replace(rule, '').replace('content.addArrangedSubview(save)', `${rule}; content.addArrangedSubview(save)`);
  assert.throws(() => assertOneTimeRule(repeated), /sized once/);
});

test('repeated review rendering still mounts the real save control and preserves save fences', async () => {
  const text = await source();
  assert.match(renderBody(text), /content\.addArrangedSubview\(save\)/);
  assert.match(text, /save\.addAction\(UIAction \{ \[weak self\] _ in self\?\.submit\(\)/);
  assert.match(text, /guard !isSaving, requireCurrentContext\(\), let item = current/);
  assert.match(text, /resolveCharacterImage\(item,characterID:characterID,newName:name,ignore:ignore,navigation:self\.initialNavigationContext\)/);
});

test('native lifetime regression exercises repeated refresh and candidate controls without saving', async () => {
  const text = await readFile(new URL('../apps/catalyst/Tests/ScrivUIKitTests/CharacterReviewLayoutLifetimeTests.swift', import.meta.url), 'utf8');
  for (const name of ['testRepeatedProjectRefreshKeepsOneSaveHeightConstraint', 'testRepeatedCandidateSwitchAndSkipPreserveConstraintAndProject']) {
    assert.ok(text.includes(`func ${name}()`));
  }
  assert.match(text, /for index in 0\.\.<30/); assert.match(text, /for index in 0\.\.<20/);
  assert.match(text, /sendActions\(for: \.touchUpInside\)/);
  assert.match(text, /XCTAssertEqual\(saveHeightConstraints\(save\)\.count, 1\)/);
  assert.match(text, /XCTAssertEqual\(store\.project, original/);
  assert.match(text, /arguments\.contains\("--screenshots"\)/);
  assert.match(text, /environment\["SCRIV_VERIFICATION_ROOT"\] == nil/);
  assert.match(text, /scratch\.lastPathComponent\.hasPrefix\("ScrivVerification-"\)/);
  assert.match(text, /scratch\.deletingLastPathComponent\(\)\.standardizedFileURL == FileManager\.default\.temporaryDirectory\.standardizedFileURL/);
  assert.doesNotMatch(text, /resolveCharacterImage\(|\.submit\(/);
});
