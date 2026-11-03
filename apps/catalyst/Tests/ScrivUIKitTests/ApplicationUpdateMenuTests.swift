import UIKit
import XCTest
@testable import ScrivUIKit

@MainActor
final class ApplicationUpdateMenuTests: XCTestCase {
    func testAppProvidesTheStandardSettingsAction() {
        XCTAssertTrue(UIApplication.shared.responds(to: NSSelectorFromString("showSettings:")))
    }

    func testUpdateCommandUsesTheActivePresenterAndReusesItsSheet() async throws {
        let application = UIApplication.shared
        let action = NSSelectorFromString("checkForUpdates:")
        XCTAssertTrue(application.responds(to: action))
        guard application.responds(to: action) else { return }
        let window = try XCTUnwrap(application.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.rootViewController is ScrivWorkspaceController })
        let root = try XCTUnwrap(window.rootViewController)
        window.makeKeyAndVisible()
        let command = UICommand(title: "Check for Updates…", action: action)
        XCTAssertTrue(application.canPerformAction(action, withSender: command))
        XCTAssertTrue(application.sendAction(action, to: nil, from: command, for: nil))
        let visible = await settled { root.presentedViewController is ScrivUpdateController && root.presentedViewController?.isBeingPresented == false }
        XCTAssertTrue(visible)
        let update = try XCTUnwrap(root.presentedViewController as? ScrivUpdateController)
        let done = try XCTUnwrap(descendants(update.view).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "scriv.update.primary" })
        let finished = await settled { done.currentTitle == "Done" || done.configuration?.title == "Done" }
        XCTAssertTrue(finished, "Update sheet: \(descendants(update.view).compactMap { ($0 as? UILabel)?.text })")
        XCTAssertTrue(application.sendAction(action, to: nil, from: command, for: nil))
        XCTAssertTrue(root.presentedViewController === update, "Repeated checks must focus the existing update sheet.")
        done.sendActions(for: .touchUpInside)
        let closed = await settled { root.presentedViewController == nil }
        XCTAssertTrue(closed)
    }

    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap { descendants($0) } }
    private func settled(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }
}
