import XCTest
import UIKit
import ScrivCore
@testable import ScrivUIKit

/// Real Catalyst layout/behavior gates. These are not executed by portable Node
/// contracts and require the isolated --screenshots verification profile.
@MainActor final class StoryboardInlineScriptTests: XCTestCase {
    func testPartitionKeepsSourceOrderAcrossEqualStartsGapsAndImportedTiming() {
        XCTAssertEqual(StoryboardSharedScriptLayout.rowIndices(wordStarts: [-1, 0, 3999, 4000, 8000, 10000], rowStarts: [0, 4000, 4000, 8000]), [0, 0, 0, 1, 3, 3])
        XCTAssertEqual(StoryboardSharedScriptLayout.rowIndices(wordStarts: [1, 9000, 1000, 12000], rowStarts: [0, 4000, 8000]), [0, 2, 2, 2])
        XCTAssertEqual(StoryboardSharedScriptLayout.rowIndices(wordStarts: [0, 1000], rowStarts: [5000]), [0, 0])
        XCTAssertEqual(StoryboardSharedScriptLayout.rowIndices(wordStarts: [0, 1000], rowStarts: []), [0, 0])
        XCTAssertEqual(StoryboardSharedScriptLayout.rowIndices(wordStarts: [], rowStarts: [0, 5000]), [])
    }

    func testFirstScriptStripIsBelowFirstPicturesNotAfterTwentyPlacements() throws {
        let store = try isolatedStore()
        store.project = fixture(); store.selectedSceneID = "scene"
        let original = store.project
        let controller = StoryboardViewController(store: store)
        controller.loadViewIfNeeded()
        for size in [CGSize(width: 1448, height: 900), CGSize(width: 900, height: 800), CGSize(width: 560, height: 800)] {
            controller.view.frame = CGRect(origin: .zero, size: size); settle(controller.view)
            let scroll = try XCTUnwrap(find("storyboard-scroll", in: controller.view) as? UIScrollView)
            scroll.setContentOffset(.zero, animated: false); settle(controller.view)
            let firstPictures = try XCTUnwrap(find("storyboard-picture-row-0", in: controller.view))
            let secondPictures = try XCTUnwrap(find("storyboard-picture-row-1", in: controller.view))
            let strip = try XCTUnwrap(find("storyboard-shared-script", in: controller.view))
            let firstWord = try XCTUnwrap(strip.subviews.first)
            let pictureFrame = firstPictures.convert(firstPictures.bounds, to: scroll)
            let stripFrame = strip.convert(strip.bounds, to: scroll)
            let secondFrame = secondPictures.convert(secondPictures.bounds, to: scroll)
            XCTAssertGreaterThanOrEqual(stripFrame.minY, pictureFrame.maxY)
            XCTAssertLessThan(stripFrame.maxY, secondFrame.minY)
            XCTAssertTrue(scroll.bounds.contains(firstWord.convert(firstWord.bounds, to: scroll)), "The initial words must be visible without traversing the full grid")
            assertExactWords(store: store, controller: controller)
            XCTAssertEqual(store.project, original)
        }
    }

    func testOverlappingCrossRowCoverageAndPlayheadRemainIndependentThroughReflow() throws {
        let store = try isolatedStore()
        store.project = fixture(); store.selectedSceneID = "scene"; store.selectedCueID = "cue-0"
        let original = store.project
        let controller = StoryboardViewController(store: store)
        controller.loadViewIfNeeded(); controller.view.frame = CGRect(x: 0, y: 0, width: 1448, height: 900); settle(controller.view)
        let targetEntry = try XCTUnwrap(store.sceneEntries.last)
        let target = try XCTUnwrap(targetEntry.words.last)
        let time = Double(store.project.startMs(of: targetEntry.id) + target.startMs)
        let before = wordButtons(in: controller.view).map { ObjectIdentifier($0) }
        store.seek(toMs: time); store.selectedCueID = "cue-0"; controller.storeDidChange(); settle(controller.view)
        let button = try XCTUnwrap(find("storyboard-word-" + target.id, in: controller.view) as? UIButton)
        XCTAssertEqual(button.accessibilityValue, "Playhead word")
        XCTAssertEqual(wordButtons(in: controller.view).map { ObjectIdentifier($0) }, before, "A playhead tick must not rebuild the word stream")
        button.sendActions(for: .touchUpInside); controller.storeDidChange()
        XCTAssertEqual(store.selectedWordIDs, [target.id])
        XCTAssertEqual(store.selectedCueID, "cue-0", "A selected overlapping picture spanning later rows must remain the word's transfer target")
        XCTAssertEqual(store.playheadMs, time)
        XCTAssertFalse(store.isPlaying)
        for width in [900.0, 560.0, 1448.0] {
            controller.view.frame.size.width = CGFloat(width); settle(controller.view)
            assertExactWords(store: store, controller: controller)
            XCTAssertEqual(store.selectedWordIDs, [target.id])
            XCTAssertEqual(store.selectedCueID, "cue-0")
            XCTAssertEqual(store.playheadMs, time)
            let active = try XCTUnwrap(find("storyboard-word-" + target.id, in: controller.view) as? UIButton)
            XCTAssertTrue(active.accessibilityTraits.contains(.selected))
            XCTAssertEqual(active.accessibilityValue, "Playhead word")
        }
        let escape = try XCTUnwrap(controller.keyCommands?.first { $0.input == UIKeyCommand.inputEscape })
        _ = controller.perform(escape.action)
        XCTAssertTrue(store.selectedWordIDs.isEmpty)
        XCTAssertEqual(store.project, original, "Layout, selection and playback decoration must never change image bytes, source wording or timing")
    }

