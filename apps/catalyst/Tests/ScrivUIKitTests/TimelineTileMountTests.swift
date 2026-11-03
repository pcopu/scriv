import XCTest
import UIKit
import ScrivCore
@testable import ScrivUIKit

/// Actual timeline view hierarchy/control regressions over synthetic local files.
/// No OS input, presentation, editing lease, timing mutation, provider or fetch.
@MainActor final class TimelineTileMountTests: XCTestCase {
    func testEverySceneCueMountsItsTileWithImageMenuAndDragRecognizer() async throws {
        try await withFixture { store, _, _, _, _ in
            let original = store.project
            for expanded in [false, true] {
                let controller = timeline(store, expanded: expanded)
                XCTAssertEqual(tiles(in: controller.view).count, 2)
                for cue in store.sceneCues {
                    let tile = try tile(label: cue.label, in: controller.view)
                    XCTAssertTrue(tile.isDescendant(of: controller.view)); XCTAssertFalse(tile.isHidden)
                    XCTAssertNotNil(tile.superview); XCTAssertGreaterThan(tile.frame.width, 0); XCTAssertEqual(tile.frame.height, 55)
                    XCTAssertEqual(tile.frame.minX, 70 + CGFloat(cue.startMs) * 0.04, accuracy: 0.001)
                    XCTAssertEqual(tile.frame.width, max(3, CGFloat(cue.durationMs) * 0.04 - 2), accuracy: 0.001)
                    XCTAssertNil(tile.menu, "A hold menu must not swallow timeline drags")
                    XCTAssertNotNil(ScrivSecondaryMenu.menu(of: tile))
                    XCTAssertTrue(tile.gestureRecognizers?.contains { $0 is ImageTimingPanRecognizer } == true)
                    XCTAssertEqual(tile.accessibilityCustomActions?.map(\.name), ["Change source or exact offset"])
                    let picture = try XCTUnwrap(tile.subviews.compactMap { $0 as? UIKitAssetImageView }.first)
                    try await settle(picture)
                    XCTAssertEqual(picture.loadPhase, .loaded)
                    XCTAssertEqual(picture.loadedDigest, store.project.asset(cue.imageId)?.sha256)
                }
            }
            XCTAssertEqual(store.project, original)
        }
    }

    func testOverlappingCuesMountInSeparateLanesOnTheSameCanvas() async throws {
        try await withFixture { store, _, _, _, _ in
            store.project.cues.append(ImageCue(id: "overlap", sceneId: "scene", imageId: "main", label: "01C", startMs: 1000, endMs: 3000, startAnchor: ScriptTimeAnchor(entryId: "line", offsetMs: 1000), authoredDurationMs: 2000))
            let original = store.project, controller = timeline(store)
            XCTAssertEqual(tiles(in: controller.view).count, 3)
            let first = try tile(label: "01A", in: controller.view), second = try tile(label: "01B", in: controller.view)
            let overlap = try tile(label: "01C", in: controller.view)
            XCTAssertTrue(first.superview === second.superview); XCTAssertTrue(first.superview === overlap.superview)
            XCTAssertEqual(first.frame.minY, second.frame.minY)
            XCTAssertGreaterThan(overlap.frame.minY, first.frame.maxY)
            XCTAssertLessThan(overlap.frame.minX, first.frame.maxX)
            store.playheadMs = 1500; store.selectedCueID = "cue-a"; controller.storeDidChange()
            XCTAssertEqual(store.currentCue?.id, "overlap")
            XCTAssertEqual(overlap.layer.borderWidth, 1, accuracy: 0.001)
            XCTAssertEqual(first.layer.borderWidth, 2.5, accuracy: 0.001)
            XCTAssertEqual(second.layer.borderWidth, 0, accuracy: 0.001)
            XCTAssertEqual(store.project, original)
        }
    }

