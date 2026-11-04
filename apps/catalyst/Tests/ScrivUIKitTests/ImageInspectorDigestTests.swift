import XCTest
import UIKit
import ScrivCore
@testable import ScrivUIKit

/// Real inspector/tag-editor views over synthetic temporary bytes only.
/// No tag toggle, save, share, fetch, provider or account operation is invoked.
@MainActor final class ImageInspectorDigestTests: XCTestCase {
    func testInspectRejectsChangedOriginalAndRetryLoadsTheLabelledVersion() async throws {
        try await withFixture { store, mainURL, _, mainBytes, _, wrongBytes in
            let original = store.project, main = try XCTUnwrap(store.project.asset("main"))
            try wrongBytes.write(to: mainURL, options: .atomic)
            XCTAssertNotNil(store.assetURL(main), "The equal-size corrupt fixture must reach the image verifier")
            let controller = ImageDetailViewController(store: store, imageID: main.id, cueID: "cue")
            controller.loadViewIfNeeded()
            let picture = try XCTUnwrap(pictures(in: controller.view).first)
            try await settle(picture); XCTAssertEqual(picture.loadPhase, .failed); XCTAssertNil(picture.loadedDigest)
            XCTAssertEqual(controller.title, "01A")
            try mainBytes.write(to: mainURL, options: .atomic)
            try retry(picture); try await settle(picture)
            XCTAssertEqual(picture.loadPhase, .loaded); XCTAssertEqual(picture.loadedDigest, main.sha256)
            XCTAssertEqual(try Data(contentsOf: mainURL), mainBytes)
            XCTAssertEqual(store.project, original)
        }
    }

    func testTagEditorVerifiesMainImageAndPortraitAgainstTheirOwnDistinctDigests() async throws {
        try await withFixture { store, mainURL, portraitURL, mainBytes, portraitBytes, wrongBytes in
            let original = store.project
            let main = try XCTUnwrap(store.project.asset("main")), portraitAsset = try XCTUnwrap(store.project.asset("portrait"))
            XCTAssertNotEqual(main.sha256, portraitAsset.sha256)
            try wrongBytes.write(to: portraitURL, options: .atomic)
            XCTAssertNotNil(store.assetURL(portraitAsset))
            let controller = CharacterTagsViewController(store: store, imageID: main.id); controller.loadViewIfNeeded()
            let target = try picture(label: "Image being tagged", in: controller.view)
            let portrait = try picture(label: "Mara", in: controller.view)
            try await settle(target); try await settle(portrait)
            XCTAssertEqual(target.loadPhase, .loaded); XCTAssertEqual(target.loadedDigest, main.sha256)
            XCTAssertEqual(portrait.loadPhase, .failed); XCTAssertNil(portrait.loadedDigest)
            try portraitBytes.write(to: portraitURL, options: .atomic)
            try retry(portrait); try await settle(portrait)
            XCTAssertEqual(portrait.loadPhase, .loaded); XCTAssertEqual(portrait.loadedDigest, portraitAsset.sha256)
            XCTAssertEqual(try Data(contentsOf: mainURL), mainBytes)
            XCTAssertEqual(try Data(contentsOf: portraitURL), portraitBytes)
            XCTAssertEqual(store.project, original, "Viewing/retrying must never assign tags or change portraits")
        }
    }

    func testMissingTagImageAndPortraitKeepTheirExistingPlaceholders() async throws {
        try await withFixture { store, _, _, _, _, _ in
            store.project.images[0].fileName = "missing-main.png"
            store.project.images[1].fileName = "missing-portrait.png"
            let original = store.project
            let controller = CharacterTagsViewController(store: store, imageID: "main"); controller.loadViewIfNeeded()
            let target = try picture(label: "Image being tagged", in: controller.view)
            let portrait = try picture(label: "Mara", in: controller.view)
            XCTAssertEqual(target.loadPhase, .empty); XCTAssertEqual(target.accessibilityValue, "Not on this Mac")
            XCTAssertEqual(portrait.loadPhase, .empty); XCTAssertEqual(portrait.accessibilityValue, "M")
            XCTAssertNil(target.loadedDigest); XCTAssertNil(portrait.loadedDigest)
            XCTAssertEqual(store.project, original)
        }
    }

