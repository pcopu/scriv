import UIKit
import XCTest
@testable import ScrivUIKit

/// Native UIKit layout checks only. These do not prove screenshot parity and
/// must not be reported as executed by the source-only cloud review.
@MainActor
final class DiscussionVisualLayoutTests: XCTestCase {
    func testParticipantAvatarKeepsItsRequestedCircularSize() {
        for diameter: CGFloat in [42, 48] {
            let avatar = DiscussionAvatarView(name: "Maya", identity: "member-stable-id", diameter: diameter)
            let fitting = avatar.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
            XCTAssertEqual(fitting.width, diameter, accuracy: 0.5)
            XCTAssertEqual(fitting.height, diameter, accuracy: 0.5)
            XCTAssertEqual(avatar.layer.cornerRadius, diameter / 2, accuracy: 0.5)
        }
    }

    func testAvatarGradientAndInitialFollowActualBounds() throws {
        let avatar = DiscussionAvatarView(name: "Élodie", identity: "member-1", diameter: 48)
        avatar.frame = CGRect(x: 0, y: 0, width: 48, height: 48)
        avatar.setNeedsLayout(); avatar.layoutIfNeeded()
        let gradient = try XCTUnwrap(avatar.layer.sublayers?.compactMap { $0 as? CAGradientLayer }.first)
        XCTAssertEqual(gradient.frame, avatar.bounds)
        XCTAssertEqual(avatar.subviews.compactMap { $0 as? UILabel }.first?.text, "É")
    }

    func testMentionChipsWrapWithoutReplacingOrExceedingTheirContainer() {
        let flow = DiscussionFlowView()
        let chips = (0..<4).map { _ in FixedDiscussionChip() }
        chips.forEach(flow.addChip)
        let identities = flow.subviews.map(ObjectIdentifier.init)
        flow.frame = CGRect(x: 0, y: 0, width: 400, height: 200)
        flow.setNeedsLayout(); flow.layoutIfNeeded()
        let wideHeight = flow.intrinsicContentSize.height
        flow.frame.size.width = 180
        flow.setNeedsLayout(); flow.layoutIfNeeded()
        XCTAssertGreaterThan(flow.intrinsicContentSize.height, wideHeight)
        XCTAssertEqual(flow.subviews.map(ObjectIdentifier.init), identities)
        for chip in chips {
            XCTAssertGreaterThanOrEqual(chip.frame.minX, 0)
            XCTAssertLessThanOrEqual(chip.frame.maxX, flow.bounds.width)
        }
    }

    func testEmptyMentionFlowDoesNotReserveBlankRows() {
        let flow = DiscussionFlowView()
        flow.frame = CGRect(x: 0, y: 0, width: 360, height: 100)
        XCTAssertEqual(flow.intrinsicContentSize.height, 0)
    }
}

@MainActor
private final class FixedDiscussionChip: UIView {
    override func sizeThatFits(_ size: CGSize) -> CGSize { CGSize(width: 90, height: 28) }
}
