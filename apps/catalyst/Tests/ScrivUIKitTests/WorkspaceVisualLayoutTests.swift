import UIKit
import XCTest
import ScrivCore
@testable import ScrivUIKit

/// Real UIKit geometry tests. Portable source checks do not execute these or
/// replace the required Catalyst screenshots at normal and minimum window sizes.
@MainActor
final class WorkspaceVisualLayoutTests: XCTestCase {
    func testTabsStayCenteredWithLongProjectNamesAtSupportedWidths() {
        for width in [CGFloat(1_032), 1_280, 1_448, 1_800] {
            let header = layoutHeader(width: width, account: nil)
            let frame = header.tabs.frame
            let alignment = header.tabs.alignmentRect(forFrame: frame)
            let diagnostic = "width=\(width) frame=\(frame) alignment=\(alignment) insets=\(header.tabs.alignmentRectInsets)"
            print("SCRIV_HEADER_LAYOUT " + diagnostic)
            // UIKit constraints apply to alignment rectangles. Two native runs
            // showed frame=49 for a48 constraint and frame=50 for a49 constraint.
            // Assert the actual constrained geometry AND the approved optical
            // frame; do not loosen tolerance or inflate the production height.
            XCTAssertEqual(alignment.height, 48, accuracy: 0.5, diagnostic)
            XCTAssertEqual(alignment.midX, width / 2, accuracy: 0.5, diagnostic)
            XCTAssertEqual(alignment.midY, header.bounds.midY, accuracy: 0.5, diagnostic)
            XCTAssertEqual(frame.midX, width / 2, accuracy: 0.5, diagnostic)
            XCTAssertEqual(frame.height, 49, accuracy: 0.5, diagnostic)
            XCTAssertGreaterThanOrEqual(frame.minY, 0, diagnostic)
            XCTAssertLessThanOrEqual(frame.maxY, header.bounds.height, diagnostic)
            XCTAssertLessThanOrEqual(header.tabs.frame.width, 420.5)
            let title = header.titleButton.convert(header.titleButton.bounds, to: header)
            let search = header.searchButton.convert(header.searchButton.bounds, to: header)
            XCTAssertLessThanOrEqual(title.maxX + 20, header.tabs.frame.minX)
            XCTAssertGreaterThanOrEqual(search.minX - 20, header.tabs.frame.maxX)
            XCTAssertGreaterThan(title.width, 40)
            XCTAssertEqual(header.titleButton.configuration?.subtitle, "Scriv")
        }
    }

    func testCollaborationControlsReflowWithoutMovingTabsOrLosingOverflow() {
        let header = layoutHeader(width: 1_600, account: String(repeating: "Long name ", count: 8))
        XCTAssertFalse(header.accountButton.isHidden)
        XCTAssertFalse(header.codexButton.isHidden)
        XCTAssertTrue(header.searchButton.isHidden)
        for width in [CGFloat(1_032), 1_600, 1_280, 1_800] {
            header.frame.size.width = width; header.setNeedsLayout(); header.layoutIfNeeded(); header.layoutIfNeeded()
            XCTAssertEqual(header.tabs.frame.midX, width / 2, accuracy: 0.5)
            XCTAssertFalse(header.moreButton.isHidden)
            XCTAssertNotNil(header.moreButton.superview)
            XCTAssertEqual(header.accountButton.isHidden, width < 1_440)
            let first = width < 1_440 ? header.searchButton : header.accountButton
            let frame = first.convert(first.bounds, to: header)
            XCTAssertGreaterThanOrEqual(frame.minX, header.tabs.frame.maxX + 23)
        }
    }

    func testHeaderActionsRemainNativeAccessibleControls() {
        let header = layoutHeader(width: 1_280, account: nil)
        for button in [header.searchButton, header.shareButton, header.moreButton] {
            XCTAssertFalse(button.accessibilityLabel?.isEmpty ?? true)
            XCTAssertEqual(button.bounds.width, 48, accuracy: 0.5)
            XCTAssertEqual(button.bounds.height, 48, accuracy: 0.5)
        }
        var actions = 0
        header.searchButton.addAction(UIAction { _ in actions += 1 }, for: .primaryActionTriggered)
        header.searchButton.sendActions(for: .primaryActionTriggered)
        header.searchButton.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(actions, 2)
    }

    func testOneTransportOwnerPerTabAndBalancedScriptSplit() {
        XCTAssertTrue(ScrivWorkspaceLayout.usesFooterTransport(for: .script))
        XCTAssertTrue(ScrivWorkspaceLayout.usesFooterTransport(for: .characters))
        XCTAssertTrue(ScrivWorkspaceLayout.usesFooterTransport(for: .storyboard))
        XCTAssertEqual(ScrivWorkspaceLayout.scriptPanelRatio, 1.1)
    }

    func testNarrowDiscussionDoesNotCrushTwoWorkPanelsIntoTinyColumns() {
        XCTAssertTrue(ScrivWorkspaceLayout.stacksWorkPanels(availableWidth: 620, discussionVisible: true, tab: .script))
        XCTAssertTrue(ScrivWorkspaceLayout.stacksWorkPanels(availableWidth: 620, discussionVisible: true, tab: .characters))
        XCTAssertFalse(ScrivWorkspaceLayout.stacksWorkPanels(availableWidth: 1_040, discussionVisible: true, tab: .script))
        XCTAssertFalse(ScrivWorkspaceLayout.stacksWorkPanels(availableWidth: 620, discussionVisible: false, tab: .script))
        XCTAssertFalse(ScrivWorkspaceLayout.stacksWorkPanels(availableWidth: 620, discussionVisible: true, tab: .storyboard))
    }

    func testApprovedPaletteHasReadableLightAndExplicitDarkText() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            let panel = ScrivUIKitTheme.panel.resolvedColor(with: traits)
            let inset = ScrivUIKitTheme.inset.resolvedColor(with: traits)
            let ink = ScrivUIKitTheme.ink.resolvedColor(with: traits)
            let secondary = ScrivUIKitTheme.secondary.resolvedColor(with: traits)
            XCTAssertGreaterThanOrEqual(contrast(ink, panel), 7)
            XCTAssertGreaterThanOrEqual(contrast(secondary, panel), 4.5)
            XCTAssertGreaterThanOrEqual(contrast(secondary, inset), 4.5)
        }
        XCTAssertEqual(ScrivUIKitTheme.label("Navy heading").textColor, ScrivUIKitTheme.ink)
    }

    func testSharedCommandLabelsUseConfigurationFontAndDoNotWrap() {
        let button = ScrivUIKitTheme.button("Generate image", symbol: "sparkles") {}
        XCTAssertNotNil(button.configuration?.titleTextAttributesTransformer)
        XCTAssertEqual(button.configuration?.titleLineBreakMode, .byTruncatingTail)
        XCTAssertEqual(button.titleLabel?.numberOfLines, 1)
        XCTAssertEqual(button.accessibilityLabel, "Generate image")
    }

    private func layoutHeader(width: CGFloat, account: String?) -> ScrivWorkspaceHeader {
        let header = ScrivWorkspaceHeader(frame: CGRect(x: 0, y: 0, width: width, height: 64))
        header.configure(title: String(repeating: "A long project title 🙂 ", count: 12), accountName: account)
        header.layoutIfNeeded(); header.layoutIfNeeded()
        return header
    }
    private func contrast(_ a: UIColor, _ b: UIColor) -> CGFloat {
        func luminance(_ color: UIColor) -> CGFloat {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, alpha: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &alpha)
            func linear(_ value: CGFloat) -> CGFloat { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        }
        let first = luminance(a), second = luminance(b)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }
}
