import UIKit
import ScrivCore

/// The sole first-use consent boundary. Constructed only by Check & connect;
/// the signed helper returns its local connection without address entry.
@MainActor
final class ScrivRuntimeBootstrapCoordinator {
    private var adapter: ScrivRuntimeBootstrapAdapter?
    private var alert: UIAlertController?
    private var consent: CheckedContinuation<Bool, Never>?
    private var response: CheckedContinuation<Data, Error>?
    private var cancelled = false
    private let hasSavedGrant: () throws -> Bool
    private let makeAdapter: () throws -> ScrivRuntimeBootstrapAdapter
    private let savePairing: (Data) throws -> Void
    private let consentOverride: ((UIViewController) async -> Bool)?

    // Dependency injection is internal for synthetic tests, never a runtime flag
    // or saved preference. Production defaults always use the real trust path.
    init(hasSavedGrant: (() throws -> Bool)? = nil,
         makeAdapter: (() throws -> ScrivRuntimeBootstrapAdapter)? = nil,
         savePairing: ((Data) throws -> Void)? = nil,
         confirm: ((UIViewController) async -> Bool)? = nil) {
        self.hasSavedGrant = hasSavedGrant ?? { try MacRuntimeBridge.savedPairing() != nil }
        self.makeAdapter = makeAdapter ?? { try ScrivRuntimeBootstrapCoordinator.loadAdapter() }
        self.savePairing = savePairing ?? { try MacRuntimeBridge.importBootstrappedPairing($0) }
        self.consentOverride = confirm
    }

    func prepare(from presenter: UIViewController) async throws {
        var succeeded = false
        defer { if !succeeded { cancel() } }
        try Task.checkCancellation()
        // A damaged/inaccessible saved item is not treated as missing consent.
        let hasGrant = try hasSavedGrant()
        try await withTaskCancellationHandler {
            if !hasGrant {
                let allowed: Bool
                if let consentOverride { allowed = await consentOverride(presenter) }
                else { allowed = await confirm(from: presenter) }
                guard allowed else { throw CancellationError() }
            }
            try Task.checkCancellation()
            guard !cancelled else { throw CancellationError() }
            let native = try makeAdapter(); adapter = native
            let bytes: Data = try await withCheckedThrowingContinuation { continuation in
                response = continuation
                native.connectAfterUserConsent(true) { [weak self] data, error in
                    Task { @MainActor in
                        guard let self, let response = self.response else { return }
                        self.response = nil
                        if self.cancelled { response.resume(throwing: CancellationError()) }
                        else if let error { response.resume(throwing: error) }
                        else if let data { response.resume(returning: data) }
                        else { response.resume(throwing: ScrivError.invalid("The signed local helper returned no connection.")) }
                    }
                }
            }
            try Task.checkCancellation()
            guard !cancelled else { throw CancellationError() }
            // Main-actor synchronous import leaves no cancellation suspension
            // between checking the active request and the create-only write.
            try savePairing(bytes)
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
        succeeded = true
    }
    private static func loadAdapter() throws -> ScrivRuntimeBootstrapAdapter {
        guard let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent("ScrivUpdatePlugin.bundle"),
              let bundle = Bundle(url: url), bundle.load(),
              let type = NSClassFromString("ScrivRuntimeBootstrapAdapterImpl") as? ScrivRuntimeBootstrapAdapter.Type else {
            throw ScrivError.unavailable("This build is missing its native Codex connection component. Install a complete signed Scriv release.")
        }
        return type.init()
    }
    private func confirm(from presenter: UIViewController) async -> Bool {
        guard !cancelled, presenter.viewIfLoaded?.window != nil, presenter.presentedViewController == nil else { return false }
        return await withCheckedContinuation { continuation in
            consent = continuation
            let sheet = UIAlertController(title: "Connect Codex on this Mac?", message: "Scriv will use your existing local Codex account and its bundled helper to start a separate local runtime when you request it. The helper can access Codex and generation files as your Mac account. Your login stays on this Mac.\n\nNothing starts until you allow this connection.", preferredStyle: .alert)
            sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.finishConsent(false) })
            sheet.addAction(UIAlertAction(title: "Allow connection", style: .default) { [weak self] _ in self?.finishConsent(true) })
            sheet.preferredAction = sheet.actions.last
            sheet.view.accessibilityIdentifier = "codex.bootstrap.consent"
            alert = sheet; presenter.present(sheet, animated: true)
        }
    }
    private func finishConsent(_ approved: Bool) {
        let pending = consent; consent = nil; alert = nil
        pending?.resume(returning: approved && !cancelled)
    }
    func cancel() {
        cancelled = true
        alert?.dismiss(animated: false); alert = nil
        finishConsent(false)
        let pending = response; response = nil
        adapter?.disconnect(); adapter = nil
        pending?.resume(throwing: CancellationError())
    }
}
