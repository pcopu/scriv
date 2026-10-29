import Foundation

/// This recovery context is local-only. Never serialize its package/runtime paths
/// as a cloud request. Only the exact submitted prompt is copied separately into
/// ImageAsset metadata, which syncs for personal and team projects alike.
public struct GenerationJobContext: Codable, Hashable, Sendable {
    public var projectID: String
    public var projectTitle: String
    public var packagePath: String
    public var targetCue: ImageCue
    public var sourceRevision: Int
    public var cloudProjectID: String?
    public var cloudServer: String?
    public var accountID: String?
    public var deviceID: String?
    public var sourceHeadSeq: Int?
    public var sourceItemVersion: Int?
    /// The manual direction is distinct from the complete submitted prompt and
    /// remains the image's editable `prompt` field.
    public var userDirection: String?
    public init(projectID: String, projectTitle: String, packagePath: String, targetCue: ImageCue, sourceRevision: Int,
                cloudProjectID: String? = nil, cloudServer: String? = nil, accountID: String? = nil,
                deviceID: String? = nil, sourceHeadSeq: Int? = nil, sourceItemVersion: Int? = nil, userDirection: String? = nil) {
        self.projectID = projectID; self.projectTitle = projectTitle; self.packagePath = packagePath
        self.targetCue = targetCue; self.sourceRevision = sourceRevision; self.cloudProjectID = cloudProjectID
        self.cloudServer = cloudServer; self.accountID = accountID; self.deviceID = deviceID
        self.sourceHeadSeq = sourceHeadSeq; self.sourceItemVersion = sourceItemVersion
        self.userDirection = userDirection
    }
}

public struct LocalGenerationJob: Codable, Identifiable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable {
        case queued, running, waiting, completed, cancelled, failed
        public var label: String {
            switch self {
            case .queued: return "Preparing on this Mac"
            case .running: return "Running on this Mac"
            case .waiting: return "Waiting for this Mac"
            case .completed: return "Image ready"
            case .cancelled: return "Cancelled"
            case .failed: return "Failed"
            }
        }
    }
    public struct Reference: Codable, Hashable, Sendable {
        public var fileName: String
        public var sha256: String
        public init(fileName: String, sha256: String) { self.fileName = fileName; self.sha256 = sha256 }
    }
    public var id: String
    public var ownerInstallationID: String
    public var context: GenerationJobContext?
    public var prompt: String
    /// Frozen effective turn text, including Scriv's instruction wrapper. Older
    /// journals remain nil: recovering an output must never invent its prompt.
    public var submittedPrompt: String?
    public var model: String
    public var runtimeIdentity: String
    public var retryOf: String?
    public var status: Status
    public var progressText: String
    public var createdAt: Date
    public var updatedAt: Date
    public var references: [Reference]
    public var threadID: String?
    public var turnID: String?
    public var artifactRelativePath: String?
    public var artifactSha256: String?
    public var outputImageID: String?
    public var errorDetail: String?
    public var errorCode: String?
    public init(id: String = UUID().uuidString, ownerInstallationID: String, context: GenerationJobContext?,
                prompt: String, submittedPrompt: String? = nil, model: String, runtimeIdentity: String, retryOf: String? = nil) {
        self.id = id.lowercased(); self.ownerInstallationID = ownerInstallationID; self.context = context
        self.prompt = prompt; self.submittedPrompt = submittedPrompt; self.model = model; self.runtimeIdentity = runtimeIdentity; self.retryOf = retryOf
        status = .queued; progressText = "Preparing reference images"; references = []
        createdAt = ScrivClock.now; updatedAt = createdAt
    }
    /// Restart never equates a missing response with failure and never resubmits.
    public mutating func recoverAfterRestart() {
        if status == .queued || status == .running {
            status = .waiting; progressText = "Inspect the original turn before retrying. No new generation has been submitted."
            updatedAt = ScrivClock.now
        }
    }
    public var canRetry: Bool { status == .failed || status == .cancelled || status == .waiting }
}

