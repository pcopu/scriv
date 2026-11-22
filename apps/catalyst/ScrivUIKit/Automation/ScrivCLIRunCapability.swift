#if SCRIV_CLI_AUTOMATION
import Foundation
import Darwin

/// Created before UIApplicationMain. A resume needs an inherited descriptor
/// from the owning driver as well as a UUID; no caller-supplied path is accepted.
final class ScrivCLIRunCapability {
    struct Failure: LocalizedError {
        var errorDescription: String? { "Isolated CLI cloud access is unavailable." }
    }
    private static var prepared: ScrivCLIRunCapability?
    private static let maximumRecordBytes = 64 * 1024 * 1024
    private static let maximumOutboxFiles = 256
    private static let maximumWorkspaceEntries = 4096
    private static let maximumWorkspaceDepth = 32
    private static let persistentMarker = ".scriv-cli-persistent"
    private static let sessionLock = ".scriv-cli-session.lock"
    private static let cloudFixtureFlag = "--scriv-cli-cloud-fixture"
    let runID: UUID
    let sessionID: UUID
    let persistent: Bool
    let resumed: Bool
    let root: URL
    let approvedOrigin: URL?
    private let namedRoot: URL
    private let rootFD: Int32
    private let outboxFD: Int32
    private let lockFD: Int32
    private let markerFD: Int32
    private var scopes: [String: Int32] = [:]

