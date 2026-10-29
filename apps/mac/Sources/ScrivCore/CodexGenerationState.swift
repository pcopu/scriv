import Foundation

/// Correlates a local image job without depending on transport or AppKit.
/// Cancellation remains sticky while `turn/start` is awaiting its response.
public struct CodexGenerationState {
    public struct Turn: Equatable {
        public let threadID: String
        public let turnID: String
    }
    public private(set) var threadID: String?
    public private(set) var turnID: String?
    public private(set) var cancellationRequested = false
    public private(set) var completion: JSONValue?
    private var interruptionIssued = false
    private var earlyCompletions: [String: JSONValue] = [:]

    public init() {}
    public mutating func startThread(_ id: String) { threadID = id }
    /// Returns the late-started turn that must immediately be interrupted.
    public mutating func startTurn(_ id: String) -> Turn? {
        turnID = id
        completion = earlyCompletions[id]
        earlyCompletions.removeAll()
        return claimInterruption()
    }
    public var currentTurn: Turn? {
        guard let threadID, let turnID else { return nil }
        return Turn(threadID: threadID, turnID: turnID)
    }
    @discardableResult public mutating func requestCancellation() -> Turn? {
        cancellationRequested = true
        return claimInterruption()
    }
    private mutating func claimInterruption() -> Turn? {
        guard cancellationRequested, !interruptionIssued, let turn = currentTurn else { return nil }
        interruptionIssued = true
        return turn
    }
    public mutating func recordCompletion(threadID: String?, turn: JSONValue) {
        guard let expected = self.threadID, threadID == expected, let id = turn["id"]?.string else { return }
        if let turnID {
            if id == turnID { completion = turn }
        } else if earlyCompletions.count < 8 {
            // App-server may deliver the notification before the RPC response.
            earlyCompletions[id] = turn
        }
    }
}

/// File eligibility is shared by the native controller and portable regressions.
/// Image decoding is still performed by AppKit before anything is imported.
public enum CodexImageArtifacts {
    public static let maximumBytes = 25 * 1024 * 1024
    private static let extensions: Set<String> = ["png", "jpg", "jpeg", "webp"]

    public static func isEligible(_ file: URL, in directory: URL) -> Bool {
        guard file.isFileURL, extensions.contains(file.pathExtension.lowercased()),
              !file.lastPathComponent.lowercased().hasPrefix("reference-"),
              file.resolvingSymlinksInPath().path.hasPrefix(directory.resolvingSymlinksInPath().path + "/"),
              let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let count = values.fileSize, count > 0, count <= maximumBytes else { return false }
        return true
    }

    public static func candidates(in directory: URL, reported: [URL]) throws -> [URL] {
        let local = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]).sorted { $0.lastPathComponent < $1.lastPathComponent }
        let preferred = local.filter { $0.deletingPathExtension().lastPathComponent.lowercased() == "storyboard" }
        var seen: Set<URL> = []
        return (preferred + reported.reversed() + local).filter { isEligible($0, in: directory) && seen.insert($0.standardizedFileURL).inserted }
    }
}
