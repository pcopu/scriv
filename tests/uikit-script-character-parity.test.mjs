import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';

const source = path => readFile(new URL(`../apps/catalyst/${path}`, import.meta.url), 'utf8');

test('approved Script and Characters design references remain byte-identical', async () => {
  for (const [name, sha] of [
    ['01-script-editor.png', 'a76bdb62372b195da5089adf38eae959c59d99fd8f2056584cd294d3bdeee177'],
    ['02-characters.png', 'cbab5f8772b2aa1461b626158374486fe0406d1b60f268f4f51120aac58547ab']
  ]) {
    const bytes = await readFile(new URL(`../design/images/${name}`, import.meta.url));
    assert.equal(createHash('sha256').update(bytes).digest('hex'), sha);
  }
});

test('UIKit presentation uses deliberate full/compact typography without changing stored zoom', async () => {
  const metrics = await source('ScrivUIKit/Script/ScriptPresentationMetrics.swift');
  const controller = await source('ScrivUIKit/Script/ScriptScreenController.swift');
  assert.match(metrics, /bodySize: CGFloat \{ \(isCompact \? 16 : 22\) \* opticalScale \}/);
  assert.match(metrics, /bodySize \* CGFloat\(zoom\)/);
  assert.match(controller, /presentation\.fontSize\(zoom: store\.scriptZoom\)/);
  assert.match(controller, /rails\.presentation = presentation/);
  assert.match(controller, /headingSpacer\.isHidden = presentation\.isCompact/);
  assert.match(controller, /headingSpacerWidth\?\.isActive = !presentation\.isCompact/);
  assert.doesNotMatch(metrics, /SwiftUI|UserDefaults|setScriptZoom|ownedDurationMs/);
});

test('display and editor remain persistent while layout metrics update', async () => {
  const rows = await source('ScrivUIKit/Script/ScriptTextViews.swift');
  assert.match(rows, /let display = ScriptTextView\(\)/);
  assert.match(rows, /let editor = ScriptTextView\(\)/);
  assert.match(rows, /gutterWidth\.constant = presentation\.gutterWidth/);
  assert.match(rows, /editor\.markedTextRange == nil/);
  assert.match(rows, /onTextEdit\?\(CharacterTextEdit\(range: range, replacement: text\)\)/);
  assert.match(rows, /continuationLabel\.isHidden = !continued/);
});

test('Script seconds pill keeps UIKit gesture tracking and its exact-click action', async () => {
  const rows = await source('ScrivUIKit/Script/ScriptTextViews.swift');
  const driver = await source('ScrivUIKit/Script/ScriptDurationScrubDriver.swift');
  const native = await source('Tests/ScriptUIKitTests.swift');
  assert.match(rows, /let durationButton = UIButton\(type: \.custom\)/);
  assert.match(rows, /durationButton\.addAction\(UIAction \{ \[weak self\] _ in self\?\.onDuration\?\(\) \}, for: \.touchUpInside\)/);
  assert.match(rows, /durationButton\.isEnabled = !locked/);
  assert.match(driver, /gesture\.minimumPressDuration = 0\.18; gesture\.allowableMovement = 20; gesture\.cancelsTouchesInView = true; button\.addGestureRecognizer\(gesture\)/);
  assert.match(driver, /case \.cancelled, \.failed: cancel\(\)/);
  assert.match(driver, /if leaseReady \{ commit\(\) \}/);
  assert.match(driver, /store\.setDuration\(entryID, seconds: Double\(milliseconds\) \/ 1000\)/);
  for (const name of [
    'testOwnedDurationPillKeepsNumericClickAndExactTextSelection',
    'testInstalledOwnedDurationGestureIsLocalToPillAndAcceptsTouchAndPointer',
    'testDurationScrubProtectsZeroBoundsAndRejectsChangedSourceOrScene'
  ]) assert.ok(native.includes(`func ${name}(`));
});

test('character presentation retains exact image identity and all profile actions', async () => {
  const controller = await source('ScrivUIKit/Characters/CharactersController.swift');
  assert.match(controller, /label\("Characters", size: 32/);
  assert.match(controller, /label\(character\.name, size: 28 \* presentationScale/);
  assert.match(controller, /CGSize\(width: 100 \* presentationScale, height: 100 \* presentationScale\)/);
  assert.match(controller, /multiplier: 0\.54/);
  for (const action of ['Discuss character', 'Delete character…', 'Edit character tags', "Use as "]) assert.ok(controller.includes(action));
  assert.match(controller, /imageDetail\(imageID: image\.id, cueID: cue\?\.id\)/);
  assert.match(controller, /setCharacterPortrait\(character\.id, imageId: image\.id\)/);
  const mount = controller.indexOf('ribbonItems.addArrangedSubview(control)');
  const relativeWidth = controller.indexOf('control.widthAnchor.constraint(equalTo: ribbon.frameLayoutGuide.widthAnchor');
  assert.ok(mount >= 0 && mount < relativeWidth, 'mount ribbon cards before activating cross-hierarchy width constraints');
});
