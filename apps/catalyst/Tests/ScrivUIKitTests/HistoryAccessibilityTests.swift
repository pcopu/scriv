import UIKit
import XCTest
@testable import ScrivUIKit

@MainActor
final class HistoryAccessibilityTests: XCTestCase {
    func testRepeatedHistoryPresentationBoundsAccessibilityAndRestoresPresenter() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--screenshots") else {
            throw XCTSkip("Requires isolated verification storage.")
        }
        let store = WorkspaceStore()
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let previous = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
        let window = (previous?.windowScene ?? scenes.first).map(UIWindow.init(windowScene:))
            ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 1200, height: 1000))
        let host = UIViewController()
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        let hostAttached = await settled { host.viewIfLoaded?.window != nil }
        XCTAssertTrue(hostAttached)
        for wasHidden in [false, true] {
            host.view.accessibilityElementsHidden = wasHidden
            let history = HistoryController(store: store)
            history.modalPresentationStyle = .formSheet
            host.present(history, animated: false)
            let presented = await settled {
                host.presentedViewController === history && history.viewIfLoaded?.window != nil && !history.isBeingPresented
            }
            XCTAssertTrue(presented)
            XCTAssertTrue(history.view.accessibilityViewIsModal, "History must expose its own modal accessibility boundary.")
            XCTAssertFalse(history.view.accessibilityElementsHidden, "History's own controls must remain accessible.")
            XCTAssertTrue(host.view.accessibilityElementsHidden, "Responder discovery must not traverse the obscured script behind History.")
            host.dismiss(animated: false)
            let dismissed = await settled { host.presentedViewController == nil && history.viewIfLoaded?.window == nil }
            XCTAssertTrue(dismissed)
            XCTAssertEqual(host.view.accessibilityElementsHidden, wasHidden, "Closing History must restore the presenter's prior accessibility state.")
        }
    }

    private func settled(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }
}
