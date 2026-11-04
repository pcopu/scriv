import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
const read = path => readFile(new URL(`../${path}`, import.meta.url), 'utf8');
const root = 'apps/catalyst/ScrivUIKit/';
const directBindings = [
  ['Characters/CharacterTeamUI.swift', 'image.configure(url:asset.flatMap { store.assetURL($0) },title:character.name,fill:true,missingText:"No portrait on this device",expectedDigest:asset?.sha256)'],
  ['Characters/CharactersController.swift', 'picture.configure(url: store.assetURL(image), title: title, fill: true, missingText: "Image not on this device", expectedDigest: image.sha256)'],
  ['Discussion/DiscussionMessageViews.swift', 'thumbnail.configure(url: store.assetURL(image), title: UIKitDiscussionPresentation.imageLabel(image, project: store.project), missingText: "Image unavailable", expectedDigest: image.sha256)'],
  ['Discussion/ScrivDiscussionController.swift', 'contextThumbnail.configure(url: store.assetURL(image), title: UIKitDiscussionPresentation.imageLabel(image, project: store.project), missingText: "Image unavailable", expectedDigest: image.sha256)'],
  ['Teams/TeamsController.swift', 'picture.configure(url: coverAsset.flatMap { store.assetURL($0) }, title: store.project.title, fill: true, missingText: "No preview", expectedDigest: coverAsset?.sha256)'],
];
function requiresBinding(text, binding) { assert.ok(text.includes(binding), `Missing exact asset digest binding: ${binding}`); }

test('character, discussion and team previews bind the displayed asset digest', async () => {
  for (const [file, binding] of directBindings) {
    const text = await read(root + file); requiresBinding(text, binding);
    assert.throws(() => requiresBinding(text.replace(/,\s*expectedDigest:[^)]+\)/g, ')'), binding), /digest binding/);
  }
  const team = await read(root + 'Teams/TeamsController.swift');
  assert.match(team, /let coverAsset = store\.project\.asset\(store\.project\.cues\.first\?\.imageId\)/);
});

test('generation avatars pair URL and digest from the same deduplicated selected reference', async () => {
  const text = await read(root + 'Images/GenerationBriefPresentation.swift');
  for (const binding of [
    'func attachedPortrait(for characterID: String) -> (url: URL, sha256: String)?',
    'context.portraits.first(where: { $0.characterIDs.contains(characterID) })',
    'let url = localPortraitURLs[portrait.assetID]',
    'return (url, portrait.sha256)',
    'func attachedPortraitURL(for characterID: String) -> URL? { attachedPortrait(for: characterID)?.url }',
    'if let portrait = snapshot.attachedPortrait(for: character.id)',
    'picture.configure(url: portrait.url, title: "Attached identity portrait for " + character.name, fill: false, expectedDigest: portrait.sha256)',
  ]) requiresBinding(text, binding);
  const binding = 'return (url, portrait.sha256)';
  assert.throws(() => requiresBinding(text.replace(binding, 'return (url, character.portraitImageId)'), binding), /digest binding/);
  assert.doesNotMatch(text, /Data\(contentsOf:|UIImage\(data:|Task\.detached/);
});

test('existing crop identity, attachment version precedence and presentation behavior remain', async () => {
  const portraits = await read(root + 'Characters/CharacterTeamUI.swift');
  assert.match(portraits, /crop\.imageID == asset\.id, crop\.imageSHA256 == asset\.sha256/);
  assert.match(portraits, /CharacterCropImageView\(source:store\.assetURL\(asset\),sha256:asset\.sha256,region:crop\.region/);
  const attachments = await read(root + 'Discussion/DiscussionPresentation.swift');
  assert.match(attachments, /if let version = attachment\["imageVersionId"\]\?\.string \{ return project\.asset\(version\) \}/);
  const context = await read(root + 'Discussion/ScrivDiscussionController.swift');
  assert.match(context, /contextThumbnail\.isHidden = image == nil/);
  const review = await read(root + 'Images/GenerationBriefReviewController.swift');
  assert.match(review, /let url = store\.assetURL\(asset\) \{ urls\[asset\.id\] = url \}/);
});

test('native caller regressions cover cache, distinct identities, reuse, Retry and safe fixtures', async () => {
  const text = await read('apps/catalyst/Tests/ScrivUIKitTests/RemainingImageDigestTests.swift');
  for (const name of [
    'testExplicitAndFallbackPortraitsRejectUnverifiedCachedBytesAndRetry',
    'testTaggedCharacterCardUsesItsOwnDigestRatherThanThePortraitDigest',
    'testDiscussionAttachmentVersionAndContextKeepTheirOwnDigestAcrossReuse',
    'testTeamCoverRejectsWrongBytesAndRetainsRetry',
    'testGenerationAvatarUsesTheDeduplicatedReferenceURLAndDigest',
    'testMissingPortraitAndTeamCoverKeepTheirPlaceholders',
  ]) assert.ok(text.includes(`func ${name}()`));
  assert.match(text, /XCTAssertNotEqual\(main\.sha256, portrait\.sha256\)/);
  assert.match(text, /XCTAssertEqual\(context\.portraits\.first\?\.characterIDs, \["mara", "mae"\]\)/);
  assert.match(text, /XCTAssertEqual\(avatar\.loadedDigest, shared\.sha256\)/);
  assert.match(text, /button\.sendActions\(for: \.touchUpInside\)/);
  assert.match(text, /XCTAssertEqual\(store\.project, original\)/);
  assert.match(text, /arguments\.contains\("--screenshots"\)/);
  assert.match(text, /environment\["SCRIV_VERIFICATION_ROOT"\] == nil/);
  assert.match(text, /scratch\.lastPathComponent\.hasPrefix\("ScrivVerification-"\)/);
  assert.match(text, /scratch\.deletingLastPathComponent\(\)\.standardizedFileURL == FileManager\.default\.temporaryDirectory\.standardizedFileURL/);
  assert.doesNotMatch(text, /\.viewDidAppear\(|\.present\(|\.downloadImage\(|\.generateImage\(|\.setCharacterTags\(/);
});
