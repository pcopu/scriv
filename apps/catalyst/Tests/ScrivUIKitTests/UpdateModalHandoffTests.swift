import UIKit
import XCTest
@testable import ScrivUIKit

@MainActor
final class UpdateModalHandoffTests: XCTestCase {
    func testHandoffDismissesSettingsAndUpdateBeforeReturning() async throws {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let previous = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
        let window = (previous?.windowScene ?? scenes.first).map(UIWindow.init(windowScene:))
            ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 1200, height: 900))
        let root = UIViewController()
        window.rootViewController = root; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        let attached = await settled { root.viewIfLoaded?.window != nil }
        XCTAssertTrue(attached)
        for initiallyEnabled in [true, false] {
            root.view.isUserInteractionEnabled = initiallyEnabled
            // The real route wraps Settings in a navigation sheet. A generic
            // settings body avoids constructing stores or touching user data.
            let settings = UINavigationController(rootViewController: UIViewController())
            settings.modalPresentationStyle = .formSheet
            root.present(settings, animated: false)
            let settingsVisible = await settled { settings.viewIfLoaded?.window != nil && !settings.isBeingPresented }
            XCTAssertTrue(settingsVisible)
            let update = ScrivUpdateController()
            settings.present(update, animated: false)
            let updateVisible = await settled { update.viewIfLoaded?.window != nil && !update.isBeingPresented }
            XCTAssertTrue(updateVisible)
            let unexpected = UIViewController()
            update.present(unexpected, animated: false)
            let unexpectedVisible = await settled { unexpected.viewIfLoaded?.window != nil && !unexpected.isBeingPresented }
            XCTAssertTrue(unexpectedVisible)
            do {
                _ = try await ScrivUpdatePresentationHandoff.dismissModalChain(containing: update)
                XCTFail("A replacement/descendant dialog must not be silently discarded.")
            } catch { }
            XCTAssertTrue(root.presentedViewController === settings)
            XCTAssertTrue(update.presentedViewController === unexpected)
            unexpected.dismiss(animated: false)
            let unexpectedDismissed = await settled { update.presentedViewController == nil }
            XCTAssertTrue(unexpectedDismissed)
            update.render(["phase": "saving"], reply: nil)
            let returnedRoot = try await ScrivUpdatePresentationHandoff.dismissModalChain(containing: update)
            XCTAssertTrue(returnedRoot === root)
            XCTAssertNil(root.presentedViewController, "No Settings modal may remain to veto the quit event.")
            XCTAssertNil(update.presentingViewController)
            XCTAssertNil(settings.presentingViewController)
            XCTAssertEqual(root.view.isUserInteractionEnabled, initiallyEnabled)
        }
    }

    func testDetachedPresentationFailsClosed() async {
        let detached = ScrivUpdateController()
        detached.loadViewIfNeeded()
        do {
            _ = try await ScrivUpdatePresentationHandoff.dismissModalChain(containing: detached)
            XCTFail("A detached controller is not evidence that the actual modal chain was removed.")
        } catch { }
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
