import Foundation
import XCTest
import ScrivCore
#if canImport(ScrivApp)
@testable import ScrivApp
#endif

/// Foundation-only presentation tests also run with the Linux harness. The
/// native SwiftUI layout and sheet interaction still require the Mac app gate.
final class ProjectHistoryPresentationTests: XCTestCase {
    func testDirectionHistoryShowsOwnedTimeAndCoverageBeforeRestore() throws {
        let scene = ScriptScene(id: "scene", title: "Scene")
        let lead = ScriptEntry(id: "lead", sceneId: scene.id, order: 0, text: "Before", ownedDurationMs: 30_300)
        let direction = ScriptEntry(id: "direction", sceneId: scene.id, order: 1, kind: .direction, text: "Franklin looks between the boys and the invoice.", ownedDurationMs: 2_000, coverageDurationMs: 4_800)
        let tail = ScriptEntry(id: "tail", sceneId: scene.id, order: 2, text: "After", ownedDurationMs: 5_000)
        let before = ScrivProject(id: "p", scenes: [scene], entries: [lead, direction, tail])
        var after = before; after.entries[1].ownedDurationMs = 2_400; after.entries[1].coverageDurationMs = 5_200
        let change = try XCTUnwrap(HistoryPresentation.localChanges(before: before, after: after).first { $0.id == direction.id })
        let fields = HistoryPresentation.fields(for: change, beforeProject: before, afterProject: after)
        XCTAssertEqual(fields.first { $0.label == "Owned time" }?.before, "2.0 s")
        XCTAssertEqual(fields.first { $0.label == "Owned time" }?.after, "2.4 s")
        XCTAssertEqual(fields.first { $0.label == "Coverage" }?.before, "30.3–35.1 s")
        XCTAssertEqual(fields.first { $0.label == "Coverage" }?.after, "30.3–35.5 s")
        XCTAssertEqual(before.entries[1].ownedDurationMs, 2_000, "Inspection must not mutate the original snapshot")
    }

    func testLocalTitleAndAudioChangesAreNotLostInCloudItemDiff() throws {
        let before = ScrivProject(id: "p", title: "Old title")
        var after = before; after.title = "New title"; after.audioVolume = 0.5
        after.audioAssets = [AudioAsset(id: "audio", fileName: "a.wav", sha256: String(repeating: "a", count: 64), byteCount: 16, durationMs: 1_000, sampleRate: 44_100, channelCount: 1, waveform: [], originalName: "Dialogue.wav")]
        let changes = HistoryPresentation.localChanges(before: before, after: after)
        let metadata = try XCTUnwrap(changes.first { $0.after?.kind == "project" })
        XCTAssertEqual(HistoryPresentation.fields(for: metadata, beforeProject: before, afterProject: after).first { $0.label == "Title" }?.after, "New title")
        XCTAssertTrue(changes.contains { $0.after?.kind == "audioAsset" })
    }

    func testExactUnicodeTextRemainsReadableAndRemovedItemsAreExplicit() throws {
        let old = CloudItem(id: "entry", kind: "entry", data: .object(["text": .string("Miyazaki 👩🏽‍🚀\nCafé"), "kind": .string("dialogue")]))
        let new = CloudItem(id: "entry", kind: "entry", data: .object(["text": .string("Miyazaki 👩🏽‍🚀\nCafé encore"), "kind": .string("dialogue")]))
        let change = CloudChange(id: "entry", before: old, after: new)
        let text = try XCTUnwrap(HistoryPresentation.fields(for: change, beforeProject: nil, afterProject: nil).first { $0.label == "Text" })
        XCTAssertEqual(text.before, "Miyazaki 👩🏽‍🚀\nCafé")
        XCTAssertEqual(text.after, "Miyazaki 👩🏽‍🚀\nCafé encore")
        XCTAssertEqual(HistoryPresentation.operation(for: CloudChange(id: old.id, before: old, after: nil)), "Removed")
        XCTAssertEqual(HistoryPresentation.operation(for: CloudChange(id: old.id, before: nil, after: old)), "Added")
    }

    func testWordTimingComparisonShowsExactMillisecondsNotOnlyCounts() throws {
        let oldWords: JSONValue = .array([.object(["text": .string("Hello"), "startMs": .number(0), "endMs": .number(500), "timingSource": .string("authored")])])
        let newWords: JSONValue = .array([.object(["text": .string("Hello"), "startMs": .number(25), "endMs": .number(525), "timingSource": .string("authored")])])
        let change = CloudChange(id: "e", before: CloudItem(id: "e", kind: "entry", data: .object(["words": oldWords])), after: CloudItem(id: "e", kind: "entry", data: .object(["words": newWords])))
        let field = try XCTUnwrap(HistoryPresentation.fields(for: change, beforeProject: nil, afterProject: nil).first { $0.label == "Word timing" })
        XCTAssertNotEqual(field.before, field.after)
        XCTAssertTrue(field.after.contains("0.025 s"))
        XCTAssertTrue(field.after.contains("0.525 s"))
        XCTAssertTrue(field.after.contains("authored"))
    }

    func testRecoveryHighlightPreservesUnicodeClustersAndNoOpDraft() throws {
        let before = "Miyazaki 👩🏽‍🚀 says café.", after = "Miyazaki 👨🏾‍🚀 says café."
        let changed = try XCTUnwrap(RecoveredDraftComparison.changedRange(in: after, comparedTo: before))
        XCTAssertEqual((after as NSString).substring(with: changed), "👨🏾‍🚀")
        XCTAssertNotNil(Range(changed, in: after))
        XCTAssertNil(RecoveredDraftComparison.changedRange(in: before, comparedTo: before))
        XCTAssertNil(RecoveredDraftComparison.changedRange(in: "", comparedTo: before))
        XCTAssertEqual(RecoveredDraftComparison.changedRange(in: "New", comparedTo: ""), NSRange(location: 0, length: 3))
    }

    func testUnchangedRevisionHasNoInventedDelta() {
        let project = ScrivProject(id: "p", title: "Project")
        XCTAssertTrue(HistoryPresentation.localChanges(before: project, after: project).isEmpty)
        var later = project; later.revision = 1; later.modifiedAt = project.modifiedAt.addingTimeInterval(1)
        XCTAssertTrue(HistoryPresentation.localChanges(before: project, after: later).isEmpty)
    }

    func testBrowserReadsRealLocalMetadataWithoutSavingOrInventingCover() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let project = ScrivProject(id: "p", title: "Actual local title", scenes: [ScriptScene(id: "s", title: "One")])
        let bytes = try ScrivJSON.encoder.encode(project)
        try bytes.write(to: root.appendingPathComponent("project.json"))
        let summary = ProjectBrowserLocalSummary.load(at: root)
        XCTAssertEqual(summary.project?.title, "Actual local title")
        XCTAssertEqual(summary.project?.scenes.count, 1)
        XCTAssertNil(summary.thumbnailURL)
        XCTAssertNil(summary.issue)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("project.json")), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["project.json"])
    }

    func testBrowserRejectsSymlinkedProjectMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let package = root.appendingPathComponent("test.scriv")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let external = root.appendingPathComponent("outside.json")
        try ScrivJSON.encoder.encode(ScrivProject(id: "p", title: "Outside")).write(to: external)
        try FileManager.default.createSymbolicLink(at: package.appendingPathComponent("project.json"), withDestinationURL: external)
        let summary = ProjectBrowserLocalSummary.load(at: package)
        XCTAssertNil(summary.project)
        XCTAssertNotNil(summary.issue)
        XCTAssertNil(summary.thumbnailURL)
    }
}
