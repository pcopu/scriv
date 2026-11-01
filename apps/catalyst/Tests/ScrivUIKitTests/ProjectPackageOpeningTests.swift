import UIKit
import UniformTypeIdentifiers
import XCTest
import ScrivCore
@testable import ScrivUIKit

/// Requires Catalyst/Foundation, not a Linux source-text assertion. External
/// picker authorization and a fresh-process reopen remain native manual gates.
@MainActor
final class ProjectPackageOpeningTests: XCTestCase {
    func testInstalledAppRegistersAnEditablePackage() throws {
        let declarations = try XCTUnwrap(Bundle.main.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]])
        let project = try XCTUnwrap(declarations.first { ($0["LSItemContentTypes"] as? [String])?.contains("app.scriv.project") == true })
        XCTAssertEqual(project["CFBundleTypeRole"] as? String, "Editor")
        XCTAssertEqual(project["LSHandlerRank"] as? String, "Owner")
        XCTAssertEqual(Bundle.main.infoDictionary?["LSSupportsOpeningDocumentsInPlace"] as? Bool, true)
        XCTAssertTrue(UIKitFileAccess.projectType.conforms(to: .package))
    }

    func testExportedPackageReopensViaBookmarkWithExactIdentityEditsAndImages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ScrivPackageTest-" + UUID().uuidString, isDirectory: true)
        let suiteName = "ScrivPackageTest." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suiteName) }
        let repository = try ProjectRepository(root: root)
        var expected = ScrivProject.example()
        let original = await repository.defaultURL(for: expected)
        let imageBytes = Data([137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3, 4])
        var asset = try await repository.importAsset(data: imageBytes, at: original, characterIds: ["character-randy"])
        asset.generationPrompt = "Exact original generation text\nKeep this distinct from manual direction."
        expected.images.append(asset); expected.cues[0].imageId = asset.id
        try await repository.save(expected, at: original, label: "Original")
        try ProjectEditing.deleteEntry(&expected, entryId: "line-02")
        expected.revision = 1; expected.title = "Exported with authored edits"
        try await repository.save(expected, at: original, label: "Edit before export")
        let export = root.appendingPathComponent("Exported package.scriv", isDirectory: true)
        try await repository.copyPackage(from: original, to: export)
        let originalBytes = try Data(contentsOf: original.appendingPathComponent("project.json"))
        XCTAssertEqual(try Data(contentsOf: export.appendingPathComponent("project.json")), originalBytes)

        let pickerAccess = UIKitFileAccess(defaults: defaults)
        try pickerAccess.rememberProject(export)
        // New manager forces resolution from saved data rather than retained URL.
        let reopenedAccess = UIKitFileAccess(defaults: defaults)
        let reopenedURL = try reopenedAccess.restoreProjectAccess(export)
        XCTAssertEqual(reopenedURL.standardizedFileURL.path, export.standardizedFileURL.path)
        let reopened = try await repository.load(at: reopenedURL)
        let history = try await repository.history(at: reopenedURL)
        let recoveredBytes = try await repository.assetData(asset, at: reopenedURL)
        XCTAssertEqual(reopened, expected)
        XCTAssertEqual(reopened.images.first(where: { $0.id == asset.id })?.generationPrompt, asset.generationPrompt)
        XCTAssertEqual(history.map(\.revision), [1, 0])
        XCTAssertNotNil(history.last?.snapshot.entries.first(where: { $0.id == "line-02" }))
        XCTAssertEqual(recoveredBytes, imageBytes)
        XCTAssertEqual(try Data(contentsOf: original.appendingPathComponent("project.json")), originalBytes)
        XCTAssertEqual(try Data(contentsOf: export.appendingPathComponent("project.json")), originalBytes)
    }

    func testFailureReportsStageAndErrorCodesWithoutDumpingPrivateUserInfo() throws {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: 1, userInfo: ["private": "DO_NOT_INCLUDE"])
        let source = NSError(domain: NSCocoaErrorDomain, code: 256, userInfo: [NSLocalizedDescriptionKey: "The selected package could not be opened.", NSUnderlyingErrorKey: underlying, "bookmarkBytes": "DO_NOT_INCLUDE"])
        for stage in ProjectOpeningFailure.Stage.allCases {
            let failure = try XCTUnwrap(ProjectOpeningFailure.annotating(source, stage: stage) as? ProjectOpeningFailure)
            let message = try XCTUnwrap(failure.errorDescription)
            XCTAssertTrue(message.contains(stage.rawValue))
            XCTAssertTrue(message.contains("NSCocoaErrorDomain 256"))
            XCTAssertTrue(message.contains("NSPOSIXErrorDomain 1"))
            XCTAssertFalse(message.contains("DO_NOT_INCLUDE"))
            XCTAssertTrue((failure.underlying as NSError) === source)
        }
    }

    func testCancelledNavigationDoesNotBecomeAnOpenError() {
        for stage in ProjectOpeningFailure.Stage.allCases {
            XCTAssertTrue(ProjectOpeningFailure.annotating(CancellationError(), stage: stage) is CancellationError)
        }
    }
}
