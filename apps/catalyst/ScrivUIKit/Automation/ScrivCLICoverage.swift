#if SCRIV_CLI_AUTOMATION && SCRIV_CLI_COVERAGE
import Foundation
import CoreFoundation
import Darwin
import ScrivCore

/// Optional instrumentation-only transport. Snapshots are cumulative; nothing
/// resets counters or attributes coverage to a command. No file or URL API.
/// The transport's runID identifies one process interval, not its retained
/// workspace. A cold relaunch gets independent counters, tokens and sessionID.
@MainActor
enum ScrivCLICoverage {
    private static let maximumBytes = 16 * 1024 * 1024
    private static let maximumChunkBytes = 128 * 1024
    private static let maximumSnapshots = 2
    private static var snapshots: [String: Snapshot] = [:]

    private struct Failure: LocalizedError {
        var errorDescription: String? { "Isolated coverage observation is unavailable or invalid." }
    }

    /// Own the sole retained raw buffer. Reads never mutate it; release removes
    /// the object and uses non-elidable memset_s before deallocating its storage.
    private final class Snapshot {
        let sessionID: UUID
        let bytes: UnsafeMutablePointer<CChar>
        let count: Int
        let sha256: String
        init(sessionID: UUID, bytes: UnsafeMutablePointer<CChar>, count: Int, sha256: String) {
            self.sessionID = sessionID; self.bytes = bytes; self.count = count; self.sha256 = sha256
        }
        deinit {
            _ = memset_s(bytes, count, 0, count)
            bytes.deallocate()
        }
    }

    /// Request is the complete CLI envelope: command, optional id, and only the
    /// exact per-command fields below. Unknown fields are rejected, not ignored.
    static func handle(command: String, request: [String: Any]) throws -> [String: Any] {
        do {
            let run = try ScrivCLIRunCapability.requirePrepared()
            try run.validate()
            guard request["command"] as? String == command else { throw Failure() }
            switch command {
            case "coverage-snapshot":
                try keys(request, required: ["command"])
                guard snapshots.count < maximumSnapshots else { throw Failure() }
                var size: UInt64 = 0
                guard scriv_cli_coverage_size(&size) == 0, size > 0,
                      size <= UInt64(maximumBytes) else { throw Failure() }
                let count = Int(size)
                let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: count)
                buffer.initialize(repeating: 0, count: count)
                var transferred = false
                defer {
                    if !transferred { _ = memset_s(buffer, count, 0, count); buffer.deallocate() }
                }
                var written: UInt64 = 0
                guard scriv_cli_coverage_copy(buffer, size, &written) == 0, written == size else { throw Failure() }
                try run.validate()
                // The immutable snapshot remains in caller-owned memory. This
                // temporary hashing view does not copy the runtime buffer.
                let data = Data(bytesNoCopy: buffer, count: count, deallocator: .none)
                let digest = ScrivDigest.sha256(data)
                var token = UUID().uuidString.lowercased()
                while snapshots[token] != nil { token = UUID().uuidString.lowercased() }
                snapshots[token] = Snapshot(sessionID: run.sessionID, bytes: buffer, count: count, sha256: digest)
                transferred = true
                return ["schemaVersion": 1, "runID": run.sessionID.uuidString.lowercased(),
                        "workspaceID": run.runID.uuidString.lowercased(),
                        "token": token, "sha256": digest, "byteCount": count,
                        "maximumChunkBytes": maximumChunkBytes, "cumulative": true,
                        "format": "llvm-profraw"]
            case "coverage-read":
                try keys(request, required: ["command", "token", "offset", "length"])
                let snapshot = try lookup(request, sessionID: run.sessionID)
                let offset = try integer(request["offset"], minimum: 0, maximum: snapshot.count)
                let length = try integer(request["length"], minimum: 1, maximum: maximumChunkBytes)
                guard offset < snapshot.count else { throw Failure() }
                let count = min(length, snapshot.count - offset)
                let data = Data(bytesNoCopy: snapshot.bytes.advanced(by: offset), count: count, deallocator: .none)
                return ["schemaVersion": 1, "token": request["token"] as! String,
                        "offset": offset, "byteCount": count, "nextOffset": offset + count,
                        "eof": offset + count == snapshot.count, "base64": data.base64EncodedString()]
            case "coverage-release":
                try keys(request, required: ["command", "token"])
                _ = try lookup(request, sessionID: run.sessionID)
                let token = request["token"] as! String
                // No other retained reference exists after lookup returns.
                snapshots.removeValue(forKey: token)
                return ["schemaVersion": 1, "token": token, "released": true]
            default:
                throw Failure()
            }
        } catch { throw Failure() }
    }

    private static func keys(_ request: [String: Any], required: Set<String>) throws {
        let actual = Set(request.keys)
        guard required.isSubset(of: actual), actual.isSubset(of: required.union(["id"])) else { throw Failure() }
    }

    private static func lookup(_ request: [String: Any], sessionID: UUID) throws -> Snapshot {
        guard let token = request["token"] as? String, token.count == 36,
              let uuid = UUID(uuidString: token), uuid.uuidString.lowercased() == token,
              let snapshot = snapshots[token], snapshot.sessionID == sessionID else { throw Failure() }
        return snapshot
    }

    private static func integer(_ value: Any?, minimum: Int, maximum: Int) throws -> Int {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { throw Failure() }
        let scalar = number.doubleValue
        guard scalar.isFinite, scalar.rounded(.towardZero) == scalar,
              scalar >= Double(minimum), scalar <= Double(maximum) else { throw Failure() }
        return Int(scalar)
    }
}
#endif