/// Safe project-visible progress metadata; no local path, references or Codex IDs.
/// Completed image versions carry their captured prompt separately as ImageAsset.
public struct CloudGenerationJob: Codable, Identifiable, Hashable, Sendable {
    public var schemaVersion: Int
    public var id: String
    public var projectId: String
    public var targetItemId: String
    public var sourceRevision: Int
    public var status: LocalGenerationJob.Status
    public var progressText: String
    public var createdAt: Int
    public var updatedAt: Int
    public var outputImageId: String?
    public var errorCode: String?
    public var createdBy: String
    public var ownerDeviceId: String
    public var ownerDeviceName: String
    public var version: Int
    public var leaseExpiresAt: Int
}

/// Small atomic journals live outside the tool's per-job writable directory.
/// The owner calls this synchronously when crossing a usage-sensitive RPC boundary.
public struct GenerationJournal {
    public let root: URL
    public init(root: URL) throws {
        if FileManager.default.fileExists(atPath: root.path), try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw ScrivError.invalid("Generation journal must not be a symbolic link.") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }
    public func save(_ job: LocalGenerationJob) throws {
        try Self.validate(job)
        let data = try ScrivJSON.encoder.encode(job)
        guard data.count <= 2 * 1024 * 1024 else { throw ScrivError.invalid("Generation journal exceeds its size limit.") }
        let url = try file(job.id)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func load() throws -> (jobs: [LocalGenerationJob], unreadable: Int) {
        var jobs: [LocalGenerationJob] = [], unreadable = 0
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey]) where url.pathExtension == "json" {
            do {
                let id = url.deletingPathExtension().lastPathComponent
                let source = try file(id), values = try source.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true, let size = values.fileSize, size <= 2 * 1024 * 1024 else { throw ScrivError.invalid("Invalid journal file.") }
                let data = try Data(contentsOf: source)
                guard data.count <= 2 * 1024 * 1024 else { throw ScrivError.invalid("Oversized journal.") }
                let job = try ScrivJSON.decoder.decode(LocalGenerationJob.self, from: data)
                try Self.validate(job)
                guard job.id == id else { throw ScrivError.invalid("Journal identity mismatch.") }
                jobs.append(job)
            } catch { unreadable += 1 }
        }
        return (jobs.sorted { $0.createdAt > $1.createdAt }, unreadable)
    }
    private func file(_ id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw ScrivError.invalid("Invalid generation identity.") }
        let file = root.appendingPathComponent(id + ".json")
        guard file.resolvingSymlinksInPath() == file else { throw ScrivError.invalid("Generation journal links are not allowed.") }
        return file
    }
    private static func validate(_ job: LocalGenerationJob) throws {
        if let submittedPrompt = job.submittedPrompt { try GenerationPrompt.validate(submittedPrompt) }
        guard UUID(uuidString: job.id) != nil, UUID(uuidString: job.ownerInstallationID) != nil,
              job.prompt.utf8.count <= 1_000_000, job.model.count <= 256, job.runtimeIdentity.count <= 2048,
              job.createdAt.timeIntervalSince1970.isFinite, job.updatedAt.timeIntervalSince1970.isFinite,
              job.references.count <= 5, job.progressText.count <= 1000,
              (job.context?.sourceRevision ?? 0) >= 0 else { throw ScrivError.invalid("Invalid generation journal.") }
        for reference in job.references {
            guard reference.fileName == URL(fileURLWithPath: reference.fileName).lastPathComponent,
                  reference.fileName.hasPrefix("reference-"), !reference.fileName.contains(".."),
                  reference.sha256.count == 64, reference.sha256.allSatisfy({ $0.isHexDigit }) else { throw ScrivError.invalid("Invalid generation reference snapshot.") }
        }
        if let path = job.artifactRelativePath {
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains(".."), !path.isEmpty else { throw ScrivError.invalid("Invalid local image location.") }
        }
    }
}
