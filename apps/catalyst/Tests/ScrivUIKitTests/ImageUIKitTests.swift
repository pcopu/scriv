import XCTest
import UIKit
import ScrivCore
@testable import ScrivUIKit

/// Requires the real UIKit / Mac Catalyst SDK and runtime. Linux parsing is not
/// a pass of these layout, responder or asynchronous image-loading tests.
@MainActor final class ImageUIKitTests: XCTestCase {
    func testOriginalVersionNeverFollowsPlacementToNewVersion() {
        let project = fixture()
        XCTAssertEqual(UIKitImageContext.placement(imageID: "v1", cueID: "new-use", project: project)?.id, "old-use")
        XCTAssertEqual(UIKitImageContext.title(imageID: "v1", cueID: "new-use", project: project), "Original shot")
        XCTAssertEqual(project.images[0].generationPrompt, "Exact submitted prompt\nOriginal source.")
    }
    func testHistoricalUnplacedImageDoesNotInventAScriptDestination() {
        var project = fixture(); project.cues.removeAll { $0.imageId == "v1" }
        XCTAssertNil(UIKitImageContext.placement(imageID: "v1", cueID: "new-use", project: project))
        XCTAssertEqual(UIKitImageContext.title(imageID: "v1", project: project), "Image")
        project.characters = [ScriptCharacter(id: "mara", name: "Mara", portraitImageId: "v1")]
        XCTAssertEqual(UIKitImageContext.title(imageID: "v1", project: project), "Mara portrait")
        XCTAssertNil(UIKitImageContext.placement(imageID: "v1", cueID: nil, project: project))
    }
    func testPreferredExactUseAndOverlappingImageLanesRemainDistinct() {
        var project = fixture(); project.cues.append(ImageCue(id: "reuse", sceneId: "scene", imageId: "v1", label: "Another use", startMs: 1500, endMs: 2500))
        XCTAssertEqual(UIKitImageContext.placement(imageID: "v1", cueID: "reuse", project: project)?.id, "reuse")
        let cues = [ImageCue(id: "a", sceneId: "scene", startMs: 0, endMs: 3000), ImageCue(id: "b", sceneId: "scene", startMs: 1000, endMs: 2000), ImageCue(id: "c", sceneId: "scene", startMs: 2000, endMs: 2500)]
        let lanes = UIKitImageContext.imageLanes(cues)
        XCTAssertEqual(lanes.map { $0.cue.id }, ["a", "b", "c"]); XCTAssertEqual(lanes.map(\.lane), [0, 1, 1]); XCTAssertEqual(cues.map(\.endMs), [3000, 2000, 2500])
    }
    func testLongSourceTextWrapsWithoutTruncatingOrChangingUTF16() {
        let source = String(repeating: "We can move these words without moving the picture. 🙂 cafe\u{301}\n", count: 12)
        let text = ImageUI.text(source, size: 16); text.frame = CGRect(x: 0, y: 0, width: 260, height: 50); text.layoutIfNeeded()
        let narrow = text.sizeThatFits(CGSize(width: 260, height: .greatestFiniteMagnitude))
        let wide = text.sizeThatFits(CGSize(width: 700, height: .greatestFiniteMagnitude))
        XCTAssertGreaterThan(narrow.height, wide.height); XCTAssertFalse(text.isScrollEnabled); XCTAssertEqual(text.textContainer.maximumNumberOfLines, 0)
        XCTAssertTrue(text.text.utf16.elementsEqual(source.utf16)); XCTAssertFalse(text.isEditable); XCTAssertTrue(text.isSelectable)
    }
    func testSafeAreaMountingAndSharedPinHelperHaveRealCommonAncestors() {
        let controller = UIViewController(); controller.loadViewIfNeeded(); controller.view.frame = CGRect(x: 0, y: 0, width: 720, height: 600)
        let stack = ImageUI.stack([ImageUI.label("Complete text")]); ImageUI.pinToSafeArea(stack, in: controller, insets: NSDirectionalEdgeInsets(top: 20, leading: 24, bottom: 20, trailing: 24))
        controller.view.layoutIfNeeded(); XCTAssertTrue(stack.superview === controller.view); XCTAssertGreaterThan(stack.frame.width, 600)
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 100)), child = UIView(); child.scrivPinEdges(to: container); container.layoutIfNeeded()
        XCTAssertTrue(child.superview === container); XCTAssertEqual(child.frame.size, container.bounds.size)
    }
    func testImageLoadIsPendingBeforeSuccessAndClearingCancelsOldResult() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 4, height: 4)) }
        let url = root.appendingPathComponent("valid.png"); try XCTUnwrap(image.pngData()).write(to: url)
        let view = UIKitAssetImageView(frame: CGRect(x: 0, y: 0, width: 240, height: 135)); view.configure(url: url, title: "First")
        XCTAssertEqual(view.loadPhase, .loading)
        for _ in 0..<100 where view.loadPhase == .loading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(view.loadPhase, .loaded)
        let missing = root.appendingPathComponent("missing.png"); view.configure(url: missing, title: "Second"); XCTAssertEqual(view.loadPhase, .loading)
        view.configure(url: nil, title: "Empty", missingText: "Add an image"); XCTAssertEqual(view.loadPhase, .empty)
        try await Task.sleep(for: .milliseconds(50)); XCTAssertEqual(view.loadPhase, .empty)
    }
    func testFailedImageDoesNotPoisonAReusedViewForAnotherURL() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        let view = UIKitAssetImageView(); view.configure(url: missing, title: "Missing")
        for _ in 0..<100 where view.loadPhase == .loading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(view.loadPhase, .failed)
        view.configure(url: missing.appendingPathExtension("other"), title: "Another"); XCTAssertEqual(view.loadPhase, .loading)
        view.configure(url: nil, title: "None"); XCTAssertEqual(view.loadPhase, .empty)
    }
    func testBackgroundDeselectPolicyExcludesWordsControlsAndImageGestures() {
        let root = UIView(), blank = UIView(), button = UIButton(type: .system), innerLabel = UILabel(), picture = UIKitAssetImageView(), text = UITextView()
        root.addSubview(blank); root.addSubview(button); button.addSubview(innerLabel); root.addSubview(picture); root.addSubview(text)
        XCTAssertTrue(StoryboardBackgroundSelectionPolicy.isBlankTouch(blank, within: root))
        XCTAssertTrue(StoryboardBackgroundSelectionPolicy.isBlankTouch(root, within: root))
        XCTAssertFalse(StoryboardBackgroundSelectionPolicy.isBlankTouch(innerLabel, within: root))
        XCTAssertFalse(StoryboardBackgroundSelectionPolicy.isBlankTouch(button, within: root))
        XCTAssertFalse(StoryboardBackgroundSelectionPolicy.isBlankTouch(picture, within: root))
        XCTAssertFalse(StoryboardBackgroundSelectionPolicy.isBlankTouch(text, within: root))
        XCTAssertFalse(StoryboardBackgroundSelectionPolicy.isBlankTouch(UIView(), within: root))
    }
    private func fixture() -> ScrivProject {
        ScrivProject(scenes: [ScriptScene(id: "scene")], images: [ImageAsset(id: "v1", version: 1, fileName: "v1.png", sha256: "a", byteCount: 1, prompt: "Manual direction", generationPrompt: "Exact submitted prompt\nOriginal source."), ImageAsset(id: "v2", version: 2, fileName: "v2.png", sha256: "b", byteCount: 1, previousVersionId: "v1")], cues: [ImageCue(id: "new-use", sceneId: "scene", imageId: "v2", label: "New shot", startMs: 0, endMs: 1000), ImageCue(id: "old-use", sceneId: "scene", imageId: "v1", label: "Original shot", startMs: 1000, endMs: 2000)])
    }
}
