import UIKit
import XCTest
import ScrivCore
@testable import ScrivUIKit

/// Synthetic, isolated native diagnostics, not AX/CUA or audible-playback proof.
/// Run the same tests on the frozen baseline and candidate to compare metrics.
@MainActor
final class PlaybackResponsivenessTests: XCTestCase {
    func testNoAudioPlaybackYieldsToMainQueueAndRepeatedPauseStopsClock() async throws {
        let store = try isolatedStore()
        store.project = fixture(count: 24, withCue: true)
        store.selectedSceneID = "scene"
        store.selectedEntryID = store.sceneEntries.first?.id
        let workspace = ScrivWorkspaceController(store: store)
        workspace.loadViewIfNeeded()
        workspace.view.frame = CGRect(x: 0, y: 0, width: 1448, height: 900)
        workspace.view.layoutIfNeeded()
        let original = store.project
        XCTAssertTrue(original.audioAssets.isEmpty)
        XCTAssertTrue(original.audioClips.isEmpty)
        defer { if store.isPlaying { store.togglePlayback() } }
        for iteration in 0..<3 {
            let before = store.playheadMs
            let heartbeat = expectation(description: "Main queue heartbeat during silent playback \(iteration)")
            store.togglePlayback()
            XCTAssertTrue(store.isPlaying)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { heartbeat.fulfill() }
            await fulfillment(of: [heartbeat], timeout: 3)
            XCTAssertGreaterThan(store.playheadMs, before)
            XCTAssertTrue(store.isPlaying)
            store.togglePlayback()
            let paused = store.playheadMs
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertFalse(store.isPlaying)
            XCTAssertEqual(store.playheadMs, paused)
            XCTAssertEqual(store.project, original, "Playback/rendering must not alter timing, images, audio or saved project fields")
        }
        withExtendedLifetime(workspace) {}
    }

    func testWordHighlightRefreshesAcrossSeeksWithoutReplacingRows() throws {
        let store = try isolatedStore()
        store.project = fixture(count: 3); store.selectedSceneID = "scene"
        let controller = ScriptScreenController(store: store)
        controller.loadViewIfNeeded()
        var pending = [controller.view!], rows: [String: ScriptEntryRow] = [:]
        while let view = pending.popLast() {
            if let row = view as? ScriptEntryRow { rows[row.entryID] = row }
            pending.append(contentsOf: view.subviews)
        }
        let identities = rows.mapValues { ObjectIdentifier($0.display) }
        let original = store.project
        for entry in store.sceneEntries where entry.kind == .dialogue {
            let word = try XCTUnwrap(entry.words.first)
            store.seek(toMs: Double(store.project.startMs(of: entry.id) + word.startMs))
            controller.storeDidChange()
            XCTAssertEqual(store.currentWordID, word.id)
            for (id, row) in rows {
                let color = row.display.attributedText.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
                if id == entry.id { XCTAssertEqual(color, .white) }
                else { XCTAssertNotEqual(color, .white) }
                XCTAssertEqual(ObjectIdentifier(row.display), identities[id])
            }
            XCTAssertEqual(store.project, original)
        }
    }

