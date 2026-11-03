import UIKit

@MainActor
final class ScrivSettingsWindowCoordinator {
    static let shared = ScrivSettingsWindowCoordinator()
    static let configurationName = "Scriv Settings"
    static let activityType = "app.scriv.settings"
    private var pendingStore: WorkspaceStore?
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

    func show(store: WorkspaceStore? = nil) {
        guard pendingStore == nil else { return }
        let session = settingsSession
        let source = store ?? activeStore
        guard session != nil || source != nil else { return }
        if session == nil { pendingStore = source }
        UIApplication.shared.requestSceneSessionActivation(session, userActivity: NSUserActivity(activityType: Self.activityType), options: nil) { [weak self] error in
            self?.pendingStore = nil
            source?.errorMessage = "Settings could not open: \(error.localizedDescription)"
        }
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
        window.rootViewController = ScrivSettingsPanelController(store: store)
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
    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) { window?.makeKeyAndVisible() }
    func sceneDidEnterBackground(_ scene: UIScene) {
        window?.endEditing(true)
        guard let store else { return }
        Task { await store.flushPendingSaves() }
    }
}
