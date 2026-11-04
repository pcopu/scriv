// Standalone Catalyst lifecycle check; injected adapters never access accounts or Keychain.
import Foundation
import ScrivCore

@MainActor
private final class ProbeAdapter: NSObject, ScrivRuntimeBootstrapAdapter {
    var calls = 0
    var reply: ((Data?, Error?) -> Void)?
    var immediate: Data?
    func connectAfterUserConsent(_ approved: Bool, completion: @escaping (Data?, Error?) -> Void) {
        precondition(approved); calls += 1; reply = completion
        if let immediate { completion(immediate, nil) }
    }
    func disconnect() {}
}

@main @MainActor
struct BootstrapCheck {
    static func main() async throws {
        var loads = 0, saves = 0
        let denied = ScrivRuntimeBootstrapCoordinator(hasSavedGrant: { false }, makeAdapter: { loads += 1; return ProbeAdapter() }, savePairing: { _ in saves += 1 })
        do { try await denied.prepare(userApproved: false); preconditionFailure("No user action") }
        catch { precondition(error is CancellationError) }
        precondition(loads == 0 && saves == 0)
        let ready = ProbeAdapter(); ready.immediate = Data([1, 2, 3])
        let firstUse = ScrivRuntimeBootstrapCoordinator(hasSavedGrant: { false }, makeAdapter: { ready }, savePairing: { bytes in precondition(bytes == Data([1, 2, 3])); saves += 1 })
        try await firstUse.prepare(userApproved: true)
        precondition(ready.calls == 1 && saves == 1, "One Connect action must prepare the first connection")
        firstUse.cancel()
        enum Locked: Error { case keychain }
        let locked = ScrivRuntimeBootstrapCoordinator(hasSavedGrant: { throw Locked.keychain }, makeAdapter: { loads += 1; return ProbeAdapter() }, savePairing: { _ in preconditionFailure("Locked grant") })
        do { try await locked.prepare(userApproved: true); preconditionFailure("Locked grant must fail") }
        catch { precondition(error is Locked) }
        precondition(loads == 0)
        let late = ProbeAdapter()
        let cancelled = ScrivRuntimeBootstrapCoordinator(hasSavedGrant: { false }, makeAdapter: { late }, savePairing: { _ in preconditionFailure("Cancelled grant") })
        let task = Task { try await cancelled.prepare(userApproved: true) }
        for _ in 0..<1_000 { if late.reply != nil { break }; await Task.yield() }
        precondition(late.reply != nil)
        cancelled.cancel(); late.reply?(Data([7]), nil)
        do { try await task.value; preconditionFailure("Cancelled request must fail") }
        catch { precondition(error is CancellationError) }
        print("PASS: single-action first use, rejected approval, locked Keychain and cancellation/late reply")
    }
}
