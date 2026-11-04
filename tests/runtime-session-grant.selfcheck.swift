// Standalone CLT check for hosts without XCTest. Link with the native ScrivCore library.
import Foundation
import ScrivCore

func rejected(_ body: () throws -> Void) {
    var failed = false
    do { try body() } catch { failed = true }
    precondition(failed, "An invalid or conflicting grant must be rejected")
}

let approved = RuntimeBridgePairing(ownerUID: 501, port: 4501, secret: Data(repeating: 1, count: 32))
let different = RuntimeBridgePairing(ownerUID: 501, port: 4501, secret: Data(repeating: 2, count: 32))
var session = RuntimeBridgeSessionGrant()
let empty = try session.resolve(persistent: nil, ownerUID: 501)
precondition(empty == nil)
try session.retain(approved, ownerUID: 501)
let retained = try session.resolve(persistent: nil, ownerUID: 501)
precondition(retained == approved)
let restarted = try RuntimeBridgeSessionGrant().resolve(persistent: nil, ownerUID: 501)
precondition(restarted == nil, "A session grant must not survive a new process")
rejected { try session.retain(different, ownerUID: 501) }
rejected { _ = try session.resolve(persistent: different, ownerUID: 501) }
rejected { _ = try session.resolve(persistent: nil, ownerUID: 502) }
let persistent = try session.resolve(persistent: approved, ownerUID: 501)
precondition(persistent == approved)
session.reset()
let reset = try session.resolve(persistent: nil, ownerUID: 501)
precondition(reset == nil)
let stillSaved = try session.resolve(persistent: approved, ownerUID: 501)
precondition(stillSaved == approved, "Reset must not remove a persistent grant")
rejected { try session.retain(RuntimeBridgePairing(ownerUID: 501, port: 4501, secret: Data()), ownerUID: 501) }

// The merged storage policy may retain a session grant only after both reads
// establish absence. A failed/raced read must never inherit that fallback.
var bootstrapped = RuntimeBridgeSessionGrant()
var reads = 0, writes = 0
try bootstrapped.importBootstrapped(approved, ownerUID: 501, readPersistent: {
    reads += 1; return nil
}, createPersistent: { value in
    precondition(value == approved); writes += 1; return .missingEntitlement
})
precondition(reads == 2 && writes == 1)
let bootstrappedGrant = try bootstrapped.resolve(persistent: nil, ownerUID: 501)
precondition(bootstrappedGrant == approved)
enum StorageFailure: Error { case locked }
for outcome in [RuntimeBridgeSessionGrant.CreateResult.duplicate, .missingEntitlement] {
    var denied = RuntimeBridgeSessionGrant()
    var deniedReads = 0
    rejected {
        try denied.importBootstrapped(approved, ownerUID: 501, readPersistent: {
            deniedReads += 1
            if deniedReads == 2 { throw StorageFailure.locked }
            return nil
        }, createPersistent: { _ in outcome })
    }
    let deniedGrant = try denied.resolve(persistent: nil, ownerUID: 501)
    precondition(deniedReads == 2 && deniedGrant == nil)
    var raced = RuntimeBridgeSessionGrant()
    var raceReads = 0
    rejected {
        try raced.importBootstrapped(approved, ownerUID: 501, readPersistent: {
            raceReads += 1; return raceReads == 1 ? nil : different
        }, createPersistent: { _ in outcome })
    }
    let racedGrant = try raced.resolve(persistent: nil, ownerUID: 501)
    precondition(raceReads == 2 && racedGrant == nil)
}
print("PASS: session lifetime/reset, persistent authority, owner/capability checks, verified absence and failed/raced storage")
