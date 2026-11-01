import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

// Portable source contracts only. These do NOT compile UIKit, run Auto Layout,
// prove first-load safety, or certify the approved screenshots on the Mac.
const source = name => readFile(new URL(`../apps/catalyst/ScrivUIKit/Images/${name}.swift`, import.meta.url), 'utf8');

test('preflight exact request uses the same canonical brief and submission wrapper as generation', async () => {
  const text = await source('GenerationBriefPresentation');
  assert.match(text, /var exactBrief: String \{ context\.prompt \}/);
  assert.match(text, /var exactRequest: String \{ GenerationPrompt\.submitted\(brief: context\.prompt\) \}/);
  assert.doesNotMatch(text, /prefix\(30_000\)|substring\(to:|replacingOccurrences/);
  assert.match(text, /Copied portraits stay in local generation history/);
  assert.match(text, /image-file storage follows your project settings/);
});

test('portrait UI follows selected input order and distinguishes missing from input-limit fallback', async () => {
  const model = await source('GenerationBriefPresentation');
  const review = await source('GenerationBriefReviewController');
  assert.match(model, /context\.portraits\.firstIndex \{ \$0\.characterIDs\.contains\(characterID\) \}/);
  assert.match(model, /localPortraitURLs\[portrait\.assetID\]/);
  assert.match(model, /no local portrait available/);
  assert.match(model, /five-input limit/);
  assert.match(review, /snapshot\.context\.portraits\.enumerated\(\)/);
  assert.match(review, /portrait\.characterIDs\.compactMap/);
  assert.match(review, /Identical image bytes are sent once/);
  assert.doesNotMatch(model + review, /Data\(contentsOf:|downloadImage\(|generateImage\(/);
});

test('review uses one bounded scroll body and keeps header tabs and Done outside it', async () => {
  const text = await source('GenerationBriefReviewController');
  assert.match(text, /scroll\.addSubview\(body\)/);
  assert.match(text, /scroll\.topAnchor\.constraint\(equalTo: header\.bottomAnchor/);
  assert.match(text, /scroll\.bottomAnchor\.constraint\(equalTo: footer\.topAnchor/);
  assert.match(text, /footer\.bottomAnchor\.constraint\(equalTo: safe\.bottomAnchor/);
  assert.match(text, /body\.widthAnchor\.constraint\(equalTo: scroll\.frameLayoutGuide\.widthAnchor/);
  assert.match(text, /UISegmentedControl\(items: \["Source", "People", "Exact request"\]\)/);
  const tabSelection = text.split('func select(_ tab: Tab) {')[1]?.split('func togglePerson')[0];
  assert.ok(tabSelection);
  assert.doesNotMatch(tabSelection, /preferredContentSize|present\(|sizeToFit\(/);
  assert.doesNotMatch(text, /UIHostingController|import SwiftUI/);
});

test('current request copy and stale invalidation preserve request and project boundaries', async () => {
  const text = await source('GenerationBriefReviewController');
  assert.match(text, /generationPromptScopeKey == originalScope/);
  assert.match(text, /selectedSceneID == originalSceneID/);
  assert.match(text, /selectedImageGenerationContext == snapshot\.context/);
  assert.match(text, /reviewIsCurrent/);
  assert.match(text, /onCopy\(self\.snapshot\.exactRequest\)/);
  assert.match(text, /ImageUI\.clear\(body\); exactText\.text = nil/);
  assert.match(text, /tabs\.isEnabled = false/);
  assert.doesNotMatch(text, /\.generateImage\(|\.discardGenerationPrompt\(|\.rebaseGenerationPrompt\(|\.retryGenerationPrompt\(/);
});

test('full source and profile strings remain read-only and exact text has its own scroll viewport', async () => {
  const text = await source('GenerationBriefReviewController');
  assert.match(text, /ImageUI\.text\(passage\.text/);
  assert.match(text, /person\.aliases\.joined\(separator: ", "\)/);
  assert.match(text, /person\.appearance/);
  assert.match(text, /person\.biography/);
  assert.match(text, /Identity background, not a new scene event/);
  assert.match(text, /exactText\.text = snapshot\.exactRequest/);
  assert.match(text, /exactText\.isEditable = false; exactText\.isSelectable = true; exactText\.isScrollEnabled = true/);
  assert.match(text, /Captured historical requests remain in image details and generation history/);
});

test('commands override local configuration fonts without reviving wrapped labels or global scaling', async () => {
  const text = await source('GenerationBriefPresentation');
  assert.match(text, /titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer/);
  assert.match(text, /button\.titleLabel\?\.numberOfLines = 1/);
  assert.match(text, /button\.setContentCompressionResistancePriority\(\.required, for: \.horizontal\)/);
  assert.doesNotMatch(text, /CGAffineTransform\(scaleX|preferredContentSizeCategory/);
});

test('embedded composer preserves optional blank input and keeps its full brief out of the workspace', async () => {
  const preview = await source('PreviewViewController');
  const views = await source('GenerationComposerViews');
  assert.match(preview, /Image direction \(optional\)/);
  assert.match(preview, /context\?\.hasContent == true/);
  assert.match(preview, /GenerationBriefReviewController\(store: self\.store, context: context\)/);
  assert.match(preview, /self\.store\.generateImage\(cueId: cueID\)/);
  assert.match(preview, /generationPromptScopeKey == expectedScope, self\.displayedCueID == cueID/);
  assert.doesNotMatch(preview, /brief\.text = context\?\.prompt|private let brief =/);
  assert.match(views, /placeholderLabel\.isHidden = !\(text \?\? ""\)\.isEmpty/);
  assert.doesNotMatch(views, /generationPrompt\s*=/);
});

test('preview preserves true aspect-fit media and reachable collapsed Layers without changing timing', async () => {
  const text = await source('PreviewViewController');
  assert.match(text, /fill: false/);
  assert.match(text, /multiplier: 9\.0 \/ 16\.0/);
  assert.match(text, /private\(set\) var layersExpanded = false/);
  assert.match(text, /content\.insertArrangedSubview\(timeline\.view/);
  assert.match(text, /content\.removeArrangedSubview\(timeline\.view\)/);
  assert.match(text, /composerTarget\(isPlaying: store\.isPlaying, playingCue: store\.currentCue\)/);
  assert.match(text, /Durable cue-scoped journaling precedes UIKit accepting the mutation/);
});

test('person names and reference pills remain one content-hugging responsive group', async () => {
  const text = await source('GenerationBriefPresentation');
  assert.match(text, /generation-person-name-/);
  assert.match(text, /generation-person-reference-/);
  assert.match(text, /GenerationPersonNameRow\(name: name, badge: badge\)/);
  const row = text.split('private final class GenerationPersonNameRow')[1];
  assert.ok(row);
  assert.match(row, /name\.setContentHuggingPriority\(\.required, for: \.horizontal\)/);
  assert.match(row, /badge\.setContentHuggingPriority\(\.required, for: \.horizontal\)/);
  assert.match(row, /vertical \? \.vertical : \.horizontal/);
  assert.match(row, /name\.widthAnchor\.constraint\(lessThanOrEqualTo: widthAnchor\)/);
  assert.doesNotMatch(row, /numberOfLines = 1|\.text =|removeFromSuperview\(/);
});

test('profile facts use one compact ruled grid and missing-image guidance is not repeated in every card', async () => {
  const text = await source('GenerationBriefReviewController');
  assert.match(text, /generation-profile-grid-/);
  assert.match(text, /profileRow\("Also called"/);
  assert.match(text, /profileRow\("Appearance"/);
  assert.match(text, /profileRow\("Background"/);
  assert.match(text, /\], spacing: 0\)/);
  assert.match(text, /snapshot\.portraitAvailability\(for: person\)/);
  assert.equal((text.match(/No substitute image is attached\./g) ?? []).length, 1);
  const profileRow = text.split('private func profileRow(')[1]?.split('private func buildExactRequest')[0];
  assert.ok(profileRow);
  assert.match(profileRow, /ImageUI\.text\(value, size: 17\)/);
  assert.match(profileRow, /top: 4, leading: 0, bottom: 4/);
  assert.doesNotMatch(profileRow, /heightAnchor\.constraint\(equalToConstant:|prefix\(|maximumNumberOfLines/);
});

// Preview chrome is intentionally local: compact controls must not inherit the
// review-sheet command style or alter media/routing semantics.
test('Preview exposes Inspect text and compact full version labels without changing actions', async () => {
  const preview = await source('PreviewViewController');
  assert.match(preview, /let expand = PreviewChromeUI\.inspect/);
  assert.match(preview, /self\.show\(\.imageDetail\(imageID: imageID, cueID: self\.cue\?\.id\)\)/);
  assert.match(preview, /let versions = PreviewChromeUI\.version\(image\.version\)/);
  assert.match(preview, /self\.store\.navigationContext == navigation/);
  assert.match(preview, /ImagePickerViewController\(store: self\.store, cueID: cue\.id, versionsOf: image\.id\)/);
  const chrome = preview.split('@MainActor enum PreviewChromeUI {')[1].split('@MainActor final class ScrivPlaybackControlsView')[0];
  assert.match(chrome, /compactButton\("Inspect", symbol: "arrow\.up\.left\.and\.arrow\.down\.right"/);
  assert.match(chrome, /ofSize: 15, weight: \.medium/);
  assert.match(chrome, /top: 5, leading: 8, bottom: 5, trailing: 8/);
  assert.match(chrome, /imagePlacement = \.trailing/);
  assert.match(chrome, /titleLineBreakMode = \.byWordWrapping/);
  assert.doesNotMatch(chrome, /byTruncating|adjustsFontSizeToFitWidth = true|heightAnchor/);
  assert.match(preview, /configure\(url: url, title: cue\?\.label \?\? "Scene preview", fill: false, expectedDigest: image\.sha256\)/);
  assert.match(preview, /multiplier: 9\.0 \/ 16\.0/);
});
