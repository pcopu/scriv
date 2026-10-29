import Foundation

/// A transport plan for one indivisible edit. Parts are immutable bytes, not
/// independently committed commands. Persist this value before the first upload.
public enum CloudAtomicBatch {
    public static let maximumOperations = 10_000
    public static let maximumBytes = 16 * 1024 * 1024
    public static let maximumPartBytes = 384 * 1024
    public static let maximumPartOperations = 100

    /// Only these structured failures are returned after the command-receipt
    /// lookup and before a successful transaction. Retain the rejected request
    /// as an audit copy, but allow its local draft to be reconciled into a new ID.
    /// Generic parsing, authorization, capacity and transport failures cannot
    /// establish whether an earlier attempt already committed.
    public static func isDefinitivelyUncommitted(status: Int, code: String) -> Bool {
        switch status {
        case 400:
            return ["invalid_reference", "image_version", "scene_too_long"].contains(code)
        case 409:
            return ["stale_epoch", "version_conflict", "timing_conflict", "batch_session_changed",
                    "item_in_use", "cue_timing", "cue_anchor", "kind_conflict", "immutable_image",
                    "schema_upgrade_required"].contains(code)
        case 413:
            return ["batch_history_too_large", "project_limit"].contains(code)
        case 423:
            return ["lease_required", "item_locked"].contains(code)
        default:
            return false
        }
    }

    public static func requiresStaging(_ command: JSONValue) throws -> Bool {
        let bytes = try ScrivJSON.encoder.encode(command).count
        return (command["operations"]?.array?.count ?? 0) > maximumPartOperations || bytes > 512 * 1024
    }
    public static func plan(_ command: JSONValue) throws -> JSONValue {
        guard case .object(var manifest) = command, let operations = command["operations"]?.array,
              !operations.isEmpty, operations.count <= maximumOperations else {
            throw ScrivError.invalid("One atomic edit supports up to 10,000 changed items. Your local draft is retained.")
        }
        var parts: [JSONValue] = [], descriptors: [JSONValue] = [], encoded: [Data] = [], count = 2, total = 0
        func finish() throws {
            guard !encoded.isEmpty else { return }
            var data = Data([91])
            for (index, operation) in encoded.enumerated() { if index > 0 { data.append(44) }; data.append(operation) }
            data.append(93); total += data.count
            guard total <= maximumBytes, parts.count < 1024, let content = String(data:data,encoding:.utf8) else {
                throw ScrivError.invalid("This atomic edit exceeds the 16 MiB upload limit. Your local draft is retained.")
            }
            parts.append(.string(content))
            descriptors.append(.object(["hash":.string(ScrivDigest.sha256(data)),"bytes":.number(Double(data.count)),"count":.number(Double(encoded.count))]))
            encoded = []; count = 2
        }
        for operation in operations {
            let data = try ScrivJSON.encoder.encode(operation)
            guard data.count + 2 <= maximumPartBytes else { throw ScrivError.invalid("One changed item exceeds the atomic upload-part limit.") }
            if !encoded.isEmpty && (encoded.count == maximumPartOperations || count + 1 + data.count > maximumPartBytes) { try finish() }
            count += data.count + (encoded.isEmpty ? 0 : 1); encoded.append(data)
        }
        try finish()
        manifest.removeValue(forKey:"operations")
        manifest["operationCount"] = .number(Double(operations.count)); manifest["parts"] = .array(descriptors)
        return .object(["manifest":.object(manifest),"parts":.array(parts)])
    }
}