    func testRegisteredTilesTrackSelectionAndPlayheadWithoutReplacementOrDuplicates() async throws {
        try await withFixture { store, _, _, _, _ in
            let original = store.project, controller = timeline(store)
            let first = try tile(label: "01A", in: controller.view), second = try tile(label: "01B", in: controller.view)
            let identities = Set(tiles(in: controller.view).map(ObjectIdentifier.init))
            for pass in 0..<30 {
                store.playheadMs = pass.isMultiple(of: 2) ? 500 : 2500
                store.selectedCueID = pass.isMultiple(of: 3) ? "cue-a" : "cue-b"
                controller.storeDidChange()
                XCTAssertEqual(tiles(in: controller.view).count, 2)
                XCTAssertEqual(Set(tiles(in: controller.view).map(ObjectIdentifier.init)), identities)
                for (id, tile) in [("cue-a", first), ("cue-b", second)] {
                    let selected = store.selectedCueID == id
                    let expected: CGFloat = selected ? 2.5 : store.currentCue?.id == id ? 1 : 0
                    XCTAssertEqual(tile.layer.borderWidth, expected, accuracy: 0.001)
                    XCTAssertEqual(tile.accessibilityTraits.contains(.selected), selected)
                    XCTAssertTrue(tile.accessibilityTraits.contains(.button))
                }
            }
            XCTAssertEqual(store.project, original)
        }
    }

    func testMountedTileActionPausesAndSeeksWithoutChangingTheProject() async throws {
        try await withFixture { store, _, _, _, _ in
            let original = store.project, controller = timeline(store)
            let second = try tile(label: "01B", in: controller.view)
            store.seek(toMs: 500); store.togglePlayback()
            defer { if store.isPlaying { store.togglePlayback() } }
            XCTAssertTrue(store.isPlaying)
            second.sendActions(for: .touchUpInside)
            XCTAssertFalse(store.isPlaying); XCTAssertEqual(store.playheadMs, 2000); XCTAssertEqual(store.selectedCueID, "cue-b")
            controller.storeDidChange()
            XCTAssertEqual(second.layer.borderWidth, 2.5, accuracy: 0.001)
            let first = try tile(label: "01A", in: controller.view)
            first.sendActions(for: .touchUpInside); controller.storeDidChange()
            XCTAssertEqual(store.playheadMs, 0); XCTAssertEqual(store.selectedCueID, "cue-a")
            XCTAssertEqual(first.layer.borderWidth, 2.5, accuracy: 0.001)
            XCTAssertEqual(second.layer.borderWidth, 0, accuracy: 0.001)
            XCTAssertEqual(store.project, original)
        }
    }

