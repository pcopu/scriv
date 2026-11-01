import UIKit
import XCTest
@testable import ScrivUIKit

/// Screenshot-fed B1002 regressions. Synthetic state only; no pairing, account,
/// server, clipboard, files or model turns are used by these layout checks.
@MainActor
final class CodexNativeModalParityTests: XCTestCase {
    func testReferenceWidthFooterDoesNotConsumeAnExtraBodyRow() throws {
        let setup = makeView()
        let jobs = try button("jobs", in: setup), history = try button("history", in: setup)
        let links = try XCTUnwrap(jobs.superview as? UIStackView)
        for width in [CGFloat(584), 420, 584] {
            setup.frame = CGRect(x: 0, y: 0, width: width, height: 614)
            layout(setup)
            XCTAssertEqual(links.axis, width == 584 ? .horizontal : .vertical)
            let jobsRect = jobs.convert(jobs.bounds, to: setup), historyRect = history.convert(history.bounds, to: setup)
            XCTAssertFalse(jobsRect.intersects(historyRect))
            if width == 584 {
                XCTAssertEqual(jobsRect.midY, historyRect.midY, accuracy: 1)
                let advanced = try button("advanced", in: setup)
                assertVisibleInBody(advanced, setup: setup)
                XCTAssertLessThanOrEqual(setup.scroll.contentSize.height, setup.scroll.bounds.height + 1)
            }
            XCTAssertLessThanOrEqual(setup.scroll.frame.maxY, setup.footer.frame.minY)
        }
    }

    func testOpeningHelpAfterScrollingRevealsHeadingAndDoesNotStartRuntime() throws {
        let setup = makeView(); setup.frame = CGRect(x: 0, y: 0, width: 584, height: 614)
        var checks = 0, starts = 0, connects = 0
        setup.onCheck = { checks += 1 }; setup.onStart = { starts += 1 }; setup.onConnect = { connects += 1 }
        layout(setup)
        setup.scroll.setContentOffset(CGPoint(x: 0, y: 90), animated: false)
        try button("installation-help", in: setup).sendActions(for: .primaryActionTriggered)
        layout(setup)
        let headline = try XCTUnwrap(descendants(setup).first { $0.accessibilityIdentifier == "codex-setup-headline" } as? UILabel)
        XCTAssertEqual(headline.text, "Get Codex ready")
        XCTAssertEqual(setup.scroll.contentOffset.y, -setup.scroll.adjustedContentInset.top, accuracy: 0.5)
        assertVisibleInBody(headline, setup: setup)
        XCTAssertFalse(descendants(setup).compactMap { $0 as? UILabel }.contains {
            $0.text == "Checks your saved local endpoint. A paired local runtime can be started for you." && !$0.isHidden
        }, "The idle explanation must not add another row to the installation state.")
        XCTAssertEqual(checks, 0); XCTAssertEqual(starts, 0); XCTAssertEqual(connects, 0)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: setup.bounds.size, format: format).image { context in setup.layer.render(in: context.cgContext) }
        let attachment = XCTAttachment(image: image); attachment.name = "Codex-B1002-help-candidate"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testOpeningAdvancedRevealsAddressAndRepeatedRefreshKeepsDraftAndViewport() throws {
        let endpoint = AccountUI.field("endpoint", height: 32)
        endpoint.text = "ws://127.0.0.1:9999"
        let setup = makeView(endpoint: endpoint)
        setup.frame = CGRect(x: 0, y: 0, width: 420, height: 600)
        layout(setup)
        try button("advanced", in: setup).sendActions(for: .primaryActionTriggered)
        layout(setup); assertVisibleInBody(endpoint, setup: setup)
        let beforeOffset = setup.scroll.contentOffset.y
        for _ in 0..<3 {
            setup.update(.init(), error: nil, journalError: nil, log: "")
            layout(setup)
            XCTAssertEqual(setup.scroll.contentOffset.y, beforeOffset, accuracy: 1)
            XCTAssertEqual(endpoint.text, "ws://127.0.0.1:9999")
            XCTAssertTrue(endpoint.isDescendant(of: setup.advancedContent))
        }
        try button("advanced", in: setup).sendActions(for: .primaryActionTriggered)
        layout(setup)
        XCTAssertNil(setup.advancedContent.superview)
        assertVisibleInBody(try button("advanced", in: setup), setup: setup)
    }

    func testNewConnectionPhaseReturnsToHeadingWithoutChangingFields() throws {
        let endpoint = AccountUI.field("endpoint", height: 32); endpoint.text = "ws://127.0.0.1:9999"
        let setup = makeView(endpoint: endpoint); setup.frame = CGRect(x: 0, y: 0, width: 420, height: 600)
        layout(setup)
        try button("advanced", in: setup).sendActions(for: .primaryActionTriggered); layout(setup)
        XCTAssertGreaterThan(setup.scroll.contentOffset.y, 0)
        setup.update(.init(checkPhase: .notFound), error: nil, journalError: nil, log: "")
        layout(setup)
        XCTAssertEqual(setup.scroll.contentOffset.y, -setup.scroll.adjustedContentInset.top, accuracy: 0.5)
        XCTAssertEqual(endpoint.text, "ws://127.0.0.1:9999")
        XCTAssertTrue(endpoint.isDescendant(of: setup.advancedContent))
        XCTAssertLessThanOrEqual(setup.scroll.frame.maxY, setup.footer.frame.minY)
        XCTAssertLessThanOrEqual(setup.header.frame.maxY, setup.scroll.frame.minY)
    }

    private func assertVisibleInBody(_ child: UIView, setup: ScrivCodexSetupView, file: StaticString = #filePath, line: UInt = #line) {
        let rect = child.convert(child.bounds, to: setup)
        XCTAssertGreaterThanOrEqual(rect.minY, setup.scroll.frame.minY - 0.5, file: file, line: line)
        XCTAssertLessThanOrEqual(rect.maxY, setup.scroll.frame.maxY + 0.5, file: file, line: line)
        XCTAssertGreaterThan(child.bounds.height, 0, file: file, line: line)
    }
    private func layout(_ setup: ScrivCodexSetupView) {
        for _ in 0..<8 { setup.setNeedsLayout(); setup.layoutIfNeeded(); setup.scroll.layoutIfNeeded(); setup.body.layoutIfNeeded() }
    }
    private func makeView(endpoint: UITextField? = nil) -> ScrivCodexSetupView {
        let progress = UIView(); progress.isHidden = true
        return ScrivCodexSetupView(executable: AccountUI.field("executable", height: 32), endpoint: endpoint ?? AccountUI.field("endpoint", height: 32), progress: progress)
    }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    private func button(_ id: String, in view: UIView) throws -> UIButton {
        try XCTUnwrap(descendants(view).first { $0.accessibilityIdentifier == "codex-" + id } as? UIButton)
    }
}
