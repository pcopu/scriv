import UIKit
import Combine
import ScrivCore

/// Queue errors above the actual frontmost UIKit form, preserving its draft.
@MainActor
final class WorkspaceErrorPresenter {
    private struct Issue { let message: String; let onDismiss: () -> Void }
    private var pending: [Issue] = []
    private var active: Issue?
    private weak var activeAlert: UIAlertController?
    private var observers = Set<AnyCancellable>()
    init() {
        for name in [UIWindow.didBecomeKeyNotification, UIApplication.didBecomeActiveNotification] {
            NotificationCenter.default.publisher(for: name).receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    if name == UIWindow.didBecomeKeyNotification { StartupTrace.process.record(.windowBecameKey) }
                    self?.presentNext()
                }.store(in: &observers)
        }
    }
    func enqueue(_ message: String, onDismiss: @escaping () -> Void) {
        guard !message.isEmpty, active?.message != message, !pending.contains(where: { $0.message == message }) else { return }
        StartupTrace.process.record(.errorQueued)
        pending.append(Issue(message: message, onDismiss: onDismiss)); presentNext()
    }
    private func presentNext() {
        guard active == nil, !pending.isEmpty, let presenter = UIKitPresentation.presenter,
              !presenter.isBeingPresented, !presenter.isBeingDismissed else {
            if active == nil, !pending.isEmpty { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.presentNext() } }
            return
        }
        let issue = pending.removeFirst(); active = issue
        let alert = UIAlertController(title: "Scriv", message: issue.message, preferredStyle: .alert)
        activeAlert = alert
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self, weak alert] _ in
            if let alert { self?.acknowledge(alert) }
        })
        presenter.present(alert, animated: true) { StartupTrace.process.record(.errorPresented) }
    }

    private func acknowledge(_ alert: UIAlertController) {
        guard activeAlert === alert, let issue = active else { return }
        StartupTrace.process.record(.errorDismissed)
        activeAlert = nil; active = nil; issue.onDismiss()
        DispatchQueue.main.async { [weak self] in self?.presentNext() }
    }

#if SCRIV_CLI_AUTOMATION
    func acknowledgeCLIImportError(_ message: String, in workspace: ScrivWorkspaceController) -> Bool {
        guard active?.message == message, let alert = activeAlert,
              alert.presentingViewController === workspace, workspace.presentedViewController === alert,
              alert.viewIfLoaded?.window != nil, !alert.isBeingPresented, !alert.isBeingDismissed,
              alert.presentedViewController == nil, alert.message == message else { return false }
        // Catalyst does not expose this UIKit OK action as a tappable view.
        // Dismiss the real presentation and run the same acknowledgement as OK.
        alert.dismiss(animated: true) { [weak self] in self?.acknowledge(alert) }
        return true
    }
#endif
}
