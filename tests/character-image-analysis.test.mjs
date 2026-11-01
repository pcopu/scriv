import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
const source = path => readFile(new URL(`../${path}`, import.meta.url), 'utf8');

test('character model persists optional version-bound annotations without changing image byte identity', async () => {
  const model = await source('apps/mac/Sources/ScrivCore/Models.swift');
  const domain = await source('apps/mac/Sources/ScrivCore/CharacterImageAnalysis.swift');
  assert.match(model, /characterAnalysis: ImageCharacterAnalysis\?/);
  assert.match(model, /portraitRegion: CharacterPortraitRegion\?/);
  for (const guard of ['imageSHA256 == image.sha256', 'imageVersion == image.version', 'protectedIDs.contains(prior.id)', 'excludedCharacterIDs', 'manualCharacterIDs', 'canonical != nil', 'confidence >= 0.88', 'detection.kind != .partial', 'detection.kind != .obscured']) assert.ok(domain.includes(guard), guard);
  assert.doesNotMatch(domain, /isGenerated|isRealPerson|biometric|faceEmbedding/i);
});

test('scan coordinator gates capability before bytes or RPC and fences navigation, cancellation and exact versions', async () => {
  const coordinator = await source('apps/mac/Sources/ScrivApp/Services/CharacterAnalysisController.swift');
  assert.match(coordinator, /guard allowsAnalysis, let store, availability == nil else/);
  assert.match(coordinator, /store\.navigationContext == navigation/);
  assert.match(coordinator, /store\.project\.asset\(image\.id\)\?\.version == image\.version/);
  assert.match(coordinator, /digest == image\.sha256/);
  assert.match(coordinator, /task\?\.cancel\(\)/);
  assert.match(coordinator, /providerID != "manual"/);
  assert.match(coordinator, /error\.code == \.cannotConnectToHost/);
  assert.doesNotMatch(coordinator, /URLSession|api[_-]?key|https:\/\/|Data\(contentsOf:.*portrait/i);
});

test('portrait crop uses oriented derived cache and never rewrites the source', async () => {
  const coordinator = await source('apps/mac/Sources/ScrivApp/Services/CharacterAnalysisController.swift');
  assert.match(coordinator, /kCGImageSourceCreateThumbnailWithTransform:true/);
  assert.match(coordinator, /CharacterPortraits/);
  assert.match(coordinator, /ScrivDigest\.sha256\(data\) == sha256/);
  assert.match(coordinator, /CGImageDestinationCreateWithURL\(temporary as CFURL/);
  assert.doesNotMatch(coordinator, /write\(to:source|removeItem\(at:source|moveItem\([^\n]*to:source/);
});

test('design-matched review actions are real controls and skip is nonmutating', async () => {
  const ui = await source('apps/catalyst/ScrivUIKit/Characters/CharacterImageReviewController.swift');
  const main = await source('apps/catalyst/ScrivUIKit/Characters/CharactersController.swift');
  for (const text of ['Who is in this image?', 'Save tag & next', 'Not a character', 'Skip for now', 'New character', 'Original images stay unchanged']) assert.ok(ui.includes(text), text);
  assert.match(ui, /requireCurrentContext\(\)/);
  assert.match(ui, /self\.skipped\.insert\(item\.id\)/);
  assert.match(ui, /await self\.store\.resolveCharacterImage/);
  assert.match(main, /Auto-tag new images/);
  assert.match(main, /reviewImageCount/);
  assert.match(main, /scanButton\.isEnabled = analysis\.availability == nil/);
});

test('native synthetic behavior tests cover review, retry identity, stale replies and untouched original bytes', async () => {
  const core = await source('apps/mac/Tests/ScrivCoreTests/CharacterImageAnalysisTests.swift');
  const native = await source('apps/catalyst/Tests/ScrivUIKitTests/CharacterImageReviewTests.swift');
  for (const name of ['testManualLabelsAndExplicitRemovalSurviveRescan', 'testUserCorrectionWinsOverRepeatedAndSlightlyShiftedModelResults', 'testStaleVersionAndStaleHashAreRejectedWithoutMutation', 'testFaceAndBodySubjectGroupDeduplicatesButTwoDifferentPeopleDoNot']) assert.ok(core.includes(name));
  for (const name of ['testUnavailableProviderNeverReceivesProjectImages', 'testLateCancelledResultCannotTagAnotherProject', 'testDerivedCropLeavesOriginalBytesUntouchedAndCachesByRegion']) assert.ok(native.includes(name));
  assert.match(native, /--screenshots/);
});