    private func withFixture(_ check: (WorkspaceStore, URL, URL, Data, Data, Data) async throws -> Void) async throws {
        guard ProcessInfo.processInfo.arguments.contains("--screenshots") else {
            throw XCTSkip("Requires isolated verification storage; never construct a live user workspace.")
        }
        let store = WorkspaceStore()
        let scratch = try XCTUnwrap(store.projectURL).deletingLastPathComponent().deletingLastPathComponent()
        defer {
            if ProcessInfo.processInfo.environment["SCRIV_VERIFICATION_ROOT"] == nil,
               scratch.lastPathComponent.hasPrefix("ScrivVerification-"),
               scratch.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL {
                try? FileManager.default.removeItem(at: scratch)
            }
        }
        for _ in 0..<500 where store.isBootstrapping { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.isBootstrapping)
        guard !store.isBootstrapping else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ScrivInspectorDigestTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Synthetic.scriv", isDirectory: true)
        let assets = package.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        var mainBytes = png(.blue), portraitBytes = png(.green), wrongBytes = png(.red)
        let size = max(mainBytes.count, max(portraitBytes.count, wrongBytes.count))
        mainBytes.append(Data(repeating: 0, count: size - mainBytes.count))
        portraitBytes.append(Data(repeating: 0, count: size - portraitBytes.count))
        wrongBytes.append(Data(repeating: 0, count: size - wrongBytes.count))
        for bytes in [mainBytes, portraitBytes, wrongBytes] { XCTAssertNotNil(UIImage(data: bytes)) }
        XCTAssertEqual(Set([mainBytes, portraitBytes, wrongBytes].map { ScrivDigest.sha256($0) }).count, 3)
        let mainURL = assets.appendingPathComponent("main.png"), portraitURL = assets.appendingPathComponent("portrait.png")
        try mainBytes.write(to: mainURL); try portraitBytes.write(to: portraitURL)
        let main = ImageAsset(id: "main", fileName: "main.png", sha256: ScrivDigest.sha256(mainBytes), byteCount: mainBytes.count)
        let portrait = ImageAsset(id: "portrait", fileName: "portrait.png", sha256: ScrivDigest.sha256(portraitBytes), byteCount: portraitBytes.count)
        store.projectURL = package
        store.project = ScrivProject(id: "inspector-digest-fixture", scenes: [ScriptScene(id: "scene")],
            entries: [ScriptEntry(id: "line", sceneId: "scene", order: 0, text: "Synthetic scene", ownedDurationMs: 1000)],
            characters: [ScriptCharacter(id: "mara", name: "Mara", portraitImageId: portrait.id)],
            images: [main, portrait], cues: [ImageCue(id: "cue", sceneId: "scene", imageId: main.id, label: "01A", startMs: 0, endMs: 1000)])
        store.selectedSceneID = "scene"
        try await check(store, mainURL, portraitURL, mainBytes, portraitBytes, wrongBytes)
    }

    private func retry(_ picture: UIKitAssetImageView) throws {
        let button = try XCTUnwrap(descendants(picture).compactMap { $0 as? UIButton }.first { $0.title(for: .normal) == "Retry" })
        XCTAssertFalse(button.isHidden); button.sendActions(for: .touchUpInside)
    }
    private func settle(_ picture: UIKitAssetImageView) async throws {
        for _ in 0..<300 where picture.loadPhase == .loading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotEqual(picture.loadPhase, .loading)
    }
    private func pictures(in view: UIView) -> [UIKitAssetImageView] { descendants(view).compactMap { $0 as? UIKitAssetImageView } }
    private func picture(label: String, in view: UIView) throws -> UIKitAssetImageView {
        try XCTUnwrap(pictures(in: view).first { picture in
            descendants(picture).contains { ($0 as? UIImageView)?.accessibilityLabel == label }
        })
    }
    private func png(_ color: UIColor) -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).pngData { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
}
