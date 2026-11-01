import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
const source = path => readFile(new URL(`../${path}`, import.meta.url), 'utf8');
const ui = path => source(`apps/catalyst/ScrivUIKit/${path}`);

// Portable source contracts only. These are NOT native execution or visual QA.
test('empty-moment image import captures a source-owned placement before the picker', async () => {
  const store = await source('apps/mac/Sources/ScrivApp/Services/WorkspaceStore.swift');
  const target = await source('apps/mac/Sources/ScrivCore/ImageImportPlacement.swift');
  assert.ok(store.indexOf('destination = try prepareImageImport') < store.indexOf('Task { _ = await self.importImage(from: url, destination: destination) }'));
  const prepare = store.split('func prepareImageImport(')[1].split('func importImage(cueId:')[0];
  assert.ok(prepare.indexOf('try imageImportPlacement') < prepare.indexOf('togglePlayback()'));
  assert.doesNotMatch(prepare, /seek\(|selectedCueID =|change\(|attachImage/);
  assert.match(store, /importPlacement\.attach\(imageID: version.id, to: &p\)/);
  assert.match(target, /next\.cues\.append\(ImageCue/);
  assert.match(target, /startAnchor: anchor, authoredDurationMs: durationMs/);
  assert.match(target, /project\.cues\(in: sceneID\) == capturedCues/);
  assert.doesNotMatch(target, /removeAll|splitCue|setOwnedDuration|setCueDuration/);
  const clock = store.split('private func updatePlayhead(toMs: Double)')[1].split('func togglePlayback()')[0];
  assert.doesNotMatch(clock, /selectedCueID =/);
});

test('preview validates exact bytes and fences reused asynchronous image requests', async () => {
  const image = await ui('Images/UIKitAssetImageView.swift');
  assert.match(image, /ScrivDigest.sha256\(bytes\) == expected/);
  assert.match(image, /expectedDigest != currentDigest/);
  assert.match(image, /self.requestID == request, self.currentURL == url/);
  assert.match(image, /loadedDigest = nil; imageView.image = nil/);
  assert.match(await ui('Images/PreviewViewController.swift'), /expectedDigest: image.sha256/);
});

test('one shared storyboard script distinguishes selection from playback without duplicate words', async () => {
  const board = await ui('Images/StoryboardViewController.swift');
  const card = board.split('@MainActor private final class UIKitStoryboardCard')[1].split('@MainActor private final class StoryboardWordButton')[0];
  assert.doesNotMatch(card, /let flow = StoryboardWordFlowView/);
  assert.match(board, /storyboard-shared-script/);
  assert.match(board, /button.setPlaybackWord\(playing\)/);
  assert.match(board, /UIColor.systemOrange.cgColor/);
  assert.match(board, /zip\(overlaps, overlapSegments\)/);
  assert.match(board, /sharedTransfer\(wordID:/);
});

test('duration digits tick without transitions and hold feedback is independently reduced-motion aware', async () => {
  const feedback = await ui('Shared/DurationHoldFeedback.swift');
  assert.match(feedback, /UIView.performWithoutAnimation/);
  assert.match(feedback, /CATransaction.setDisableActions\(true\)/);
  assert.match(feedback, /progress.duration = 0.18/);
  assert.match(feedback, /pulse.values = \[1, 1.04, 1\]/);
  assert.match(feedback, /UIAccessibility.isReduceMotionEnabled/);
  assert.doesNotMatch(feedback, /transitionCrossDissolve|keyPath: "opacity"/);
  for (const path of ['Script/ScriptDurationScrubDriver.swift', 'Images/ImageDurationScrubDriver.swift']) {
    const value = await ui(path); assert.match(value, /feedback.lockIn\(\)/); assert.match(value, /DurationHoldFeedback.tick/); assert.match(value, /feedback.reset\(\)/);
  }
});

test('picture split remains a fenced explicit preview and history hides detailed word timing initially', async () => {
  const split = await ui('Images/ImageSplitPreviewController.swift');
  assert.match(split, /split-picture-commit/);
  assert.match(split, /store.project.revision == revision/);
  assert.match(split, /store.splitCue\(original.id, atMs: cutMs, expected: original\)/);
  const move = split.split('@objc private func moveCut()')[1].split('private func updatePreview()')[0];
  assert.doesNotMatch(move, /store\.|seek\(|splitCue/);
  const history = await ui('Projects/HistoryController.swift');
  assert.match(history, /allFields.filter \{ \$0.label != "Word timing" \}/);
  assert.match(history, /Word timing details/);
  assert.match(history, /Read-only preview/);
  assert.match(history, /Restore as a new revision/);
});

test('command find uses the existing physical press gate and protects modal and text contexts', async () => {
  const router = await ui('Shared/ScrivPlaybackKeyboardRouter.swift');
  assert.match(router, /ignoringModifiers.lowercased\(\) == "f", !editingText/);
  assert.match(router, /pressGate.consume\(\.findInScript\)/);
  assert.match(router, /canFindScript: mayFindScript/);
  assert.match(router, /let mayFindScript = UIKitPresentation.window\?\.rootViewController\?\.presentedViewController == nil/);
  assert.match(router, /Find in script", input: "f", modifiers: \.command/);
  const root = await ui('App/ScrivWorkspaceController.swift');
  assert.doesNotMatch(root, /input: "f"/);
  assert.match(root, /guard presentedViewController == nil else/);
  assert.match(root, /focusSearch\(\)/);
});
