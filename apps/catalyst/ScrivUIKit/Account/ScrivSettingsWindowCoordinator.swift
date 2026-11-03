import UIKit

@MainActor
final class ScrivSettingsWindowCoordinator {
    static let shared = ScrivSettingsWindowCoordinator()
    static let configurationName = "Scriv Settings"
    static let activityType = "app.scriv.settings"
    private var pendingStore: WorkspaceStore?
    private var pendingPane: ScrivSettingsPane?
    private var settingsSession: UISceneSession? {
        UIApplication.shared.openSessions.first { $0.configuration.name == Self.configurationName }
    }
    private var activeStore: WorkspaceStore? {
        let windows = [UIKitPresentation.window].compactMap { $0 } + UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        for window in windows {
            if let workspace = window.rootViewController as? ScrivWorkspaceController { return workspace.store }
            if let settings = window.rootViewController as? ScrivSettingsPanelController { return settings.store }
        }
        return nil
    }
    var canShow: Bool { settingsSession != nil || pendingStore != nil || activeStore != nil }

    func show(store: WorkspaceStore? = nil, pane: ScrivSettingsPane? = nil) {
        // A second Advanced request during scene creation changes the pending
        // selection instead of creating another Settings window.
        if let pane { pendingPane = pane }
        guard pendingStore == nil else { return }
        let session = settingsSession
        let source = store ?? activeStore
        guard session != nil || source != nil else { pendingPane = nil; return }
        let activity = NSUserActivity(activityType: Self.activityType)
        if let pane { activity.userInfo = ["pane": pane.rawValue] }
        if session == nil { pendingStore = source }
        else {
            if let pane, let scene = session?.scene as? UIWindowScene,
               let panel = scene.windows.compactMap({ $0.rootViewController as? ScrivSettingsPanelController }).first {
                panel.selectPane(pane)
            }
            pendingPane = nil
        }
        UIApplication.shared.requestSceneSessionActivation(session, userActivity: activity, options: nil) { [weak self] error in
            self?.pendingStore = nil; self?.pendingPane = nil
            source?.errorMessage = "Settings could not open: \(error.localizedDescription)"
        }
    }

    func paneForConnection() -> ScrivSettingsPane? {
        defer { pendingPane = nil }
        return pendingPane
    }
    static func pane(in activity: NSUserActivity) -> ScrivSettingsPane? {
        guard activity.activityType == activityType, let raw = activity.userInfo?["pane"] as? Int else { return nil }
        return ScrivSettingsPane(rawValue: raw)
    }

    func storeForConnection() -> WorkspaceStore {
        defer { pendingStore = nil }
        // A restored Settings window can connect before a workspace does.
        return pendingStore ?? activeStore ?? WorkspaceStore()
    }
}

@MainActor
final class ScrivSettingsSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var store: WorkspaceStore?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let store = ScrivSettingsWindowCoordinator.shared.storeForConnection()
        self.store = store
        ScrivUpdateCoordinator.shared.register(store)
        let window = UIWindow(windowScene: scene)
        let panel = ScrivSettingsPanelController(store: store)
        let pendingPane = ScrivSettingsWindowCoordinator.shared.paneForConnection()
        let activityPane = connectionOptions.userActivities.compactMap { ScrivSettingsWindowCoordinator.pane(in: $0) }.first
        if let pane = pendingPane ?? activityPane { panel.selectPane(pane) }
        window.rootViewController = panel
        window.tintColor = .systemBlue
        self.window = window
        scene.title = "Settings"
        scene.sizeRestrictions?.minimumSize = CGSize(width: 760, height: 500)
        scene.sizeRestrictions?.maximumSize = CGSize(width: 1200, height: 1000)
        window.makeKeyAndVisible()
        #if targetEnvironment(macCatalyst)
        scene.titlebar?.titleVisibility = .visible
        let bounds = scene.screen.bounds
        scene.requestGeometryUpdate(.Mac(systemFrame: CGRect(x: max(0, bounds.midX - 440), y: max(0, bounds.midY - 330), width: 880, height: 660)))
        #endif
    }
    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        if let pane = ScrivSettingsWindowCoordinator.pane(in: userActivity) {
            (window?.rootViewController as? ScrivSettingsPanelController)?.selectPane(pane)
        }
        window?.makeKeyAndVisible()
    }
    func sceneDidDisconnect(_ scene: UIScene) {
        (window?.rootViewController as? ScrivSettingsPanelController)?.cancelPendingConnectionCheck()
    }
    func sceneDidEnterBackground(_ scene: UIScene) {
        window?.endEditing(true)
        guard let store else { return }
        Task { await store.flushPendingSaves() }
    }
}