    private init(runID: UUID, sessionID: UUID, persistent: Bool, resumed: Bool,
                 root: URL, namedRoot: URL, rootFD: Int32, outboxFD: Int32,
                 lockFD: Int32, markerFD: Int32, approvedOrigin: URL?) throws {
        if let approvedOrigin { try Self.validateLoopbackOrigin(approvedOrigin) }
        self.runID = runID; self.sessionID = sessionID
        self.persistent = persistent; self.resumed = resumed
        self.root = root; self.namedRoot = namedRoot
        self.rootFD = rootFD; self.outboxFD = outboxFD
        self.lockFD = lockFD; self.markerFD = markerFD; self.approvedOrigin = approvedOrigin
    }
    deinit {
        for fd in scopes.values { close(fd) }
        if markerFD >= 0 { close(markerFD) }
        close(lockFD); close(outboxFD); close(rootFD)
    }
    static func prepare() throws {
        let arguments = CommandLine.arguments
        let freshPersistent = arguments.contains("--scriv-cli-persistent")
        let resumed = arguments.contains("--scriv-cli-resume")
        let cloudFixture = arguments.contains(cloudFixtureFlag)
        guard arguments.contains("--scriv-cli") else {
            guard !freshPersistent, !resumed, !cloudFixture else { throw Failure() }
            return
        }
        guard prepared == nil, arguments.contains("--screenshots"),
              !(freshPersistent && resumed), let pointer = getenv("SCRIV_CLI_RUN_ID") else { throw Failure() }
        let runID = try canonicalID(String(cString: pointer))
        let sessionID: UUID
        if let pointer = getenv("SCRIV_CLI_SESSION_ID") {
            sessionID = try canonicalID(String(cString: pointer))
        } else {
            guard !resumed else { throw Failure() }
            sessionID = runID
        }
        guard !resumed || sessionID != runID else { throw Failure() }
        let persistent = freshPersistent || resumed
        guard !cloudFixture || (!persistent && sessionID == runID) else { throw Failure() }
        let approvedOrigin = cloudFixture ? try readCloudFixtureOrigin(3, runID: runID) : nil

        // Duplicate FD3 before any open can occupy that descriptor. Never lock
        // the inherited root: flock would share the driver's open description.
        var rootFD: Int32 = -1, outboxFD: Int32 = -1, lockFD: Int32 = -1, markerFD: Int32 = -1
        var transferred = false
        defer {
            if !transferred {
                for fd in [markerFD, lockFD, outboxFD, rootFD] where fd >= 0 { close(fd) }
            }
        }
        if resumed {
            rootFD = fcntl(3, F_DUPFD_CLOEXEC, 4)
            guard rootFD >= 0 else { throw Failure() }
            close(3)
        }
        let temporary = FileManager.default.temporaryDirectory
        let name = "ScrivVerification-CLI-" + runID.uuidString.lowercased()
        let root = temporary.appendingPathComponent(name, isDirectory: true)
        let namedRoot = temporary.resolvingSymlinksInPath().appendingPathComponent(name, isDirectory: true)
        let parent = open(temporary.resolvingSymlinksInPath().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw Failure() }
        defer { close(parent) }
        if resumed {
            var info = stat()
            guard fstat(rootFD, &info) == 0, privateDirectory(info),
                  childMatches(name, parent: parent, descriptor: rootFD) else { throw Failure() }
        } else {
            // The safe default still creates an exclusive, fresh UUID root.
            // An existing root is never reused, reset, repaired or removed.
            guard mkdirat(parent, name, mode_t(0o700)) == 0 else { throw Failure() }
            rootFD = try openDirectory(name, parent: parent)
            guard mkdirat(rootFD, "Outbox", mode_t(0o700)) == 0 else { throw Failure() }
        }
        outboxFD = try openDirectory("Outbox", parent: rootFD)
        // Each process independently opens this file and holds an exclusive
        // nonblocking lock for its lifetime. Resume may not recreate it.
        lockFD = openat(rootFD, sessionLock,
                        O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (resumed ? 0 : O_CREAT | O_EXCL), mode_t(0o600))
        var lockInfo = stat()
        guard lockFD >= 0, fstat(lockFD, &lockInfo) == 0, privateFile(lockInfo), lockInfo.st_size == 0,
              childMatches(sessionLock, parent: rootFD, descriptor: lockFD),
              flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw Failure() }
        if persistent {
            markerFD = openat(rootFD, persistentMarker,
                              (resumed ? O_RDONLY : O_RDWR | O_CREAT | O_EXCL) | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, mode_t(0o600))
            guard markerFD >= 0 else { throw Failure() }
            if !resumed {
                let bytes = markerBytes(runID)
                try bytes.withUnsafeBytes { buffer in
                    var offset = 0
                    while offset < buffer.count {
                        guard let base = buffer.baseAddress else { throw Failure() }
                        let count = Darwin.write(markerFD, base.advanced(by: offset), buffer.count - offset)
                        if count < 0 && errno == EINTR { continue }
                        guard count > 0 else { throw Failure() }
                        offset += count
                    }
                }
                guard fsync(markerFD) == 0, fsync(rootFD) == 0 else { throw Failure() }
            }
            try validateMarker(markerFD, parent: rootFD, runID: runID)
        }
        let run = try ScrivCLIRunCapability(runID: runID, sessionID: sessionID, persistent: persistent, resumed: resumed,
                                           root: root, namedRoot: namedRoot, rootFD: rootFD, outboxFD: outboxFD,
                                           lockFD: lockFD, markerFD: markerFD, approvedOrigin: approvedOrigin)
        transferred = true
        guard setenv("SCRIV_VERIFICATION_ROOT", root.path, 1) == 0,
              setenv("SCRIV_CLI_SESSION_ID", sessionID.uuidString.lowercased(), 1) == 0 else { throw Failure() }
        try run.validate()
        if resumed {
            // Validate the entire retained tree before UIApplicationMain can
            // construct repositories, generation stores or journal readers.
            // No chmod, directory creation, recovery or migration occurs here.
            var budget = maximumWorkspaceEntries
            var info = stat()
            guard fstat(rootFD, &info) == 0 else { throw Failure() }
            try validateDescendants(rootFD, device: info.st_dev, depth: 0, budget: &budget)
            try run.validate()
        }
        prepared = run
    }
    private static func canonicalID(_ raw: String) throws -> UUID {
        guard raw.count == 36, let value = UUID(uuidString: raw),
              raw.lowercased() == value.uuidString.lowercased() else { throw Failure() }
        return value
    }
    private static func readCloudFixtureOrigin(_ descriptor: Int32, runID: UUID) throws -> URL {
        defer { close(descriptor) }
        var info = stat()
        let flags = fcntl(descriptor, F_GETFL)
        // FD3 carries an unlinked, read-only grant for this fresh app process.
        guard flags >= 0, flags & O_ACCMODE == O_RDONLY, fstat(descriptor, &info) == 0,
              info.st_uid == geteuid(), info.st_nlink == 0, info.st_mode == S_IFREG | 0o600,
              (1...128).contains(info.st_size) else { throw Failure() }
        var bytes = Data(count: Int(info.st_size))
        let count = bytes.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, 0) }
        guard count == bytes.count, let grant = String(data: bytes, encoding: .utf8) else { throw Failure() }
        let fields = grant.split(separator: "\n", omittingEmptySubsequences: false)
        guard fields.count == 4, fields[0] == "ScrivCLICloudFixture-v1",
              fields[1] == runID.uuidString.lowercased(), fields[3].isEmpty,
              let origin = URL(string: String(fields[2])),
              let port = origin.port, fields[2] == "http://127.0.0.1:\(port)" else { throw Failure() }
        try validateLoopbackOrigin(origin)
        return origin
    }
    private static func markerBytes(_ runID: UUID) -> Data {
        Data(("ScrivCLIWorkspace-v1\n" + runID.uuidString.lowercased() + "\n").utf8)
    }
    private static func validateMarker(_ descriptor: Int32, parent: Int32, runID: UUID) throws {
        let expected = markerBytes(runID)
        var info = stat()
        guard fstat(descriptor, &info) == 0, privateFile(info), info.st_size == expected.count,
              childMatches(persistentMarker, parent: parent, descriptor: descriptor) else { throw Failure() }
        var bytes = Data(count: expected.count)
        try bytes.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                guard let base = buffer.baseAddress else { throw Failure() }
                let count = pread(descriptor, base.advanced(by: offset), buffer.count - offset, off_t(offset))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure() }
                offset += count
            }
        }
        guard bytes == expected, fstat(descriptor, &info) == 0, privateFile(info), info.st_size == expected.count,
              childMatches(persistentMarker, parent: parent, descriptor: descriptor) else { throw Failure() }
    }
    private static func validateDescendants(_ parent: Int32, device: dev_t, depth: Int, budget: inout Int) throws {
        guard depth < maximumWorkspaceDepth else { throw Failure() }
        let listing = openat(parent, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard listing >= 0 else { throw Failure() }
        guard let stream = fdopendir(listing) else { close(listing); throw Failure() }
        defer { closedir(stream) }
        while true {
            errno = 0
            guard let entry = readdir(stream) else { guard errno == 0 else { throw Failure() }; break }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(validatingCString: $0) }
            }
            guard let name, !name.isEmpty, name.utf8.count <= Int(NAME_MAX), !name.contains("/") else { throw Failure() }
            guard name != ".", name != ".." else { continue }
            guard budget > 0 else { throw Failure() }
            budget -= 1
            var named = stat()
            guard fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  safeDescendant(named, device: device) else { throw Failure() }
            let directory = (named.st_mode & S_IFMT) == S_IFDIR
            let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (directory ? O_DIRECTORY : 0))
            guard fd >= 0 else { throw Failure() }
            defer { close(fd) }
            var opened = stat()
            guard fstat(fd, &opened) == 0, safeDescendant(opened, device: device), sameFile(named, opened),
                  childMatches(name, parent: parent, descriptor: fd) else { throw Failure() }
            if directory { try validateDescendants(fd, device: device, depth: depth + 1, budget: &budget) }
            guard fstat(fd, &opened) == 0, safeDescendant(opened, device: device),
                  childMatches(name, parent: parent, descriptor: fd) else { throw Failure() }
        }
    }
    private static func safeDescendant(_ info: stat, device: dev_t) -> Bool {
        guard info.st_uid == geteuid(), info.st_dev == device, (info.st_mode & 0o7022) == 0 else { return false }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return (info.st_mode & 0o700) == 0o700
        case S_IFREG: return info.st_nlink == 1 && info.st_size >= 0
        default: return false // Includes symlinks, FIFOs, sockets and devices.
        }
    }
    /// Called before CloudClient accesses preferences, origins, or credentials.
    /// A requested CLI launch with absent/broken preparation terminates instead
    /// of silently constructing the production Keychain backend.
    static func forCloudConstruction() -> ScrivCLIRunCapability? {
        guard CommandLine.arguments.contains("--scriv-cli") else { return nil }
        guard let run = prepared, (try? run.validate()) != nil else {
            fatalError("Isolated CLI setup is invalid")
        }
        return run
    }
    static func requirePrepared() throws -> ScrivCLIRunCapability {
        guard let run = prepared else { throw Failure() }
        try run.validate(); return run
    }
    func validate() throws {
        guard CommandLine.arguments.contains("--scriv-cli"), CommandLine.arguments.contains("--screenshots"),
              let id = getenv("SCRIV_CLI_RUN_ID"), String(cString: id).lowercased() == runID.uuidString.lowercased(),
              let session = getenv("SCRIV_CLI_SESSION_ID"), String(cString: session) == sessionID.uuidString.lowercased(),
              CommandLine.arguments.contains("--scriv-cli-resume") == resumed,
              CommandLine.arguments.contains("--scriv-cli-persistent") == (persistent && !resumed),
              CommandLine.arguments.contains(Self.cloudFixtureFlag) == (approvedOrigin != nil),
              let path = getenv("SCRIV_VERIFICATION_ROOT"), String(cString: path) == root.path,
              namedRoot.resolvingSymlinksInPath() == namedRoot,
              root.resolvingSymlinksInPath() == namedRoot else { throw Failure() }
        var named = stat(), opened = stat()
        guard lstat(namedRoot.path, &named) == 0, fstat(rootFD, &opened) == 0,
              Self.privateDirectory(opened), Self.sameFile(named, opened),
              Self.childMatches("Outbox", parent: rootFD, descriptor: outboxFD) else { throw Failure() }
        var outbox = stat()
        guard fstat(outboxFD, &outbox) == 0, Self.privateDirectory(outbox) else { throw Failure() }
        var lock = stat()
        guard fstat(lockFD, &lock) == 0, Self.privateFile(lock), lock.st_size == 0,
              Self.childMatches(Self.sessionLock, parent: rootFD, descriptor: lockFD) else { throw Failure() }
        if persistent { try Self.validateMarker(markerFD, parent: rootFD, runID: runID) }
    }
    /// Anchor a read-only caller's opened root to this capability's retained
    /// inode, not merely to a pathname observed in two separate validations.
    func validateRootDescriptor(_ descriptor: Int32) throws {
        try validate()
        var candidate = stat(), retained = stat()
        guard fstat(descriptor, &candidate) == 0, fstat(rootFD, &retained) == 0,
              Self.privateDirectory(candidate), Self.privateDirectory(retained),
              Self.sameFile(candidate, retained) else { throw Failure() }
    }
    var publicStatus: [String: Any] {
        ["credentials": "process-memory", "outbox": "private-run-root", "network": approvedOrigin == nil ? "disabled" : "loopback-only",
         "oauth": "disabled", "peerTransport": "disabled"]
    }
    static func validateLoopbackOrigin(_ url: URL) throws {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme == "http", c.host == "127.0.0.1", let port = c.port, (1...65535).contains(port),
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.path.isEmpty || c.path == "/",
              url.absoluteString == "http://127.0.0.1:\(port)" || url.absoluteString == "http://127.0.0.1:\(port)/" else { throw Failure() }
    }
    func authorizeNetwork(_ url: URL, webSocket: Bool = false) throws {
        try validate()
        guard let approvedOrigin else { throw Failure() }
        try Self.validateLoopbackOrigin(approvedOrigin)
        guard let allowed = URLComponents(url: approvedOrigin, resolvingAgainstBaseURL: false),
              let candidate = URLComponents(url: url, resolvingAgainstBaseURL: false),
              candidate.scheme == (webSocket ? "ws" : "http"), candidate.host == allowed.host,
              candidate.port == allowed.port, candidate.user == nil, candidate.password == nil,
              candidate.fragment == nil else { throw Failure() }
    }
    func authorizeOriginChange(_ url: URL) throws {
        try validate()
        try Self.validateLoopbackOrigin(url)
        guard let approvedOrigin, url == approvedOrigin else { throw Failure() }
    }

    // All isolated outbox operations are descriptor-relative. No caller path is
    // followed, even if a run-owned directory/file is replaced with a symlink.
    func outboxDirectory(scope: String) throws -> URL {
        _ = try scopeDescriptor(scope)
        return root.appendingPathComponent("Outbox", isDirectory: true).appendingPathComponent(scope, isDirectory: true)
    }
    private func scopeDescriptor(_ scope: String) throws -> Int32 {
        try validate()
        guard scope.count == 64, scope.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw Failure() }
        if let fd = scopes[scope] {
            var info = stat()
            guard fstat(fd, &info) == 0, Self.privateDirectory(info), Self.childMatches(scope, parent: outboxFD, descriptor: fd) else { throw Failure() }
            return fd
        }
        // Only this process creates scope directories; preexisting names fail.
        guard mkdirat(outboxFD, scope, mode_t(0o700)) == 0 else { throw Failure() }
        let fd = try Self.openDirectory(scope, parent: outboxFD)
        scopes[scope] = fd
        return fd
    }
    private func location(_ url: URL) throws -> (Int32, String) {
        guard url.isFileURL, url == url.standardizedFileURL,
              url.deletingLastPathComponent().deletingLastPathComponent() == root.appendingPathComponent("Outbox", isDirectory: true) else { throw Failure() }
        let name = url.lastPathComponent
        guard !name.isEmpty, name.utf8.count <= 255, name != ".", name != "..",
              name.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 }) else { throw Failure() }
        return (try scopeDescriptor(url.deletingLastPathComponent().lastPathComponent), name)
    }
    func files(in directory: URL) throws -> [URL] {
        let fd = try scopeDescriptor(directory.lastPathComponent)
        guard directory == root.appendingPathComponent("Outbox", isDirectory: true).appendingPathComponent(directory.lastPathComponent, isDirectory: true) else { throw Failure() }
        // openat(".") gives a fresh directory offset; dup would share it.
        let listing = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard listing >= 0 else { throw Failure() }
        guard let stream = fdopendir(listing) else { close(listing); throw Failure() }
        defer { closedir(stream) }
        var result: [URL] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else { guard errno == 0 else { throw Failure() }; break }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            guard name != ".", name != ".." else { continue }
            guard result.count < Self.maximumOutboxFiles else { throw Failure() }
            let url = directory.appendingPathComponent(name)
            _ = try location(url)
            // Reject unexpected entries rather than skipping a tampered file.
            _ = try fileInfo(url)
            result.append(url)
        }
        try validate(); return result
    }
    private func openFile(_ url: URL) throws -> Int32 {
        let (parent, name) = try location(url)
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Failure() }
        var info = stat()
        guard fstat(fd, &info) == 0, Self.privateFile(info), Self.childMatches(name, parent: parent, descriptor: fd) else {
            close(fd); throw Failure()
        }
        return fd
    }
    private func fileInfo(_ url: URL) throws -> stat {
        let fd = try openFile(url); defer { close(fd) }
        var info = stat(); guard fstat(fd, &info) == 0 else { throw Failure() }; return info
    }
    func exists(_ url: URL) throws -> Bool {
        let (parent, name) = try location(url)
        var info = stat()
        if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw Failure() }; return false
        }
        guard Self.privateFile(info) else { throw Failure() }
        return true
    }
    func read(_ url: URL) throws -> Data {
        let fd = try openFile(url)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size >= 0, info.st_size <= Self.maximumRecordBytes else { throw Failure() }
        var bytes = Data()
        // Check actual bytes as well as stat: a regular file can grow mid-read.
        do {
            while true {
                let remaining = Self.maximumRecordBytes + 1 - bytes.count
                guard remaining > 0 else { throw Failure() }
                let chunk = try handle.read(upToCount: min(64 * 1024, remaining)) ?? Data()
                if chunk.isEmpty { break }
                bytes.append(chunk)
                guard bytes.count <= Self.maximumRecordBytes else { throw Failure() }
            }
        } catch { throw Failure() } // Never forward a filesystem error/path.
        let (parent, name) = try location(url)
        guard Self.childMatches(name, parent: parent, descriptor: fd),
              fstat(fd, &info) == 0, Self.privateFile(info), info.st_size == bytes.count else { throw Failure() }
        return bytes
    }
    func creationDate(_ url: URL) throws -> Date {
        let info = try fileInfo(url)
        return Date(timeIntervalSince1970: Double(info.st_birthtimespec.tv_sec) + Double(info.st_birthtimespec.tv_nsec) / 1_000_000_000)
    }
    func write(_ bytes: Data, to url: URL) throws {
        guard bytes.count <= Self.maximumRecordBytes else { throw Failure() }
        let (parent, name) = try location(url)
        let temporary = "pending-" + UUID().uuidString
        let fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw Failure() }
        defer {
            if Self.childMatches(temporary, parent: parent, descriptor: fd) { _ = unlinkat(parent, temporary, 0) }
            close(fd)
        }
        var info = stat()
        guard fstat(fd, &info) == 0, Self.privateFile(info) else { throw Failure() }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                guard let base = buffer.baseAddress else { throw Failure() }
                let count = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure() }; offset += count
            }
        }
        guard fsync(fd) == 0 else { throw Failure() }
        _ = try location(url); _ = try exists(url)
        guard Self.childMatches(temporary, parent: parent, descriptor: fd),
              renameat(parent, temporary, parent, name) == 0 else { throw Failure() }
    }
    func remove(_ url: URL) throws {
        let fd = try openFile(url); defer { close(fd) }
        let (parent, name) = try location(url)
        guard Self.childMatches(name, parent: parent, descriptor: fd), unlinkat(parent, name, 0) == 0 else { throw Failure() }
    }
    func move(_ source: URL, to destination: URL) throws {
        let fd = try openFile(source); defer { close(fd) }
        let (parent, name) = try location(source), (other, target) = try location(destination)
        guard parent == other, !(try exists(destination)), Self.childMatches(name, parent: parent, descriptor: fd),
              renameatx_np(parent, name, other, target, UInt32(RENAME_EXCL)) == 0 else { throw Failure() }
    }
    private static func privateDirectory(_ info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == geteuid() && (info.st_mode & 0o7777) == 0o700
    }
    private static func privateFile(_ info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFREG && info.st_uid == geteuid() && info.st_nlink == 1 && (info.st_mode & 0o7777) == 0o600
    }
    private static func sameFile(_ a: stat, _ b: stat) -> Bool {
        (a.st_mode & S_IFMT) == (b.st_mode & S_IFMT) && a.st_dev == b.st_dev && a.st_ino == b.st_ino
    }
    private static func childMatches(_ name: String, parent: Int32, descriptor: Int32) -> Bool {
        var named = stat(), opened = stat()
        return fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0 && fstat(descriptor, &opened) == 0 && sameFile(named, opened)
    }
    private static func openDirectory(_ name: String, parent: Int32) throws -> Int32 {
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure() }
        var info = stat()
        guard fstat(fd, &info) == 0, privateDirectory(info), childMatches(name, parent: parent, descriptor: fd) else { close(fd); throw Failure() }
        return fd
    }
}

/// No token installation/export command. Only production sign-in handlers can
/// write a session, and no sign-in network destination is enabled in this batch.
@MainActor
final class ScrivCLIMemoryCredentials: CloudCredentialBackend {
    private let run: ScrivCLIRunCapability
    private var values: [String: String] = [:]
    init(run: ScrivCLIRunCapability) { self.run = run }
    func read(account: String) throws -> String? { try run.validate(); return values[account] }
    func write(_ token: String, account: String) throws { try run.validate(); try delete(account: account); values[account] = token }
    func delete(account: String) throws { try run.validate(); values.removeValue(forKey: account) }
}
#endif
