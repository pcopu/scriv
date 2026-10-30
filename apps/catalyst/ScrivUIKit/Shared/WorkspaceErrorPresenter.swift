import UIKit
import Combine

/// Queue errors above the actual frontmost UIKit form, preserving its draft.
@MainActor
final class WorkspaceErrorPresenter {
    private struct Issue { let message: String; let onDismiss: () -> Void }
    private var pending: [Issue] = []
    private var active: Issue?
    private var observers = Set<AnyCancellable>()
    init() {
        for name in [UIWindow.didBecomeKeyNotification, UIApplication.didBecomeActiveNotification] {
            NotificationCenter.default.publisher(for: name).receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.presentNext() }.store(in: &observers)
        }
    }
    func enqueue(_ message: String, onDismiss: @escaping () -> Void) {
        guard !message.isEmpty, active?.message != message, !pending.contains(where: { $0.message == message }) else { return }
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
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.active = nil; issue.onDismiss()
            DispatchQueue.main.async { [weak self] in self?.presentNext() }
        })
        presenter.present(alert, animated: true)
    }
}
