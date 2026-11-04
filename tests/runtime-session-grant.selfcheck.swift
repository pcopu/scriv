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
print("PASS: session lifetime/reset, persistent authority, conflict rejection, owner and capability validation")
