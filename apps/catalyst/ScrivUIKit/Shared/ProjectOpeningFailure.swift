import Foundation

/// Bounded, local-only diagnostics distinguish a picker grant/bookmark failure
/// from recovery or package decoding. Keep the original error for debugging;
/// never stringify userInfo, bookmark bytes, or a private project snapshot.
struct ProjectOpeningFailure: LocalizedError {
    enum Stage: String, CaseIterable {
        case rememberAccess = "retain the selected package's access"
        case restoreAccess = "restore the package's saved access"
        case recoverChanges = "check the package's pending changes"
        case readProject = "read the package's project metadata"
        case readCheckpoint = "read the package's sync checkpoint"
        case readHistory = "read the package's history"
    }
    let stage: Stage
    let underlying: Error
    static func annotating(_ error: Error, stage: Stage) -> Error {
        // Navigation cancellation is not a failed package and must stay silent.
        if error is CancellationError { return error }
        return ProjectOpeningFailure(stage: stage, underlying: error)
    }
    var errorDescription: String? {
        let source = underlying as NSError
        var code = "\(source.domain) \(source.code)"
        if let cause = source.userInfo[NSUnderlyingErrorKey] as? NSError {
            code += "; \(cause.domain) \(cause.code)"
        }
        return "Scriv could not \(stage.rawValue). \(source.localizedDescription) [\(code)]"
    }
}
