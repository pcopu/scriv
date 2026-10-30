import UIKit
import ScrivCore

final class ScrivUIKitAppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey:Any]? = nil) -> Bool {
        let router = ScrivUIKitRouter.shared
        ScrivUIKitFeatures.registerScriptAndProjects(in: router)
        ScrivUIKitFeatures.registerAudio(in: router)
        ScrivUIKitFeatures.registerCharactersAndTeams(in: router)
        ScrivUIKitFeatures.registerImages(in: router)
        ScrivUIKitFeatures.registerAccount(in: router)
        return true
    }
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Scriv workspace", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = ScrivUIKitSceneDelegate.self
        return configuration
    }
}

final class ScrivUIKitSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var store: WorkspaceStore?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let workspace = WorkspaceStore(); store = workspace
        let window = UIWindow(windowScene: scene)
        window.rootViewController = ScrivWorkspaceController(store: workspace)
        window.tintColor = ScrivUIKitTheme.accent
        self.window = window; window.makeKeyAndVisible()
        scene.sizeRestrictions?.minimumSize = CGSize(width: 1080, height: 720)
        for context in connectionOptions.urlContexts { workspace.handleOpenURL(context.url) }
    }
    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        for context in contexts { store?.handleOpenURL(context.url) }
    }
    func sceneDidEnterBackground(_ scene: UIScene) {
        // This is a best-effort flush only. Durable accepted mutations must be
        // journaled before publication; scene callbacks cannot defer termination.
        guard let store else { return }
        UIKitPresentation.finishEditing()
        Task { await store.flushPendingSaves() }
    }
}
