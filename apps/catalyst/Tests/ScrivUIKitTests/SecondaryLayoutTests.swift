import XCTest
import UIKit
@testable import ScrivUIKit

/// These checks require UIKit on the Mac. Source-contract checks on Linux are
/// intentionally separate and do not certify rendered layout or visual parity.
@MainActor final class SecondaryLayoutTests: XCTestCase {
    func testAccountActionsStaySingleLineAndResistCaptionCompression() {
        for title in ["Cancel", "Apply", "Save timing", "Inspect existing turn", "Use in original project"] {
            let button = AccountUI.button(title) {}
            XCTAssertEqual(button.titleLabel?.numberOfLines, 1)
            XCTAssertEqual(button.configuration?.titleLineBreakMode, .byTruncatingTail)
            XCTAssertEqual(button.contentCompressionResistancePriority(for: .horizontal), .required)
            XCTAssertGreaterThan(button.intrinsicContentSize.width, 45)
        }
    }

    func testNarrowFooterMovesCopyAboveActionsWithoutRecreatingControls() {
        let copy = AccountUI.label("Trimming changes this clip, not the recording.", size: 11)
        let cancel = AccountUI.button("Cancel") {}, apply = AccountUI.button("Apply", primary: true) {}
        cancel.widthAnchor.constraint(greaterThanOrEqualToConstant: 86).isActive = true
        apply.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        let actions = AccountUI.stack([UIView(), cancel, apply], spacing: 10, horizontal: true)
        let row = ScrivSecondaryAdaptiveRow([copy, actions], minimumHorizontalWidth: 460)
        row.updateLayout(for: 420)
        XCTAssertEqual(row.axis, .vertical)
        XCTAssertTrue(row.arrangedSubviews[0] === copy)
        XCTAssertTrue(actions.arrangedSubviews[1] === cancel)
        XCTAssertTrue(actions.arrangedSubviews[2] === apply)
        row.updateLayout(for: 600)
        XCTAssertEqual(row.axis, .horizontal)
        XCTAssertTrue(row.arrangedSubviews[1] === actions)
        XCTAssertEqual(cancel.configuration?.title, "Cancel")
        XCTAssertEqual(apply.configuration?.title, "Apply")
    }

    func testResponsiveLayoutPreservesInProgressTextAndSelection() {
        let field = AccountUI.field("Source in", height: 32)
        field.text = "1.234"
        let row = ScrivSecondaryAdaptiveRow([AccountUI.label("Source in"), field], minimumHorizontalWidth: 460)
        for width in [CGFloat(320), 900, 420, 680] {
            row.updateLayout(for: width)
            XCTAssertEqual(field.text, "1.234")
            XCTAssertTrue(row.arrangedSubviews[1] === field)
            XCTAssertFalse(field.isHidden)
        }
    }

    func testGenerationActionsWrapWholeButtonsAtNarrowWidths() {
        let wrap = CharacterChipWrapView()
        let buttons = ["Open image", "Use in original project", "Inspect existing turn", "Retry…", "View details"].map { AccountUI.button($0) {} }
        wrap.chips = buttons
        wrap.frame = CGRect(x: 0, y: 0, width: 320, height: 300)
        wrap.layoutIfNeeded()
        XCTAssertGreaterThan(Set(buttons.map { $0.frame.minY }).count, 1)
        for button in buttons {
            XCTAssertEqual(button.titleLabel?.numberOfLines, 1)
            XCTAssertLessThanOrEqual(button.frame.maxX, 320)
            XCTAssertGreaterThanOrEqual(button.frame.width, button.intrinsicContentSize.width - 1)
        }
    }

    func testPrecisionControlsKeepTransientInvalidTextWithoutSilentRounding() {
        let field = AudioSecondsField(title: "Source in", accessibilityName: "Source in", maximumMs: 10000, identifier: "test-source-in")
        field.text = "1."
        field.frame = CGRect(x: 0, y: 0, width: 180, height: 70)
        field.layoutIfNeeded()
        XCTAssertEqual(field.text, "1.")
        XCTAssertEqual(field.textField.accessibilityIdentifier, "test-source-in")
        XCTAssertEqual(field.textField.accessibilityLabel, "Source in, seconds")
    }
}
