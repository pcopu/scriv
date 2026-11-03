import UIKit
import XCTest
import ScrivCore
@testable import ScrivUIKit

@MainActor
final class CharacterImageReviewTests: XCTestCase {
    private final class EscapeProbe: ScrivScreenController {
        var closeCount = 0
        override func closeFromEscape() { closeCount += 1 }
    }
    private final class Provider: CharacterImageAnalysisProvider {
        let providerID = "synthetic-test"
        var availability: String?
        var requests: [CharacterImageAnalysisRequest] = []
        var delayed = false
        var error: Error?
        var continuation: CheckedContinuation<CharacterImageAnalysisResult,Error>?
        func analyze(_ request: CharacterImageAnalysisRequest) async throws -> CharacterImageAnalysisResult {
            requests.append(request)
            if let error { throw error }
            if delayed { return try await withCheckedThrowingContinuation { continuation = $0 } }
            return response
        }
        var response: CharacterImageAnalysisResult { .init(detections:[.init(region:.init(x:0.1,y:0.1,width:0.3,height:0.4),characterID:"mara",confidence:0.99)]) }
    }
    /// These synthetic stores mutate `project` directly (bypassing the accepted
    /// revision chain), so a later save is correctly refused and its error alert
    /// lands on the host app's frontmost window, where it would block every later
    /// test's sheet. Let saves settle, then remove the packages and any such alert.
    private var fixtures: [(WorkspaceStore,URL)] = []
    override func tearDown() async throws {
        for (store,root) in fixtures { await store.flushPendingSaves(); try? FileManager.default.removeItem(at:root) }
        fixtures = []
        try await Task.sleep(for:.milliseconds(300))
        for window in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows) {
            var top = window.rootViewController
            while let next = top?.presentedViewController { top = next }
            if let alert = top as? UIAlertController, alert.title == "Scriv" { alert.dismiss(animated: false) }
        }
        try await super.tearDown()
    }
    private func storeFixture() async throws -> (WorkspaceStore,URL) {
        guard ProcessInfo.processInfo.arguments.contains("--screenshots") else { throw XCTSkip("Requires isolated --screenshots storage, never a real-user store.") }
        let store = WorkspaceStore()
        // Let startup finish first: a slow bootstrap otherwise lands after the
        // fixture project below and replaces it, so the scan never sees the
        // test image (an intermittent failure on a loaded Mac).
        while store.isBootstrapping { await Task.yield() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("scriv")
        let assets = root.appendingPathComponent("assets",isDirectory:true); try FileManager.default.createDirectory(at:assets,withIntermediateDirectories:true)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let data = UIGraphicsImageRenderer(size:CGSize(width:120,height:100),format:format).pngData { context in UIColor.systemBlue.setFill(); context.fill(CGRect(x:0,y:0,width:120,height:100)) }
        try data.write(to:assets.appendingPathComponent("synthetic.png"))
        let image = ImageAsset(id:"image",fileName:"synthetic.png",sha256:ScrivDigest.sha256(data),byteCount:data.count)
        store.projectURL = root; store.project = ScrivProject(id:UUID().uuidString,characters:[ScriptCharacter(id:"mara",name:"Mara")],images:[image])
        fixtures.append((store,root))
        return (store,root)
    }
    private func settle(_ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertTrue(condition())
    }
    func testUnavailableProviderNeverReceivesProjectImages() async throws {
        let (store,root) = try await storeFixture()
        let provider = Provider(); provider.availability = "Image analysis transport is unavailable."
        let controller = CharacterAnalysisController(store:store,provider:provider,pendingDirectory:root.appendingPathComponent("pending"))
        controller.refresh(); try await Task.sleep(for:.milliseconds(50))
        XCTAssertTrue(provider.requests.isEmpty); XCTAssertEqual(controller.status,provider.availability)
    }
    func testConnectedSyntheticProviderScansOnceAndResumesAfterNewVersion() async throws {
        let (store,root) = try await storeFixture()
        let provider = Provider(), controller = CharacterAnalysisController(store:store,provider:provider,pendingDirectory:root.appendingPathComponent("pending"))
        controller.refresh(); try await settle { store.project.images[0].characterAnalysis != nil }
        controller.refresh(); try await Task.sleep(for:.milliseconds(50))
        XCTAssertEqual(provider.requests.count,1); XCTAssertEqual(store.project.images[0].characterIds,["mara"])
        var version = store.project.images[0]; version.id = "version-two"; version.version = 2; version.previousVersionId = "image"; version.characterAnalysis = nil
        store.project.images.append(version); controller.refresh(); try await settle { store.project.images[1].characterAnalysis != nil }
        XCTAssertEqual(provider.requests.count,2); XCTAssertEqual(provider.requests[1].imageID,"version-two")
    }
    func testUnexpectedActivityPausesWholeQueueAcrossReconnectAndReopenUntilExplicitRetry() async throws {
        let (store,root) = try await storeFixture()
        let key = "ScrivCharacterAnalysisInterruption.v1." + store.project.id
        defer { UserDefaults.standard.removeObject(forKey:key) }
        var second = store.project.images[0]; second.id = "second"; store.project.images.append(second)
        let provider = Provider(); provider.error = CharacterAnalysisInterruption(reason:"Unexpected tool activity; review original turn.")
        let controller = CharacterAnalysisController(store:store,provider:provider,pendingDirectory:root.appendingPathComponent("pending"))
        controller.refresh(); try await settle { controller.failureCount == 1 }
        XCTAssertEqual(provider.requests.count,1); XCTAssertTrue(store.project.images.allSatisfy { $0.characterAnalysis == nil })
        provider.availability = "Disconnected"; controller.refresh()
        provider.availability = nil; controller.refresh(); try await Task.sleep(for:.milliseconds(50))
        XCTAssertEqual(provider.requests.count,1,"Reconnect must not replay an uncertain turn")
        let reopened = CharacterAnalysisController(store:store,provider:provider,pendingDirectory:root.appendingPathComponent("pending"))
        reopened.refresh(); try await Task.sleep(for:.milliseconds(50)); XCTAssertEqual(provider.requests.count,1)
        provider.error = nil; reopened.scanAgain(); try await settle { store.project.images.allSatisfy { $0.characterAnalysis != nil } }
        XCTAssertEqual(provider.requests.count,3); XCTAssertNil(UserDefaults.standard.string(forKey:key))
    }
    func testPendingMarkerPrecedesProviderAndBlocksReopenUntilExplicitRetry() async throws {
        let (store,root) = try await storeFixture()
        let pending = root.appendingPathComponent("pending")
        let key = "ScrivCharacterAnalysisInterruption.v1." + store.project.id
        defer { UserDefaults.standard.removeObject(forKey:key) }
        let provider = Provider(); provider.delayed = true
        let controller = CharacterAnalysisController(store:store,provider:provider,pendingDirectory:pending)
        controller.refresh(); try await settle { provider.continuation != nil }
        let files = try FileManager.default.contentsOfDirectory(at:pending,includingPropertiesForKeys:nil)
        XCTAssertEqual(files.count,1); XCTAssertFalse(try Data(contentsOf:files[0]).isEmpty)
        let reopened = CharacterAnalysisController(store:store,provider:provider,pendingDirectory:pending)
        reopened.refresh(); try await Task.sleep(for:.milliseconds(50))
        XCTAssertEqual(provider.requests.count,1); XCTAssertTrue(reopened.status.contains("previous character scan"))
        controller.pause(); provider.continuation?.resume(returning:provider.response); provider.continuation = nil
        try await Task.sleep(for:.milliseconds(50)); XCTAssertNil(store.project.images[0].characterAnalysis)
        reopened.refresh(); XCTAssertEqual(provider.requests.count,1)
        provider.delayed = false; reopened.scanAgain(); try await settle { store.project.images[0].characterAnalysis != nil }
        XCTAssertEqual(provider.requests.count,2); XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:pending.path).isEmpty)
    }
    func testPendingMarkerWriteFailureNeverCallsProvider() async throws {
        let (store,root) = try await storeFixture()
        let invalidDirectory = root.appendingPathComponent("not-a-directory")
        try Data([1]).write(to:invalidDirectory)
        let key = "ScrivCharacterAnalysisInterruption.v1." + store.project.id
        defer { UserDefaults.standard.removeObject(forKey:key) }
        let provider = Provider(), controller = CharacterAnalysisController(store:store,provider:provider,pendingDirectory:invalidDirectory)
        controller.refresh(); try await settle { controller.failureCount == 1 }
        XCTAssertTrue(provider.requests.isEmpty); XCTAssertTrue(controller.status.contains("No analysis was submitted"))
    }
    func testLateCancelledResultCannotTagAnotherProject() async throws {
        let (store,root) = try await storeFixture()
        let provider = Provider(); provider.delayed = true
        let controller = CharacterAnalysisController(store:store,provider:provider,pendingDirectory:root.appendingPathComponent("pending"))
        controller.refresh(); try await settle { provider.continuation != nil }
        controller.pause(); store.project = ScrivProject(id:"other-project")
        provider.continuation?.resume(returning:provider.response); provider.continuation = nil
        try await Task.sleep(for:.milliseconds(50)); XCTAssertTrue(store.project.images.isEmpty); XCTAssertTrue(store.project.characters.isEmpty)
    }
    func testReviewControllerHasRealAssignIgnoreSkipActionsWithoutMutationOnOpen() async throws {
        let (store,root) = try await storeFixture()
        let image = store.project.images[0]
        try CharacterImageAnalysis.apply(.init(detections:[.init(region:.init(x:0.1,y:0.1,width:0.3,height:0.4),kind:.obscured,confidence:0.4,reason:"Face obscured · needs your help")]),to:&store.project,imageID:image.id,version:image.version,sha256:image.sha256,providerID:"synthetic")
        let before = store.project, controller = CharacterImageReviewController(store:store)
        controller.loadViewIfNeeded()
        for size in [CGSize(width:760,height:930),CGSize(width:480,height:700)] {
            controller.view.frame = CGRect(origin:.zero,size:size); controller.view.layoutIfNeeded()
            let controls = descendants(controller.view).compactMap { $0 as? UIButton }
            XCTAssertTrue(controls.contains { $0.accessibilityIdentifier == "character-review-save" && !$0.isEnabled })
            XCTAssertTrue(controls.contains { $0.accessibilityIdentifier == "character-review-ignore" })
            XCTAssertTrue(controls.contains { $0.currentTitle == "Skip for now" || $0.configuration?.title == "Skip for now" })
        }
        XCTAssertEqual(store.project,before,"Opening, resizing and dismissing review are not edits")
    }
    func testNavigationWrappedSheetEscapeHonorsBothChildAndContainerSaveLocks() async throws {
        let (store, _) = try await storeFixture()
        // UIKit exposes a navigation child's modal policy through its wrapper.
        // The original shared handler must therefore work for either lock owner,
        // without assuming the child and container flags are independent.
        for lockChild in [true, false] {
            let screen = EscapeProbe(store: store)
            let navigation = UINavigationController(rootViewController: screen)
            XCTAssertFalse(screen.isModalInPresentation)
            XCTAssertFalse(navigation.isModalInPresentation)
            let owner = lockChild ? "child" : "navigation container"
            if lockChild { screen.isModalInPresentation = true }
            else { navigation.isModalInPresentation = true }
            XCTAssertTrue(navigation.isModalInPresentation, "The effective navigation policy reflects the \(owner) lock")
            screen.scrivEscapeSheet()
            XCTAssertEqual(screen.closeCount, 0, "Escape must respect the \(owner) save lock")
            screen.scrivEscapeSheet()
            XCTAssertEqual(screen.closeCount, 0, "Repeated Escape must also respect the \(owner) save lock")
            screen.isModalInPresentation = false; navigation.isModalInPresentation = false
            XCTAssertFalse(navigation.isModalInPresentation)
            screen.scrivEscapeSheet()
            XCTAssertEqual(screen.closeCount, 1, "Escape works after the \(owner) lock is released")
        }
        let unwrapped = EscapeProbe(store: store)
        unwrapped.isModalInPresentation = true
        unwrapped.scrivEscapeSheet()
        XCTAssertEqual(unwrapped.closeCount, 0)
        unwrapped.isModalInPresentation = false
        unwrapped.scrivEscapeSheet()
        XCTAssertEqual(unwrapped.closeCount, 1)
    }
    func testDerivedCropLeavesOriginalBytesUntouchedAndCachesByRegion() async throws {
        let (store,root) = try await storeFixture()
        let image = store.project.images[0], source = try XCTUnwrap(store.assetURL(image)), before = try Data(contentsOf:source)
        let region = NormalizedCharacterRegion(x:0.1,y:0.2,width:0.3,height:0.4)
        let crop = try await CharacterPortraitCache.thumbnail(source:source,sha256:image.sha256,region:region)
        XCTAssertNotEqual(crop,source); XCTAssertEqual(try Data(contentsOf:source),before)
        let cached = try await CharacterPortraitCache.thumbnail(source:source,sha256:image.sha256,region:region)
        XCTAssertEqual(cached,crop)
        let bitmap = try XCTUnwrap(UIImage(contentsOfFile:crop.path)?.cgImage)
        XCTAssertEqual(bitmap.width,36); XCTAssertEqual(bitmap.height,40)
    }
    private func descendants(_ root: UIView) -> [UIView] { [root] + root.subviews.flatMap(descendants) }
}
