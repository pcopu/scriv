import UIKit
import XCTest
@testable import ScrivUIKit

/// Repeated popup/Settings navigation and interrupted preparation, using isolated
/// verification stores and synthetic preparation only.
@MainActor
final class CodexNativeModalParityTests: XCTestCase {
    func testActualCodexRouteIsOneAnchoredPopoverWithoutConnecting() async throws {
        let store = WorkspaceStore(), router = ScrivUIKitRouter()
        ScrivUIKitFeatures.registerAccount(in: router)
        let previous = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)
        let scene = try XCTUnwrap(previous?.windowScene)
        let window = UIWindow(windowScene: scene), host = CodexPopupTestHostController()
        let anchor = UIButton(type: .system); anchor.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        host.loadViewIfNeeded(); host.view.addSubview(anchor); anchor.frame = CGRect(x: 40, y: 40, width: 32, height: 32)
        let appeared = expectation(description: "Popup fixture host appeared")
        host.didAppear = { appeared.fulfill() }; window.rootViewController = host; window.makeKeyAndVisible()
        defer { host.dismiss(animated: false); window.isHidden = true; previous?.makeKey() }
        await fulfillment(of: [appeared], timeout: 5)
        for _ in 0..<2 {
            router.present(.codex, from: host, store: store, sourceView: anchor)
            let attached = await settled { host.presentedViewController?.viewIfLoaded?.window != nil && host.presentedViewController?.isBeingPresented == false }
            XCTAssertTrue(attached)
            let popup = try XCTUnwrap(host.presentedViewController as? UINavigationController)
            XCTAssertEqual(popup.modalPresentationStyle, .popover)
            XCTAssertTrue(popup.popoverPresentationController?.sourceView === anchor)
            XCTAssertEqual(popup.popoverPresentationController?.sourceRect, anchor.bounds)
            XCTAssertTrue(popup.isNavigationBarHidden)
            XCTAssertEqual(popup.preferredContentSize, ScrivCodexSetupView.preferredPopupSize)
            let controller = try XCTUnwrap(popup.topViewController as? ScrivCodexController)
            let setup = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? ScrivCodexSetupView }.first)
            XCTAssertEqual(setup.surface, .popup)
            router.present(.codex, from: host, store: store, sourceView: anchor)
            XCTAssertTrue(host.presentedViewController === popup)
            XCTAssertNil(popup.presentedViewController)
            XCTAssertEqual(store.codex.connectionCheck.phase, .idle)
            XCTAssertFalse(store.codex.isConnecting); XCTAssertFalse(store.codex.isConnected)
            XCTAssertFalse(store.codex.bridgePaired); XCTAssertFalse(store.codex.accountChecked)
            XCTAssertNil(store.codex.pendingLoginID)
            try button("done", in: setup).sendActions(for: .primaryActionTriggered)
            // Reopening during dismissal must not stack or resurrect the popup.
            router.present(.codex, from: host, store: store, sourceView: anchor)
            let dismissed = await settled { host.presentedViewController == nil }
            XCTAssertTrue(dismissed)
        }
    }

    func testClosingSettingsCancelsPendingPreparationAndCanRetry() async throws {
        let store = WorkspaceStore(), first = expectation(description: "First preparation"), second = expectation(description: "Retry preparation")
        var attempts = 0
        var release: CheckedContinuation<Void, Error>?
        let panel = ScrivSettingsPanelController(store: store) { store, pane in
            ScrivSettingsController(store: store, pane: pane, prepareLocalRuntime: { _ in
                attempts += 1
                try await withCheckedThrowingContinuation { continuation in
                    release = continuation
                    if attempts == 1 { first.fulfill() } else { second.fulfill() }
                }
                try Task.checkCancellation()
                XCTFail("A cancelled preparation must not proceed toward a runtime")
            })
        }
        panel.selectPane(.codex); panel.loadViewIfNeeded()
        let detail = try XCTUnwrap(panel.viewController(for: .secondary) as? UINavigationController)
        let controller = try XCTUnwrap(detail.topViewController as? ScrivSettingsController)
        controller.loadViewIfNeeded()
        defer { controller.cancelPendingConnectionCheck(); release?.resume(throwing: CancellationError()); release = nil }
        try button("check", in: controller.view).sendActions(for: .primaryActionTriggered)
        await fulfillment(of: [first], timeout: 2)
        XCTAssertEqual(store.codex.connectionCheck.phase, .checking)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 880, height: 660)); window.rootViewController = panel
        let delegate = ScrivSettingsSceneDelegate(); delegate.window = window
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first)
        delegate.sceneDidDisconnect(scene)
        release?.resume(); release = nil
        let cancelled = await settled { store.codex.connectionCheck.phase == .cancelled && (try? self.button("check", in: controller.view).isEnabled) == true }
        XCTAssertTrue(cancelled)
        XCTAssertFalse(store.codex.isConnected); XCTAssertFalse(store.codex.bridgePaired)
        try button("check", in: controller.view).sendActions(for: .primaryActionTriggered)
        await fulfillment(of: [second], timeout: 2)
        XCTAssertEqual(attempts, 2)
        panel.selectPane(.general)
        release?.resume(); release = nil
        let recancelled = await settled { store.codex.connectionCheck.phase == .cancelled && !store.codex.isConnecting }
        XCTAssertTrue(recancelled)
        panel.selectPane(.codex)
        XCTAssertTrue(detail.topViewController === controller)
        XCTAssertFalse(store.codex.isConnected)
        XCTAssertNil(store.codex.pendingLoginID)
    }

    func testSwitchingPanesCancelsOnlyItsOwnCheck() async throws {
        let store = WorkspaceStore(), started = expectation(description: "Another surface started preparation")
        var release: CheckedContinuation<Void, Never>?
        let attempt = Task {
            await store.codex.checkAndConnect(prepareLocalRuntime: {
                await withCheckedContinuation { continuation in release = continuation; started.fulfill() }
            })
        }
        await fulfillment(of: [started], timeout: 2)
        defer { store.codex.cancelConnectionCheck(); release?.resume(); release = nil; attempt.cancel() }
        let panel = ScrivSettingsPanelController(store: store)
        panel.selectPane(.codex); panel.loadViewIfNeeded(); panel.selectPane(.general)
        panel.cancelPendingConnectionCheck()
        XCTAssertEqual(store.codex.connectionCheck.phase, .checking, "Read-only navigation must not cancel a different surface's request")
        store.codex.cancelConnectionCheck(); release?.resume(); release = nil
        await attempt.value
        XCTAssertFalse(store.codex.isConnected); XCTAssertFalse(store.codex.bridgePaired)
    }

    func testStalePopupDismissalCannotCancelNewSettingsAttempt() async throws {
        let store = WorkspaceStore()
        let firstStarted = expectation(description: "Popup preparation started")
        let nextStarted = expectation(description: "Settings preparation started")
        let firstUnwound = expectation(description: "Old preparation unwound")
        var firstRelease: CheckedContinuation<Void, Never>?
        var nextRelease: CheckedContinuation<Void, Never>?
        let popup = ScrivSettingsController(store: store, runtimeOnly: true, prepareLocalRuntime: { _ in
            await withCheckedContinuation { continuation in firstRelease = continuation; firstStarted.fulfill() }
            firstUnwound.fulfill()
            try Task.checkCancellation()
        })
        popup.loadViewIfNeeded()
        defer {
            popup.cancelPendingConnectionCheck(); store.codex.cancelConnectionCheck()
            firstRelease?.resume(); nextRelease?.resume()
        }
        try button("check", in: popup.view).sendActions(for: .primaryActionTriggered)
        await fulfillment(of: [firstStarted], timeout: 2)
        let firstAttempt = try XCTUnwrap(store.codex.connectionCheck.attempt)
        popup.cancelPendingConnectionCheck()
        XCTAssertEqual(store.codex.connectionCheck.phase, .cancelled)
        // Keep the cancelled popup preparation suspended while Settings starts.
        let settings = ScrivSettingsController(store: store, pane: .codex, prepareLocalRuntime: { _ in
            await withCheckedContinuation { continuation in nextRelease = continuation; nextStarted.fulfill() }
            try Task.checkCancellation()
        })
        settings.loadViewIfNeeded()
        defer { settings.cancelPendingConnectionCheck() }
        try button("check", in: settings.view).sendActions(for: .primaryActionTriggered)
        await fulfillment(of: [nextStarted], timeout: 2)
        let nextAttempt = try XCTUnwrap(store.codex.connectionCheck.attempt)
        XCTAssertNotEqual(firstAttempt, nextAttempt)
        popup.presentationControllerDidDismiss(UIPresentationController(presentedViewController: popup, presenting: nil))
        XCTAssertEqual(store.codex.connectionCheck.attempt, nextAttempt, "A stale dismissal must not cancel the new connection")
        firstRelease?.resume(); firstRelease = nil
        await fulfillment(of: [firstUnwound], timeout: 2)
        XCTAssertEqual(store.codex.connectionCheck.attempt, nextAttempt)
        XCTAssertEqual(store.codex.connectionCheck.phase, .checking)
        settings.cancelPendingConnectionCheck(); nextRelease?.resume(); nextRelease = nil
        let cancelled = await settled { store.codex.connectionCheck.phase == .cancelled && !store.codex.isConnecting }
        XCTAssertTrue(cancelled)
        XCTAssertFalse(store.codex.isConnected); XCTAssertFalse(store.codex.bridgePaired)
    }

    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    private func button(_ id: String, in view: UIView) throws -> UIButton {
        try XCTUnwrap(descendants(view).first { $0.accessibilityIdentifier == "codex-" + id } as? UIButton)
    }
    private func settled(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }
}

@MainActor
private final class CodexPopupTestHostController: UIViewController {
    var didAppear: (() -> Void)?
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let callback = didAppear; didAppear = nil; callback?()
    }
}
