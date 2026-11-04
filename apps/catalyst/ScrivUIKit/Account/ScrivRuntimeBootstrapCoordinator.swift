import UIKit
import ScrivCore

/// Constructed only by the user's Connect action, which authorizes startup;
/// the signed helper returns its local connection without address entry.
@MainActor
final class ScrivRuntimeBootstrapCoordinator {
    private var adapter: ScrivRuntimeBootstrapAdapter?
    private var response: CheckedContinuation<Data, Error>?
    private var cancelled = false
    private let hasSavedGrant: () throws -> Bool
    private let makeAdapter: () throws -> ScrivRuntimeBootstrapAdapter
    private let savePairing: (Data) throws -> Void

    // Dependency injection is internal for synthetic tests, never a runtime flag
    // or saved preference. Production defaults always use the real trust path.
    init(hasSavedGrant: (() throws -> Bool)? = nil,
         makeAdapter: (() throws -> ScrivRuntimeBootstrapAdapter)? = nil,
         savePairing: ((Data) throws -> Void)? = nil) {
        self.hasSavedGrant = hasSavedGrant ?? { try MacRuntimeBridge.savedPairing() != nil }
        self.makeAdapter = makeAdapter ?? { try ScrivRuntimeBootstrapCoordinator.loadAdapter() }
        self.savePairing = savePairing ?? { try MacRuntimeBridge.importBootstrappedPairing($0) }
    }

    func prepare(userApproved: Bool) async throws {
        var succeeded = false
        defer { if !succeeded { cancel() } }
        try Task.checkCancellation()
        guard userApproved else { throw CancellationError() }
        // A damaged/inaccessible saved item is not treated as missing consent.
        _ = try hasSavedGrant()
        try await withTaskCancellationHandler {
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
    func cancel() {
        cancelled = true
        let pending = response; response = nil
        adapter?.disconnect(); adapter = nil
        pending?.resume(throwing: CancellationError())
    }
}
