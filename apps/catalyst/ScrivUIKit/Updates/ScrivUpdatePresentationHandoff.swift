import UIKit

/// The update sheet can sit above a Settings navigation sheet. Removing only
/// the top sheet leaves a modal that may veto Sparkle's normal Apple quit event.
/// Dismiss only the verified presentation chain containing our updater, not
/// arbitrary windows or a replacement presentation, and never force-quit.
@MainActor
enum ScrivUpdatePresentationHandoff {
    static func dismissModalChain(containing update: UIViewController) async throws -> UIViewController {
        func failure() -> NSError {
            NSError(domain: "app.scriv.updates", code: 2, userInfo: [NSLocalizedDescriptionKey: "Scriv could not close the update windows safely. Close other dialogs and check for updates again."])
        }
        // On Mac Catalyst a sheet lives in its own bridged window whose root is
        // the sheet itself, so find the chain's root through its presenters.
        guard update.viewIfLoaded?.window != nil else { throw failure() }
        var root = update
        while let presenter = root.presentingViewController { root = presenter }
        guard root !== update else { throw failure() }
        var top = root
        while let next = top.presentedViewController { top = next }
        guard top === update, !update.isBeingDismissed, !update.isBeingPresented else { throw failure() }
        let wasEnabled = root.view.isUserInteractionEnabled
        root.view.isUserInteractionEnabled = false
        defer { root.view.isUserInteractionEnabled = wasEnabled }
        root.view.endEditing(true)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            root.dismiss(animated: false) {
                guard root.presentedViewController == nil, update.presentingViewController == nil else {
                    continuation.resume(throwing: failure()); return
                }
                continuation.resume()
            }
        }
        return root
    }
}
