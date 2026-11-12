#if SCRIV_CLI_AUTOMATION
import Foundation

/// Bounded process totals from the original callback invocation sites. These
/// are not physical input events or successful controller/model operations.
/// No payload, source identity, closure, timestamp or event history is retained.
@MainActor
enum ScrivCLIInteractionCounts {
    private static let limit = 1_000_000
    private static var mergeAtStartInvocations = 0
    private static var onTextEditInvocations = 0
    private static var exhausted = false

    // This immutable launch check only suppresses recording outside CLI runs.
    // Observation also requires the existing strict filesystem/package gate.
    // There is deliberately no arm, reset or project/editor lifecycle API.
    private static let recordsInvocations: Bool = {
        let env = ProcessInfo.processInfo.environment
        guard CommandLine.arguments.contains("--scriv-cli"), CommandLine.arguments.contains("--screenshots"),
              let runID = env["SCRIV_CLI_RUN_ID"], runID.count == 36, UUID(uuidString: runID) != nil,
              let configured = env["SCRIV_VERIFICATION_ROOT"] else { return false }
        let expected = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScrivVerification-CLI-" + runID.lowercased()).standardizedFileURL
        return URL(fileURLWithPath: configured).standardizedFileURL.path == expected.path
    }()

    static func recordMergeAtStartInvocation() {
        guard recordsInvocations else { return }
        increment(&mergeAtStartInvocations)
    }

    static func recordOnTextEditInvocation() {
        guard recordsInvocations else { return }
        increment(&onTextEditInvocations)
    }

    private static func increment(_ count: inout Int) {
        guard count < limit else { exhausted = true; return }
        count += 1
    }

    private struct Failure: LocalizedError {
        var errorDescription: String? { "Synthetic interaction-count observation is unavailable or invalid." }
    }

    /// Read-only and cumulative for this process. Callers compare snapshots
    /// within the same isolated run; importing a project never resets totals.
    static func observe(workspace: ScrivWorkspaceController) throws -> [String: Any] {
        do {
            guard recordsInvocations, !exhausted else { throw Failure() }
            // Reuse, without relaxing, the run-root ownership/symlink checks,
            // mounted synthetic package check and allowed presentation scope.
            // Its model snapshot is discarded, never included in this result.
            _ = try ScrivCLILoadedProject.observe(workspace: workspace)
            return ["schemaVersion": 1,
                    "observation": "actual-script-callback-invocations",
                    "mergeAtStartInvocations": mergeAtStartInvocations,
                    "onTextEditInvocations": onTextEditInvocations]
        } catch { throw Failure() }
    }
}
#endif