    func testZoomAndSceneRebuildRemoveOldTilesAndRegisterOnlyTheNewScene() async throws {
        try await withFixture { store, _, _, _, _ in
            let original = store.project, controller = timeline(store)
            let old = tiles(in: controller.view), firstWidth = try tile(label: "01A", in: controller.view).frame.width
            let zoom = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UISlider }.first { $0.accessibilityLabel == "Timeline zoom" })
            zoom.value = 2; zoom.sendActions(for: .valueChanged)
            XCTAssertEqual(tiles(in: controller.view).count, 2)
            XCTAssertTrue(old.allSatisfy { $0.superview == nil })
            XCTAssertGreaterThan(try tile(label: "01A", in: controller.view).frame.width, firstWidth)
            let zoomed = tiles(in: controller.view)
            store.selectedSceneID = "other"; store.selectedCueID = "cue-c"; store.playheadMs = 500
            controller.storeDidChange()
            XCTAssertEqual(tiles(in: controller.view).count, 1)
            XCTAssertTrue(zoomed.allSatisfy { $0.superview == nil })
            let other = try tile(label: "02A", in: controller.view)
            XCTAssertEqual(other.layer.borderWidth, 2.5, accuracy: 0.001)
            XCTAssertTrue(other.accessibilityTraits.contains(.selected))
            store.selectedCueID = nil; controller.storeDidChange()
            XCTAssertEqual(other.layer.borderWidth, 1, accuracy: 0.001)
            XCTAssertFalse(other.accessibilityTraits.contains(.selected))
            store.selectedSceneID = "scene"; store.selectedCueID = "cue-b"; store.playheadMs = 2500
            controller.storeDidChange()
            XCTAssertNil(other.superview); XCTAssertEqual(tiles(in: controller.view).count, 2)
            XCTAssertEqual(try tile(label: "01B", in: controller.view).layer.borderWidth, 2.5, accuracy: 0.001)
            XCTAssertEqual(store.project, original)
        }
    }

    func testMountedImageRejectsWrongCachedBytesAndRebuildLoadsItsExactDigest() async throws {
        try await withFixture { store, mainURL, mainBytes, wrongBytes, _ in
            let original = store.project, main = try XCTUnwrap(store.project.asset("main"))
            let other = try XCTUnwrap(store.project.asset("other-image"))
            XCTAssertNotEqual(main.sha256, other.sha256)
            try wrongBytes.write(to: mainURL, options: .atomic)
            XCTAssertNotNil(store.assetURL(main), "Equal-size changed bytes must reach the digest verifier")
            let unverified = UIKitAssetImageView(); unverified.configure(url: mainURL, title: "Synthetic unverified cache")
            try await settle(unverified); XCTAssertEqual(unverified.loadPhase, .loaded)
            let controller = timeline(store)
            let picture = try image(label: "01A", in: controller.view)
            let otherPicture = try image(label: "01B", in: controller.view)
            try await settle(picture); XCTAssertEqual(picture.loadPhase, .failed); XCTAssertNil(picture.loadedDigest)
            try await settle(otherPicture); XCTAssertEqual(otherPicture.loadPhase, .loaded); XCTAssertEqual(otherPicture.loadedDigest, other.sha256)
            try mainBytes.write(to: mainURL, options: .atomic)
            // A zoom change is a real rebuild trigger. A plain refresh does
            // not recheck file stamps, and the child image's Retry is not interactive.
            let zoom = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UISlider }.first { $0.accessibilityLabel == "Timeline zoom" })
            zoom.value = 1.5; zoom.sendActions(for: .valueChanged)
            let rebuilt = try image(label: "01A", in: controller.view)
            XCTAssertFalse(rebuilt === picture); XCTAssertFalse(picture.isDescendant(of: controller.view))
            try await settle(rebuilt); XCTAssertEqual(rebuilt.loadPhase, .loaded); XCTAssertEqual(rebuilt.loadedDigest, main.sha256)
            XCTAssertEqual(try Data(contentsOf: mainURL), mainBytes)
            XCTAssertEqual(store.project, original)
        }
    }

    func testMissingAndUnassignedImagesStillMountSelectablePlaceholderTiles() async throws {
        try await withFixture { store, _, _, _, _ in
            store.project.images[0].fileName = "missing-main.png"
            store.project.cues[1].imageId = nil
            let original = store.project, controller = timeline(store)
            XCTAssertEqual(tiles(in: controller.view).count, 2)
            for label in ["01A", "01B"] {
                let picture = try image(label: label, in: controller.view)
                XCTAssertEqual(picture.loadPhase, .empty); XCTAssertEqual(picture.accessibilityValue, "No local image")
                XCTAssertNil(picture.loadedDigest)
                try tile(label: label, in: controller.view).sendActions(for: .touchUpInside)
            }
            XCTAssertEqual(store.selectedCueID, "cue-b"); XCTAssertEqual(store.playheadMs, 2000)
            XCTAssertEqual(store.project, original)
        }
    }

    private func timeline(_ store: WorkspaceStore, expanded: Bool = false) -> LayerTimelineViewController {
        let controller = LayerTimelineViewController(store: store, expanded: expanded)
        controller.loadViewIfNeeded(); controller.view.frame = CGRect(x: 0, y: 0, width: 900, height: 500)
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        return controller
    }
    private func withFixture(_ check: (WorkspaceStore, URL, Data, Data, URL) async throws -> Void) async throws {
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ScrivTimelineMountTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Synthetic.scriv", isDirectory: true)
        let assets = package.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        var mainBytes = png(.blue), otherBytes = png(.green), wrongBytes = png(.red)
        let size = max(mainBytes.count, max(otherBytes.count, wrongBytes.count))
        mainBytes.append(Data(repeating: 0, count: size - mainBytes.count))
        otherBytes.append(Data(repeating: 0, count: size - otherBytes.count))
        wrongBytes.append(Data(repeating: 0, count: size - wrongBytes.count))
        for bytes in [mainBytes, otherBytes, wrongBytes] { XCTAssertNotNil(UIImage(data: bytes)) }
        XCTAssertEqual(Set([mainBytes, otherBytes, wrongBytes].map { ScrivDigest.sha256($0) }).count, 3)
        let mainURL = assets.appendingPathComponent("main.png"), otherURL = assets.appendingPathComponent("other.png")
        try mainBytes.write(to: mainURL); try otherBytes.write(to: otherURL)
        let main = ImageAsset(id: "main", fileName: "main.png", sha256: ScrivDigest.sha256(mainBytes), byteCount: mainBytes.count)
        let other = ImageAsset(id: "other-image", fileName: "other.png", sha256: ScrivDigest.sha256(otherBytes), byteCount: otherBytes.count)
        store.projectURL = package
        store.project = ScrivProject(id: "timeline-mount-fixture", scenes: [ScriptScene(id: "scene"), ScriptScene(id: "other")],
            entries: [ScriptEntry(id: "line", sceneId: "scene", order: 0, kind: .direction, text: "Synthetic scene", ownedDurationMs: 4000, coverageDurationMs: 4000),
                      ScriptEntry(id: "other-line", sceneId: "other", order: 0, kind: .direction, text: "Other synthetic scene", ownedDurationMs: 2000, coverageDurationMs: 2000)],
            images: [main, other], cues: [
                ImageCue(id: "cue-a", sceneId: "scene", imageId: main.id, label: "01A", startMs: 0, endMs: 2000, startAnchor: ScriptTimeAnchor(entryId: "line", offsetMs: 0), authoredDurationMs: 2000),
                ImageCue(id: "cue-b", sceneId: "scene", imageId: other.id, label: "01B", startMs: 2000, endMs: 4000, startAnchor: ScriptTimeAnchor(entryId: "line", offsetMs: 2000), authoredDurationMs: 2000),
                ImageCue(id: "cue-c", sceneId: "other", imageId: other.id, label: "02A", startMs: 500, endMs: 2000, startAnchor: ScriptTimeAnchor(entryId: "other-line", offsetMs: 500), authoredDurationMs: 1500)])
        store.selectedSceneID = "scene"; store.selectedCueID = "cue-a"; store.playheadMs = 0
        try await check(store, mainURL, mainBytes, wrongBytes, otherURL)
    }
    private func tiles(in view: UIView) -> [UIButton] {
        descendants(view).compactMap { $0 as? UIButton }.filter { $0.subviews.contains { $0 is UIKitAssetImageView } }
    }
    private func image(label: String, in view: UIView) throws -> UIKitAssetImageView {
        try XCTUnwrap(descendants(view).compactMap { $0 as? UIKitAssetImageView }.first { picture in
            descendants(picture).contains { ($0 as? UIImageView)?.accessibilityLabel == label }
        })
    }
    private func tile(label: String, in view: UIView) throws -> UIButton { try XCTUnwrap(image(label: label, in: view).superview as? UIButton) }
    private func settle(_ picture: UIKitAssetImageView) async throws {
        for _ in 0..<300 where picture.loadPhase == .loading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotEqual(picture.loadPhase, .loading)
    }
    private func png(_ color: UIColor) -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).pngData { context in color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8)) }
    }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
}
