import XCTest
import UIKit
import ScrivCore
@testable import ScrivUIKit

/// Native picker cards with synthetic local bytes. Never uses user assets,
/// remote fetching, image generation, a live account, or a Save/Use action.
@MainActor final class ImagePickerDigestTests: XCTestCase {
    func testChooseImageAndVersionCardsRejectChangedBytesEvenWithAnUnverifiedCacheEntry() async throws {
        try await withFixture { store, url, expected in
            let original = store.project, asset = try XCTUnwrap(store.project.images.first)
            XCTAssertNotNil(store.assetURL(asset), "Equal-size changed bytes pass the cheap path/size lookup")
            XCTAssertNotEqual(ScrivDigest.sha256(try Data(contentsOf: url)), asset.sha256)
            // Other thumbnail callers can populate the loader's unverified cache.
            let unverified = UIKitAssetImageView(); unverified.configure(url: url, title: "Synthetic unverified image")
            try await settle(unverified); XCTAssertEqual(unverified.loadPhase, .loaded)
            for versionsOf in [nil, asset.id] as [String?] {
                let (controller, picture) = try pickerPicture(store: store, versionsOf: versionsOf)
                try await settle(picture)
                XCTAssertEqual(picture.loadPhase, .failed, "A version label must not accompany another image's bytes")
                XCTAssertNil(picture.loadedDigest)
                XCTAssertEqual(controller.title, versionsOf == nil ? "Choose an image" : "Image versions")
                XCTAssertEqual(store.project, original)
            }
            XCTAssertEqual(asset.sha256, ScrivDigest.sha256(expected))
        }
    }

    func testRetryRecoversTheExactImageWithoutChangingProjectOrRecoveredBytes() async throws {
        try await withFixture { store, url, expected in
            let original = store.project, asset = try XCTUnwrap(store.project.images.first)
            let (controller, picture) = try pickerPicture(store: store, versionsOf: asset.id)
            try await settle(picture); XCTAssertEqual(picture.loadPhase, .failed)
            let retry = try XCTUnwrap(descendants(picture).compactMap { $0 as? UIButton }
                .first { $0.title(for: .normal) == "Retry" })
            XCTAssertFalse(retry.isHidden)
            try expected.write(to: url, options: .atomic)
            retry.sendActions(for: .touchUpInside)
            try await settle(picture)
            XCTAssertEqual(picture.loadPhase, .loaded)
            XCTAssertEqual(picture.loadedDigest, asset.sha256)
            XCTAssertTrue(retry.isHidden)
            XCTAssertEqual(controller.title, "Image versions")
            XCTAssertEqual(store.project, original)
            XCTAssertEqual(try Data(contentsOf: url), expected, "Display must not rewrite recovered source bytes")
            let (reopened, reopenedPicture) = try pickerPicture(store: store, versionsOf: nil)
            try await settle(reopenedPicture)
            XCTAssertEqual(reopenedPicture.loadPhase, .loaded)
            XCTAssertEqual(reopenedPicture.loadedDigest, asset.sha256)
            XCTAssertEqual(reopened.title, "Choose an image")
            XCTAssertEqual(store.project, original)
        }
    }

    func testMissingAssetStaysAnEmptyPlaceholderWithoutChangingSelection() async throws {
        try await withFixture { store, _, _ in
            store.project.images[0].fileName = "missing-synthetic.png"
            let original = store.project
            let (controller, picture) = try pickerPicture(store: store, versionsOf: nil)
            XCTAssertEqual(picture.loadPhase, .empty)
            XCTAssertNil(picture.loadedDigest)
            XCTAssertEqual(picture.accessibilityValue, "Not on this Mac")
            XCTAssertEqual(controller.title, "Choose an image")
            XCTAssertEqual(store.project, original)
        }
    }

    private func withFixture(_ check: (WorkspaceStore, URL, Data) async throws -> Void) async throws {
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ScrivPickerDigestTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Synthetic.scriv", isDirectory: true)
        let assets = package.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        var wrong = png(.red), expected = png(.blue)
        // PNG decoders allow trailing bytes. Equal lengths ensure this exercises
        // digest verification rather than WorkspaceStore's cheaper size check.
        let size = max(wrong.count, expected.count)
        wrong.append(Data(repeating: 0, count: size - wrong.count))
        expected.append(Data(repeating: 0, count: size - expected.count))
        XCTAssertNotNil(UIImage(data: wrong)); XCTAssertNotNil(UIImage(data: expected))
        XCTAssertNotEqual(ScrivDigest.sha256(wrong), ScrivDigest.sha256(expected))
        let url = assets.appendingPathComponent("synthetic.png"); try wrong.write(to: url)
        let asset = ImageAsset(id: "synthetic-image", version: 1, fileName: "synthetic.png", sha256: ScrivDigest.sha256(expected), byteCount: expected.count)
        store.projectURL = package
        store.project = ScrivProject(id: "picker-digest-fixture", scenes: [ScriptScene(id: "scene")],
            entries: [ScriptEntry(id: "line", sceneId: "scene", order: 0, text: "Synthetic scene", ownedDurationMs: 1000)],
            images: [asset], cues: [ImageCue(id: "cue", sceneId: "scene", imageId: asset.id, label: "01A", startMs: 0, endMs: 1000)])
        store.selectedSceneID = "scene"
        try await check(store, url, expected)
    }

    private func pickerPicture(store: WorkspaceStore, versionsOf: String?) throws -> (ImagePickerViewController, UIKitAssetImageView) {
        let controller = ImagePickerViewController(store: store, cueID: "cue", versionsOf: versionsOf)
        controller.loadViewIfNeeded(); controller.view.frame = CGRect(x: 0, y: 0, width: 720, height: 720)
        let collection = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UICollectionView }.first)
        XCTAssertEqual(controller.collectionView(collection, numberOfItemsInSection: 0), 1)
        let cell = controller.collectionView(collection, cellForItemAt: IndexPath(item: 0, section: 0))
        let picture = try XCTUnwrap(descendants(cell).compactMap { $0 as? UIKitAssetImageView }.first)
        return (controller, picture)
    }
    private func settle(_ picture: UIKitAssetImageView) async throws {
        for _ in 0..<300 where picture.loadPhase == .loading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotEqual(picture.loadPhase, .loading, "Synthetic local image loading must finish")
    }
    private func png(_ color: UIColor) -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).pngData { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
}
