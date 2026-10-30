import AppKit
import SwiftUI
import XCTest
import ScrivCore
@testable import ScrivApp

/// These exercise real macOS text layout. The Linux package deliberately does
/// not include this target; a portable core pass is not a native layout pass.
final class TextPresentationTests: XCTestCase {
    func testSpeculativeEditorMeasurementsDoNotChangeDrawingWidthOrSelection() async {
        await MainActor.run {
            let view = editor(width: 260)
            let text = String(repeating: "Mara opens the gate slowly. ", count: 16)
            view.string = text
            let selection = NSRange(location: 8, length: 11)
            view.setSelectedRange(selection)
            let before = view.textContainer!.containerSize
            let narrow = view.measuredSize(width: 180, minimumHeight: 25)
            let wide = view.measuredSize(width: 700, minimumHeight: 25)
            XCTAssertGreaterThan(narrow.height, wide.height)
            XCTAssertEqual(narrow.width, 180)
            XCTAssertEqual(wide.width, 700)
            XCTAssertEqual(view.textContainer!.containerSize, before)
            XCTAssertEqual(view.selectedRange(), selection)
            XCTAssertEqual(view.string, text)
        }
    }

    func testActualResizeKeepsAllGlyphsInsideEditorAndPreservesCaret() async {
        await MainActor.run {
            let view = editor(width: 600)
            view.string = String(repeating: "X ", count: 150) + "Mara opens the gate slowly."
            view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
            let selection = view.selectedRange()
            for width in [CGFloat(220), 430, 260] {
                view.setFrameSize(NSSize(width: width, height: 500))
                view.layoutSubtreeIfNeeded()
                let container = view.textContainer!, manager = view.layoutManager!
                manager.ensureLayout(for: container)
                XCTAssertEqual(container.containerSize.width, width, accuracy: 0.5)
                XCTAssertLessThanOrEqual(manager.usedRect(for: container).maxX, width + 0.5)
                XCTAssertEqual(manager.glyphRange(for: container).length, manager.numberOfGlyphs)
                XCTAssertEqual(view.selectedRange(), selection)
            }
        }
    }

    func testEditorMeasurementIncludesTrailingEmptyLine() async {
        await MainActor.run {
            let view = editor(width: 260)
            view.string = "One line"
            let single = view.measuredSize(width: 260, minimumHeight: 25)
            view.string += "\n"
            let withEmptyLine = view.measuredSize(width: 260, minimumHeight: 25)
            XCTAssertGreaterThan(withEmptyLine.height, single.height)
        }
    }

    @MainActor func testLinkedScriptTextRetainsFullHeightUnderCompressedProposal() async {
        _ = NSApplication.shared
        let measured = expectation(description: "Native SwiftUI text measured")
        var observed = CGSize.zero
        var fulfilled = false
        let source = "We can move these words without moving the picture. Mara opens the gate slowly."
        let character = ScriptCharacter(id: "mara", name: "Mara")
        let range = (source as NSString).range(of: "Mara")
        let link = CharacterTextLink(characterId: character.id, location: range.location, length: range.length, text: "Mara")
        // A vertically constrained row previously caused Text to use an
        // ellipsis. Width remains constrained, while authored text reports
        // its complete wrapped height to the surrounding row/rail layout.
        let content = LinkedScriptText(text: source, characters: [character], characterLinks: [link], size: 20) { _ in }
        let host = NSHostingView(rootView: content.background {
            GeometryReader { proxy in Color.clear.preference(key: TextSizePreference.self, value: proxy.size) }
        }.onPreferenceChange(TextSizePreference.self) { size in
            observed = size
            if size.height > 0, !fulfilled { fulfilled = true; measured.fulfill() }
        }.frame(width: 240, height: 24))
        host.setFrameSize(NSSize(width: 240, height: 24))
        host.layoutSubtreeIfNeeded()
        await fulfillment(of: [measured], timeout: 3)
        XCTAssertGreaterThan(observed.height, 60)
        XCTAssertEqual(observed.width, 240, accuracy: 1)
        XCTAssertEqual(CharacterMentions.resolved(in: source, links: [link]).first?.range, range)
        withExtendedLifetime(host) {}
    }

    func testImageAvailabilityIsNotReportedBeforeTheCurrentLoadFinishes() async {
        await MainActor.run {
            let first = URL(fileURLWithPath: "/fixture/first.png"), second = URL(fileURLWithPath: "/fixture/second.png")
            let loaded = AssetImageLoadResult(url: first, image: NSImage(size: NSSize(width: 1, height: 1)))
            let failed = AssetImageLoadResult(url: first, image: nil)
            XCTAssertEqual(AssetImageLoadResult.phase(for: nil, result: nil), .empty)
            XCTAssertEqual(AssetImageLoadResult.phase(for: first, result: nil), .loading)
            XCTAssertEqual(AssetImageLoadResult.phase(for: first, result: loaded), .loaded)
            XCTAssertEqual(AssetImageLoadResult.phase(for: first, result: failed), .failed)
            XCTAssertEqual(AssetImageLoadResult.phase(for: second, result: failed), .loading)
            XCTAssertEqual(AssetImageLoadResult.phase(for: second, result: loaded), .loading)
            XCTAssertEqual(AssetImageLoadResult.phase(for: nil, result: loaded), .empty)
            // Retry clears the completed result instead of retaining a failure.
            XCTAssertEqual(AssetImageLoadResult.phase(for: first, result: nil), .loading)
        }
    }

    @MainActor private func editor(width: CGFloat) -> ScriptNativeTextView {
        let view = ScriptNativeTextView(frame: NSRect(x: 0, y: 0, width: width, height: 500))
        view.font = .systemFont(ofSize: 20)
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.heightTracksTextView = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.layoutSubtreeIfNeeded()
        return view
    }
}

private struct TextSizePreference: PreferenceKey {
    static var defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}
