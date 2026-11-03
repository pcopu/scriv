import UIKit
import XCTest
@testable import ScrivUIKit

@MainActor
final class SettingsPanelTests: XCTestCase {
    func testSettingsCommandOpensOneWindowAndPreservesPaneState() async throws {
        let app = UIApplication.shared
        let workspaceWindow = try XCTUnwrap(app.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.rootViewController is ScrivWorkspaceController })
        let workspace = try XCTUnwrap(workspaceWindow.rootViewController as? ScrivWorkspaceController)
        let action = NSSelectorFromString("showSettings:")
        let command = UIKeyCommand(title: "Settings…", action: action, input: ",", modifierFlags: .command)
        XCTAssertTrue(app.sendAction(action, to: nil, from: command, for: nil))
        let appeared = await settled { self.settingsScenes.count == 1 }
        XCTAssertTrue(appeared, "Connected scenes: \(app.connectedScenes.map { "\($0.session.configuration.name ?? "nil") / \(String(describing: $0.delegate))" })")
        let scene = try XCTUnwrap(settingsScenes.first)
        defer { for scene in self.settingsScenes { app.requestSceneSessionDestruction(scene.session, options: nil, errorHandler: nil) } }
        let window = try XCTUnwrap(scene.windows.first)
        let panel = try XCTUnwrap(window.rootViewController as? ScrivSettingsPanelController)
        let visible = await settled { panel.viewIfLoaded?.window != nil }
        XCTAssertTrue(visible)
        XCTAssertFalse(window === workspaceWindow)
        XCTAssertTrue(panel.store === workspace.store)
        XCTAssertNil(workspace.presentedViewController)
        let detail = try XCTUnwrap(panel.viewController(for: .secondary) as? UINavigationController)
        panel.selectPane(.account)
        let account = try XCTUnwrap(detail.topViewController)
        account.loadViewIfNeeded()
        let expand = try XCTUnwrap(descendants(account.view).compactMap { $0 as? UIButton }.first { $0.accessibilityLabel == "Server settings" })
        expand.sendActions(for: .primaryActionTriggered)
        let server = try XCTUnwrap(descendants(account.view).compactMap { $0 as? UITextField }.first)
        let savedAddress = workspace.store.cloudBaseURL
        server.text = "https://unsaved-settings.example"; server.sendActions(for: .editingChanged)
        panel.selectPane(.general); panel.selectPane(.account)
        XCTAssertTrue(detail.topViewController === account)
        XCTAssertEqual(server.text, "https://unsaved-settings.example")
        XCTAssertEqual(workspace.store.cloudBaseURL, savedAddress)
        XCTAssertTrue(app.sendAction(action, to: nil, from: command, for: nil))
        let refocused = await settled { window.isKeyWindow && scene.activationState == .foregroundActive }
        XCTAssertTrue(refocused)
        XCTAssertEqual(settingsScenes.count, 1)
        XCTAssertEqual(panel.selectedPane, .account)

        for style in [UIUserInterfaceStyle.light, .dark] {
            window.overrideUserInterfaceStyle = style
            for pane in ScrivSettingsPane.allCases {
                panel.selectPane(pane)
                panel.view.layoutIfNeeded()
                let image = UIGraphicsImageRenderer(bounds: panel.view.bounds).image { _ in panel.view.drawHierarchy(in: panel.view.bounds, afterScreenUpdates: true) }
                let attachment = XCTAttachment(image: image)
                attachment.name = "settings-\(pane.title.lowercased())-\(style == .dark ? "dark" : "light")"
                attachment.lifetime = .keepAlways; add(attachment)
                XCTAssertGreaterThan(detail.view.bounds.width, 400)
                let sidebar = try XCTUnwrap(panel.viewController(for: .primary))
                let scroll = try XCTUnwrap(detail.topViewController?.view.subviews.compactMap { $0 as? UIScrollView }.first)
                let sidebarFrame = sidebar.view.convert(sidebar.view.bounds, to: panel.view)
                let contentFrame = scroll.convert(scroll.bounds, to: panel.view)
                XCTAssertGreaterThanOrEqual(contentFrame.minX, sidebarFrame.maxX - 1, "Settings must not extend underneath the sidebar.")
            }
        }
        app.requestSceneSessionDestruction(scene.session, options: nil, errorHandler: nil)
        let closed = await settled { self.settingsScenes.isEmpty }
        XCTAssertTrue(closed)
        await activate(workspaceWindow)
        XCTAssertTrue(app.sendAction(action, to: nil, from: command, for: nil))
        let reopened = await settled { self.settingsScenes.count == 1 }
        XCTAssertTrue(reopened)
        let reopenedScene = try XCTUnwrap(settingsScenes.first)
        let reopenedPanel = try XCTUnwrap(reopenedScene.windows.first?.rootViewController as? ScrivSettingsPanelController)
        XCTAssertTrue(reopenedPanel.store === workspace.store)
        app.requestSceneSessionDestruction(reopenedScene.session, options: nil, errorHandler: nil)
        let reclosed = await settled { self.settingsScenes.isEmpty }
        XCTAssertTrue(reclosed)
        await activate(workspaceWindow)
    }

    private func activate(_ window: UIWindow) async {
        guard let scene = window.windowScene else { XCTFail("The workspace scene must still exist."); return }
        UIApplication.shared.requestSceneSessionActivation(scene.session, userActivity: nil, options: nil, errorHandler: nil)
        window.makeKeyAndVisible()
        let active = await settled { scene.activationState == .foregroundActive && window.isKeyWindow }
        XCTAssertTrue(active)
    }

    private var settingsScenes: [UIWindowScene] {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.filter { $0.delegate is ScrivSettingsSceneDelegate }
    }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap { descendants($0) } }
    private func settled(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }
}
