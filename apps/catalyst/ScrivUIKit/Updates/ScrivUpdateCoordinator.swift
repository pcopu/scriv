import UIKit
import ScrivCore

/// One session, one explicit choice at a time. The native plug-in owns Sparkle;
/// this coordinator owns only presentation and the application's save fence.
@MainActor
final class ScrivUpdateCoordinator {
    static let shared = ScrivUpdateCoordinator()
    private let stores = NSHashTable<WorkspaceStore>.weakObjects()
    private var plugin: ScrivUpdatePlugin?
    private var sheet: ScrivUpdateController?
    private weak var presenter: UIViewController?
    private var preparing = false

    func register(_ store: WorkspaceStore) { stores.add(store) }

    func show(from presenter: UIViewController) {
        if let sheet { sheet.view.window?.makeKey(); return }
        self.presenter = presenter
        let controller = ScrivUpdateController()
        sheet = controller
        controller.onClose = { [weak self] in self?.sheet = nil }
        presenter.present(controller, animated: true)
        // Catalyst can defer a native sheet's presentation completion. The
        // explicit check must start while the sheet is open, not on dismissal.
        check()
    }
    private func check() {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else {
            sheet?.render(["phase": "blocked", "message": "In-app updates are built in, but release signing is not configured yet. You can keep using Scriv. Nothing will be downloaded or installed."], reply: nil)
            return
        }
        if plugin == nil {
            guard let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent("ScrivUpdatePlugin.bundle"),
                  let bundle = Bundle(url: url), bundle.load(),
                  let type = bundle.principalClass as? ScrivUpdatePlugin.Type else {
                sheet?.render(["phase": "blocked", "message": "This build does not include the signed Scriv update component. Install a complete signed release to enable updates."], reply: nil)
                return
            }
            let plugin = type.init()
            plugin.configure(events: { [weak self] event, reply in
                // Sparkle guarantees main-thread user-driver callbacks.
                MainActor.assumeIsolated { self?.receive(event, reply: reply) }
            }, prepare: { [weak self] willRelaunch, completion in
                Task { @MainActor in
                    guard let self, !self.preparing else {
                        completion(NSError(domain: "app.scriv.updates", code: 1, userInfo: [NSLocalizedDescriptionKey: "Scriv is already preparing an update."]))
                        return
                    }
                    self.preparing = true
                    defer { self.preparing = false }
                    do {
                        guard !self.stores.allObjects.isEmpty else { throw ScrivError.unavailable("Open a workspace before updating Scriv.") }
                        for store in self.stores.allObjects { try await store.prepareForApplicationUpdate() }
                        if willRelaunch {
                            guard let sheet = self.sheet else { throw ScrivError.unavailable("The update window is no longer available. Check for updates again.") }
                            let root = try await ScrivUpdatePresentationHandoff.dismissModalChain(containing: sheet)
                            self.sheet = nil; self.presenter = root
                            // Dismissal callbacks can finish editing. Verify the
                            // final on-disk snapshot again before Sparkle quits.
                            for store in self.stores.allObjects { try await store.prepareForApplicationUpdate() }
                        }
                        completion(nil)
                    } catch { completion(error as NSError) }
                }
            })
            self.plugin = plugin
        }
        plugin?.checkForUpdates()
    }
    private func receive(_ event: [String: Any], reply: ((String) -> Void)?) {
        if event["phase"] as? String == "dismiss" {
            sheet?.dismiss(animated: true); sheet = nil; return
        }
        if event["phase"] as? String == "focus" { sheet?.view.window?.makeKey(); return }
        // A normal quit may be delayed/canceled. Do not immediately create
        // another modal, which would itself block it. The next explicit Check
        // shows Sparkle's retained retry action instead.
        if event["phase"] as? String == "waitingToQuit" { return }
        if sheet == nil, ["error", "retryBlocked"].contains(event["phase"] as? String ?? ""),
           let presenter, presenter.viewIfLoaded?.window != nil {
            let controller = ScrivUpdateController()
            sheet = controller
            controller.onClose = { [weak self] in self?.sheet = nil }
            controller.render(event, reply: reply)
            presenter.present(controller, animated: true)
            return
        }
        sheet?.render(event, reply: reply)
    }
}