    func testRailEndpointsAndOverlapMenusMatchUncachedReferenceAfterEditsAndReflow() throws {
        let store = try isolatedStore()
        var project = fixture(count: 30)
        store.project = project; store.selectedSceneID = "scene"
        let rails = ScriptDirectionRails(store: store)
        for pass in 0..<3 {
            if pass == 1 {
                project.entries[1].ownedDurationMs += 1_234
                project.entries[0].coverageDurationMs += 2_500
            }
            store.project = project
            store.selectedEntryID = project.entries[pass * 6].id
            rails.presentation = pass == 2 ? .compact : .expanded
            let entries = store.sceneEntries
            let frames: [String: CGRect] = Dictionary(uniqueKeysWithValues: entries.enumerated().map { index, entry in
                let height = CGFloat(pass == 2 ? 94 : 140)
                return (entry.id, CGRect(x: 0, y: CGFloat(index) * height, width: 700, height: height - 20))
            })
            rails.frame = CGRect(x: 0, y: 0, width: 740, height: 5000)
            rails.update(entries: entries, frames: frames)
            rails.setNeedsLayout(); rails.layoutIfNeeded()
            let rows = entries.map { entry in
                let frame = frames[entry.id]!
                return ScriptRailRow(startMs: project.startMs(of: entry.id), durationMs: entry.ownedDurationMs,
                    anchorY: Double(frame.minY + rails.presentation.anchorOffset),
                    bottomY: Double(frame.maxY + rails.presentation.rowSpacing))
            }
            func endpoint(_ entry: ScriptEntry) -> CGFloat {
                max(frames[entry.id]!.minY + rails.presentation.anchorOffset + 12,
                    CGFloat(PresentationGeometry.railPosition(at: project.startMs(of: entry.id) + entry.coverageDurationMs, rows: rows)))
            }
            let directions = entries.filter { $0.kind == .direction }
            for entry in directions {
                let button = try XCTUnwrap(rails.subviews.compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == entry.id })
                XCTAssertEqual(button.frame.midY, endpoint(entry), accuracy: 0.001)
                XCTAssertEqual(button.accessibilityValue, ScrivFormat.time(project.startMs(of: entry.id) + entry.coverageDurationMs))
                let expected = directions.filter { endpoint(entry) >= frames[$0.id]!.minY + 12 && endpoint(entry) <= endpoint($0) + 14 }
                let actions = try XCTUnwrap(button.menu).children.compactMap { $0 as? UIAction }
                XCTAssertEqual(actions.map(\.title), expected.map(\.text))
                XCTAssertEqual(actions.filter { $0.state == .on }.map(\.title), expected.filter { $0.id == store.selectedEntryID }.map(\.text))
            }
            XCTAssertEqual(store.project, project)
        }
    }

    /// No platform-independent speed threshold: retain the xctresult metrics and
    /// compare both versions on the same Mac/configuration. No file I/O is timed.
    func testProfileSyntheticScriptPlaybackRenderPasses() throws {
        let store = try isolatedStore()
        store.project = fixture(count: 96); store.selectedSceneID = "scene"
        let controller = ScriptScreenController(store: store)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 800, height: 900)
        controller.view.layoutIfNeeded()
        let original = store.project
        store.isPlaying = true
        defer { store.isPlaying = false }
        measure(metrics: [XCTClockMetric()]) {
            for tick in 0..<12 {
                store.playheadMs = Double(tick * 16)
                controller.storeDidChange()
                controller.view.layoutIfNeeded()
            }
        }
        XCTAssertEqual(store.project, original)
    }

    private func isolatedStore() throws -> WorkspaceStore {
        guard ProcessInfo.processInfo.arguments.contains("--screenshots") else {
            throw XCTSkip("Requires the isolated --screenshots test launch argument; never use a real project")
        }
        return WorkspaceStore()
    }

    private func fixture(count: Int, withCue: Bool = false) -> ScrivProject {
        // Keep construction deliberately staged. The Catalyst test compiler
        // cannot type-check the nested map/ternary initializer in bounded time.
        var entries: [ScriptEntry] = []
        entries.reserveCapacity(count)
        var duration = 0
        for index in 0..<count {
            let isDirection: Bool = index % 6 == 0
            let id: String = "entry-\(index)"
            let kind: EntryKind = isDirection ? .direction : .dialogue
            let text: String
            if isDirection { text = "Synthetic direction \(index)" }
            else { text = "Synthetic dialogue \(index) with a timed word." }
            let owned: Int = isDirection ? 0 : 2_000
            let coverage: Int = isDirection ? 12_000 : 0
            let entry = ScriptEntry(id: id, sceneId: "scene", order: Double(index),
                kind: kind, text: text, ownedDurationMs: owned, coverageDurationMs: coverage)
            entries.append(entry)
            duration += entry.ownedDurationMs
        }
        var cues: [ImageCue] = []
        if withCue && duration > 0 {
            let cue = ImageCue(id: "synthetic-cue", sceneId: "scene", label: "Synthetic scene",
                startMs: 0, endMs: duration, prompt: "Synthetic test direction")
            cues.append(cue)
        }
        let scene = ScriptScene(id: "scene")
        return ScrivProject(id: "synthetic-playback-profile", scenes: [scene], entries: entries, cues: cues)
    }
}
