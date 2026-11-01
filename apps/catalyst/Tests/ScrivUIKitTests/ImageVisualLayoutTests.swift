import UIKit
import XCTest
@testable import ScrivUIKit

/// Real UIKit layout gates. These must run on Mac Catalyst; source parsing on
/// Linux does not prove geometry, font rendering or imagegen visual parity.
@MainActor final class ImageVisualLayoutTests: XCTestCase {
    func testPicturedCharacterChipsWrapWithoutOverlappingOrLosingNames() {
        let names = ["Randy", "Miyazaki", "Farmer Franklin", "An unusually long character name with café and 👩🏽‍🚀"]
        let flow = ImageTagFlowView(names.map { ImageUI.tag($0, color: .systemBlue) })
        flow.frame = CGRect(x: 0, y: 0, width: 240, height: 300)
        flow.layoutIfNeeded()
        let narrowHeight = flow.intrinsicContentSize.height
        XCTAssertEqual(flow.subviews.compactMap(\.accessibilityLabel), names)
        for (index, item) in flow.subviews.enumerated() {
            XCTAssertGreaterThan(item.frame.width, 0)
            XCTAssertLessThanOrEqual(item.frame.maxX, 240.5)
            XCTAssertLessThanOrEqual(item.frame.maxY, narrowHeight + 0.5)
            for other in flow.subviews.dropFirst(index + 1) { XCTAssertFalse(item.frame.intersects(other.frame)) }
        }
        flow.frame.size.width = 900; flow.setNeedsLayout(); flow.layoutIfNeeded()
        XCTAssertLessThan(flow.intrinsicContentSize.height, narrowHeight)
        XCTAssertEqual(flow.subviews.compactMap(\.accessibilityLabel), names)
    }

    func testVeryLongTagUsesMultipleLinesInsideItsMeasuredBounds() {
        let name = String(repeating: "Long exact character identity ", count: 6)
        let tag = ImageUI.tag(name, color: .systemTeal)
        let flow = ImageTagFlowView([tag]); flow.frame = CGRect(x: 0, y: 0, width: 180, height: 500)
        flow.layoutIfNeeded(); tag.layoutIfNeeded()
        XCTAssertEqual(tag.accessibilityLabel, name)
        XCTAssertLessThanOrEqual(tag.frame.width, 180.5)
        XCTAssertGreaterThan(tag.frame.height, 45)
        XCTAssertGreaterThanOrEqual(flow.intrinsicContentSize.height, tag.frame.height)
    }

    func testImageControlsUseCompactExplicitTypographyAndVisibleBorders() throws {
        let button = ImageUI.button("Choose image", symbol: "photo") {}
        let configuration = try XCTUnwrap(button.configuration)
        XCTAssertEqual(configuration.contentInsets.top, 7)
        XCTAssertEqual(configuration.background.cornerRadius, 8)
        XCTAssertGreaterThan(configuration.background.strokeWidth, 0)
        XCTAssertNotNil(configuration.titleTextAttributesTransformer)
        XCTAssertEqual(button.accessibilityLabel, "Choose image")
        ImageUI.compact(button)
        XCTAssertEqual(button.configuration?.contentInsets.top, 5)
        XCTAssertNotNil(button.configuration?.titleTextAttributesTransformer)
    }

    func testFullDirectionTextStillWrapsAndRemainsSelectable() {
        let source = String(repeating: "Franklin looks between the boys and the invoice. 👀\n", count: 8)
        let quote = ImageUI.text(source, size: 14)
        quote.frame = CGRect(x: 0, y: 0, width: 240, height: 40)
        quote.layoutIfNeeded()
        XCTAssertTrue(quote.text.utf16.elementsEqual(source.utf16))
        XCTAssertTrue(quote.isSelectable)
        XCTAssertFalse(quote.isScrollEnabled)
        XCTAssertEqual(quote.textContainer.maximumNumberOfLines, 0)
        XCTAssertGreaterThan(quote.sizeThatFits(CGSize(width: 240, height: CGFloat.greatestFiniteMagnitude)).height, 100)
    }
}
