import AppKit
import Combine

/// Present errors above the active document sheet without dismissing that
/// sheet (or losing its draft). A SwiftUI alert on the workspace is behind
/// child sheets on macOS, so it cannot reliably report their failed actions.
@MainActor
final class WorkspaceErrorPresenter {
    private struct Issue {
        let message: String
        let onDismiss: () -> Void
    }
    private var pending: [Issue] = []
    private var active: Issue?
    private var activeAlert: NSAlert?
    private var windowObserver: AnyCancellable?

    init() {
        // Startup failures may arrive before the first document window exists.
        windowObserver = NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.presentNext() }
    }

    func enqueue(_ message: String, onDismiss: @escaping () -> Void) {
        guard !message.isEmpty, active?.message != message,
              !pending.contains(where: { $0.message == message }) else { return }
        pending.append(Issue(message: message, onDismiss: onDismiss))
        presentNext()
    }

    private func presentNext() {
        guard active == nil, !pending.isEmpty,
              var window = NSApp.modalWindow ?? NSApp.mainWindow ?? NSApp.keyWindow else { return }
        while let parent = window.sheetParent { window = parent }
        let issue = pending.removeFirst()
        active = issue
        let alert = NSAlert()
        alert.messageText = "Scriv"
        alert.informativeText = issue.message
        alert.addButton(withTitle: "OK")
        // AppKit's critical-sheet path temporarily disables an existing sheet,
        // then resumes it unchanged when the error is acknowledged. A normal
        // alert would be queued until the editor is closed, hiding the error.
        alert.alertStyle = window.attachedSheet == nil ? .warning : .critical
        activeAlert = alert
        alert.beginSheetModal(for: window) { [weak self] _ in
            guard let self else { return }
            self.active = nil
            self.activeAlert = nil
            issue.onDismiss()
            // Let AppKit finish removing this sheet before showing another.
            DispatchQueue.main.async { [weak self] in self?.presentNext() }
        }
    }
}