    func testNoPicturesStillShowsAllWordsAndEmptySceneClearsOldWordControls() throws {
        let store = try isolatedStore()
        var project = fixture(); project.cues = []
        store.project = project; store.selectedSceneID = "scene"
        let controller = StoryboardViewController(store: store)
        controller.loadViewIfNeeded(); controller.view.frame = CGRect(x: 0, y: 0, width: 560, height: 800); settle(controller.view)
        assertExactWords(store: store, controller: controller)
        XCTAssertNotNil(find("storyboard-shared-script", in: controller.view))
        XCTAssertEqual(store.project, project)
        project.entries = []; store.project = project
        controller.storeDidChange(); settle(controller.view)
        XCTAssertTrue(wordButtons(in: controller.view).isEmpty)
        XCTAssertEqual(store.project, project)
    }

    func testLongScriptAndLongUnicodeWordRemainReachableAfterNarrowReflow() throws {
        let store = try isolatedStore()
        var project = fixture(entryCount: 100)
        let lastEntry = project.entries.count - 1
        project.entries[lastEntry].words[1].text = String(repeating: "長いcafe\u{301}👩🏽‍🚀", count: 16)
        project.entries[lastEntry].text = project.entries[lastEntry].words.map(\.text).joined(separator: " ")
        store.project = project; store.selectedSceneID = "scene"
        let controller = StoryboardViewController(store: store)
        controller.loadViewIfNeeded()
        for width in [1448.0, 560.0] {
            controller.view.frame = CGRect(x: 0, y: 0, width: CGFloat(width), height: 800); settle(controller.view)
            assertExactWords(store: store, controller: controller)
            let scroll = try XCTUnwrap(find("storyboard-scroll", in: controller.view) as? UIScrollView)
            let lastWord = try XCTUnwrap(wordButtons(in: controller.view).last)
            scroll.scrollRectToVisible(lastWord.convert(lastWord.bounds, to: scroll), animated: false)
            settle(controller.view)
            XCTAssertTrue(scroll.bounds.contains(lastWord.convert(lastWord.bounds, to: scroll)))
            XCTAssertEqual(store.project, project)
        }
    }

    private func isolatedStore() throws -> WorkspaceStore {
        guard ProcessInfo.processInfo.arguments.contains("--screenshots") else {
            throw XCTSkip("Requires --screenshots; never inspect a real project")
        }
        return WorkspaceStore()
    }
    private func fixture(entryCount: Int = 20) -> ScrivProject {
        var entries: [ScriptEntry] = [], cues: [ImageCue] = []
        for index in 0..<entryCount {
            let words = [TimedWord(id: "w-\(index)-0", text: "cafe\u{301}", startMs: 0, endMs: 400),
                         TimedWord(id: "w-\(index)-1", text: "日本語👩🏽‍🚀", startMs: 400, endMs: 1000)]
            entries.append(ScriptEntry(id: "entry-\(index)", sceneId: "scene", order: Double(index), text: "cafe\u{301} 日本語👩🏽‍🚀", ownedDurationMs: 1000, words: words))
            guard index < 20 else { continue }
            let start = index < 2 ? 0 : index * 1000
            let end = index == 0 ? entryCount * 1000 : min(entryCount * 1000, start + 2500)
            cues.append(ImageCue(id: "cue-\(index)", sceneId: "scene", label: "Picture \(index)", startMs: start, endMs: end))
        }
        return ScrivProject(id: "synthetic-inline-storyboard", scenes: [ScriptScene(id: "scene")], entries: entries, cues: cues)
    }
    private func descendants(_ root: UIView) -> [UIView] { [root] + root.subviews.flatMap(descendants) }
    private func find(_ id: String, in root: UIView) -> UIView? { descendants(root).first { $0.accessibilityIdentifier == id } }
    private func wordButtons(in root: UIView) -> [UIButton] {
        descendants(root).compactMap { $0 as? UIButton }.filter { $0.accessibilityIdentifier?.hasPrefix("storyboard-word-") == true }
    }
    private func assertExactWords(store: WorkspaceStore, controller: StoryboardViewController, file: StaticString = #filePath, line: UInt = #line) {
        let words = store.sceneEntries.flatMap(\.words)
        let buttons = wordButtons(in: controller.view)
        XCTAssertEqual(buttons.compactMap(\.accessibilityIdentifier), words.map { "storyboard-word-" + $0.id }, file: file, line: line)
        XCTAssertEqual(buttons.compactMap { $0.title(for: .normal) }, words.map(\.text), file: file, line: line)
        XCTAssertEqual(Set(buttons.compactMap(\.accessibilityIdentifier)).count, words.count, file: file, line: line)
        for flow in descendants(controller.view).filter({ $0.accessibilityIdentifier?.hasPrefix("storyboard-shared-script") == true }) {
            for (index, button) in flow.subviews.enumerated() {
                XCTAssertGreaterThan(button.bounds.height, 0, file: file, line: line)
                XCTAssertLessThanOrEqual(button.frame.maxX, flow.bounds.width + 0.5, file: file, line: line)
                XCTAssertLessThanOrEqual(button.frame.maxY, flow.bounds.height + 0.5, file: file, line: line)
                for other in flow.subviews.dropFirst(index + 1) { XCTAssertFalse(button.frame.intersects(other.frame), file: file, line: line) }
            }
        }
    }
    private func settle(_ root: UIView, file: StaticString = #filePath, line: UInt = #line) {
        var previous: [CGRect] = [], stable = 0
        for _ in 0..<16 {
            root.setNeedsLayout(); root.layoutIfNeeded()
            let geometry = descendants(root).flatMap { [$0.frame, $0.bounds] }
            stable = geometry == previous ? stable + 1 : 0
            if stable == 2 { return }
            previous = geometry
        }
        XCTFail("Storyboard layout did not settle; native reachability remains unverified", file: file, line: line)
    }
}
