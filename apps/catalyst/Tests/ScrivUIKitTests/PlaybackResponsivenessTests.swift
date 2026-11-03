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
        // Startup must not land after the fixture and replace it mid-test.
        while store.isBootstrapping { await Task.yield() }
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
            rails.presentation = pass == 2 ? ScriptPresentationMetrics(paneWidth: 930) : .expanded
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
                let button = try XCTUnwrap(rails.subviews.compactMap { $0 as? DirectionHandleButton }.first { $0.accessibilityIdentifier == entry.id })
                XCTAssertNil(button.menu, "A press-and-hold menu would swallow coverage drags that start with a pause")
                XCTAssertEqual(button.frame.midY, endpoint(entry), accuracy: 0.001)
                XCTAssertEqual(button.accessibilityValue, ScrivFormat.time(project.startMs(of: entry.id) + entry.coverageDurationMs))
                let expected = directions.filter { endpoint(entry) >= frames[$0.id]!.minY + 12 && endpoint(entry) <= endpoint($0) + 14 }
                let actions = try XCTUnwrap(button.overlapMenu).children.compactMap { $0 as? UIAction }
                XCTAssertEqual(actions.map(\.title), expected.map(\.text))
                XCTAssertEqual(actions.filter { $0.state == .on }.map(\.title), expected.filter { $0.id == store.selectedEntryID }.map(\.text))
            }
            XCTAssertEqual(store.project, project)
        }
    }

    /// Fixed-work diagnostics, not an XCTest baseline or a speed threshold.
    /// Compare versions with this same harness on the same Mac/configuration.
    /// The original 0...176 ms ticks exercise steady-state first-word refreshes,
    /// not word-boundary transitions, visible frame delivery or audible playback.
    func testProfileSyntheticScriptPlaybackRenderPasses() async throws {
        let store = try isolatedStore()
        // Settle startup before installing the fixture, outside the timed work.
        let bootstrapDeadline = ProcessInfo.processInfo.systemUptime + 5
        while store.isBootstrapping && ProcessInfo.processInfo.systemUptime < bootstrapDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard !store.isBootstrapping else {
            XCTFail("Isolated startup must finish before installing the playback fixture")
            return
        }
        store.project = fixture(count: 96); store.selectedSceneID = "scene"
        let controller = ScriptScreenController(store: store)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 800, height: 900)
        controller.view.layoutIfNeeded()
        let original = store.project
        let entryIDs = store.sceneEntries.map(\.id)
        let wordIDs = store.sceneEntries.flatMap { $0.words.map(\.id) }
        let selectedEntryID = store.selectedEntryID
        func rowIdentities() -> [String: [ObjectIdentifier]] {
            var pending = [controller.view!], identities: [String: [ObjectIdentifier]] = [:]
            while let view = pending.popLast() {
                if let row = view as? ScriptEntryRow {
                    identities[row.entryID] = [ObjectIdentifier(row), ObjectIdentifier(row.display)]
                }
                pending.append(contentsOf: view.subviews)
            }
            return identities
        }
        let originalRows = rowIdentities()
        let expectedWord = try XCTUnwrap(TimingEngine.absoluteWords(original, sceneId: "scene").first {
            $0.startMs <= 176 && 176 < $0.endMs
        })
        XCTAssertEqual(entryIDs.count, 96)
        XCTAssertEqual(Set(originalRows.keys), Set(entryIDs))
        XCTAssertTrue(original.audioAssets.isEmpty)
        XCTAssertTrue(original.audioClips.isEmpty)
        store.isPlaying = true
        defer { store.isPlaying = false }
        // A native sample stalled in XCTest metric-reporting symbolization,
        // after the render body. Its underlying file-open cause remains unknown.
        // Keep the work and raw durations without invoking that reporting path.
        // Batch zero is the first (cold) timed batch after initial view layout;
        // retain it separately from ten measured batches. Do not time assertions,
        // attachment encoding, logging, file I/O or asynchronous settling.
        var durations: [Double] = [], batchTickCounts: [Int] = []
        durations.reserveCapacity(11); batchTickCounts.reserveCapacity(11)
        for batch in 0..<11 {
            var completedTicks = 0
            let started = ProcessInfo.processInfo.systemUptime
            for tick in 0..<12 {
                store.playheadMs = Double(tick * 16)
                controller.storeDidChange()
                controller.view.layoutIfNeeded()
                completedTicks += 1
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            durations.append(elapsed); batchTickCounts.append(completedTicks)
            XCTAssertTrue(elapsed.isFinite && elapsed > 0, "Batch \(batch) must retain a valid elapsed duration")
            XCTAssertEqual(completedTicks, 12)
            XCTAssertEqual(store.project, original, "Playback/rendering must not alter saved project fields")
            XCTAssertEqual(store.sceneEntries.map(\.id), entryIDs)
            XCTAssertEqual(store.sceneEntries.flatMap { $0.words.map(\.id) }, wordIDs)
            XCTAssertEqual(rowIdentities(), originalRows, "Playback refreshes must retain row and text-view identity")
            XCTAssertEqual(store.selectedSceneID, "scene")
            XCTAssertEqual(store.selectedEntryID, selectedEntryID)
            XCTAssertEqual(store.playheadMs, 176)
            XCTAssertEqual(store.currentWordID, expectedWord.id)
            XCTAssertTrue(store.isPlaying)
        }
        XCTAssertEqual(durations.count, 11)
        XCTAssertEqual(batchTickCounts.reduce(0, +), 132)
        let measured = Array(durations.dropFirst())
        XCTAssertEqual(measured.count, 10)
        let mean = measured.reduce(0, +) / Double(measured.count)
        let report: [String: Any] = [
            "schemaVersion": 1, "harness": "fixed-work-monotonic-v1",
            "clock": "ProcessInfo.systemUptime", "unit": "seconds",
            "fixtureEntryCount": entryIDs.count, "viewportWidth": 800, "viewportHeight": 900,
            "tickSpacingMs": 16, "finalPlayheadMs": store.playheadMs,
            "coldMeaning": "First timed batch after initial view layout",
            "coldSeconds": durations[0], "measuredSeconds": measured,
            "rawBatchSeconds": durations, "batchTickCounts": batchTickCounts,
            "sampleCount": durations.count, "totalTicks": batchTickCounts.reduce(0, +),
            "measuredMeanSeconds": mean,
            "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
            "processorCount": ProcessInfo.processInfo.processorCount,
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "appBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        ]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "synthetic-script-playback-fixed-work-v1.json"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("Playback fixed-work profile: 96 rows, 11 batches x 12 ticks; cold=\(durations[0])s, measured mean=\(mean)s; raw samples retained in \(attachment.name ?? "JSON attachment")")
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
