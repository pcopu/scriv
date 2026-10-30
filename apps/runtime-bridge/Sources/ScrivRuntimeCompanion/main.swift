import Foundation
import Network
import Security
import CoreServices
import Darwin
import ScrivCore

/// Deliberately headless macOS companion: no AppKit/SwiftUI/hosting UI and no
/// daemon registration. The user launches its signed app explicitly. Launching
/// only opens the local authenticated listener; Codex starts on a later signed
/// Start request. macOS URL activation is a launch affordance, never a command.
final class RuntimeCompanion {
    private let queue = DispatchQueue(label: "Scriv.RuntimeCompanion")
    private var listener: NWListener?
    private var pairing: RuntimeBridgePairing?
    private var replay = RuntimeBridgeReplayWindow()
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var stderr: FileHandle?
    private var outputBuffer = Data()
    private var events: [RuntimeBridgeEvent] = []
    private var eventBytes = 0
    private var nextSequence = 1
    private var ownerSession: UUID?
    private var generationRoot: URL?
    private var leaseAt = Date()
    private var leaseTimer: DispatchSourceTimer?
    private var peers = 0
    private var signals: [DispatchSourceSignal] = []
    private var lockFD: Int32 = -1
    private var pairingURL: URL?
    private var failure: String?
    private let instanceID = UUID()
    private let launchEvents = CompanionLaunchEvents()
    func start() throws {
        // A user-owned, non-symlink private folder; never follow someone else's
        // pairing symlink or overwrite a running instance's capability.
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ScrivRuntimeCompanion", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard folder.standardizedFileURL == folder.resolvingSymlinksInPath(), let attrs = try? FileManager.default.attributesOfItem(atPath: folder.path), (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid() else { throw ScrivError.permission("The companion directory is not owned by this Mac account.") }
        guard chmod(folder.path, 0o700) == 0 else { throw ScrivError.permission("The companion directory could not be made private.") }
        lockFD = open(folder.appendingPathComponent("instance.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw ScrivError.conflict("The runtime companion is already open.") }
        guard fchmod(lockFD, 0o600) == 0 else { throw ScrivError.permission("The companion lock could not be made private.") }
        let destination = folder.appendingPathComponent("Pair with Scriv.scrivbridge")
        pairingURL = destination
        let existing = try readPairing(destination)
        let secret = try existing?.secret ?? randomSecret()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: existing.flatMap { NWEndpoint.Port(rawValue: $0.port) } ?? .any)
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = false
        let listener = try NWListener(using: parameters); self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                do {
                    guard let port = listener.port else { throw ScrivError.unavailable("The local runtime listener has no port.") }
                    let pair = existing ?? RuntimeBridgePairing(ownerUID: geteuid(), port: port.rawValue, secret: secret)
                    guard pair.port == port.rawValue else { throw ScrivError.permission("The paired local port changed unexpectedly.") }
                    if existing == nil { try self.writePairing(pair) }
                    self.pairing = pair
                } catch { self.shutdown(); exit(EXIT_FAILURE) }
            case .failed: self.shutdown(); exit(EXIT_FAILURE)
            default: break
            }
        }
        NSAppleEventManager.shared().setEventHandler(launchEvents, andSelector: #selector(CompanionLaunchEvents.receive(_:reply:)), forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            // Binding 127.0.0.1 is the enforcement boundary. Also reject anything
            // unexpected instead of treating an arbitrary endpoint as local.
            guard case .hostPort(let host, _) = connection.endpoint,
                  host == .ipv4(.loopback), self.peers < 16 else { connection.cancel(); return }
            self.peers += 1
            CompanionConnection(connection: connection, queue: self.queue) { [weak self] data, respond in
                guard let self else { respond(nil); return }
                defer { self.peers -= 1 }
                respond(self.handle(data))
            }.start()
        }
        listener.start(queue: queue)
        let timer = DispatchSource.makeTimerSource(queue: queue); leaseTimer = timer
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in guard let self, self.process != nil, Date().timeIntervalSince(self.leaseAt) > 35 else { return }; self.stopOwned(); self.failure = "The app connection ended. The owned runtime was stopped; inspect the original turn before retrying." }
        timer.resume()
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN); let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [weak self] in self?.shutdown(); exit(EXIT_SUCCESS) }; source.resume(); signals.append(source)
        }
    }
    private func randomSecret() throws -> Data {
        var key = Data(count: 32)
        guard key.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }) == errSecSuccess else { throw ScrivError.unavailable("Secure local pairing could not be created.") }
        return key
    }
    private func readPairing(_ url: URL) throws -> RuntimeBridgePairing? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        if fd < 0 { if errno == ENOENT { return nil }; throw ScrivError.permission("The existing local pairing file could not be opened safely.") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0, info.st_size > 0, info.st_size <= 4096 else { close(fd); throw ScrivError.permission("The local pairing file must be private to your Mac account.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
        let data = try handle.read(upToCount: 4096) ?? Data()
        let pair = try JSONDecoder().decode(RuntimeBridgePairing.self, from: data); try pair.validate(ownerUID: geteuid()); return pair
    }
    private func writePairing(_ pair: RuntimeBridgePairing) throws {
        guard let destination = pairingURL else { throw ScrivError.invalid("The local pairing destination is unavailable.") }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent("pair-\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ScrivError.unavailable("The pairing file could not be created privately.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do { try handle.write(contentsOf: JSONEncoder().encode(pair)); try handle.synchronize(); try handle.close() }
        catch { try? FileManager.default.removeItem(at: temporary); throw error }
        guard rename(temporary.path, destination.path) == 0 else { try? FileManager.default.removeItem(at: temporary); throw ScrivError.unavailable("The pairing file could not be installed.") }
    }
    private func handle(_ data: Data?) -> Data? {
        guard let data, let pairing, data.count <= RuntimeBridgeEnvelope.maximumFrameBytes else { return nil }
        do {
            let envelope = try JSONDecoder().decode(RuntimeBridgeEnvelope.self, from: data)
            try replay.accept(envelope, secret: pairing.secret)
            let reply: RuntimeBridgeReply
            do { reply = try execute(JSONDecoder().decode(RuntimeBridgeCommand.self, from: envelope.payload)) }
            catch { reply = RuntimeBridgeReply(running: process?.isRunning == true, error: error.localizedDescription) }
            return try JSONEncoder().encode(RuntimeBridgeEnvelope(payload: JSONEncoder().encode(reply), secret: pairing.secret, nonce: envelope.nonce, response: true))
        } catch { return nil } // Unauthenticated probes receive no state or details.
    }
    private func execute(_ command: RuntimeBridgeCommand) throws -> RuntimeBridgeReply {
        if command.operation == .status { return RuntimeBridgeReply(running: process?.isRunning == true, instanceID: instanceID) }
        try RuntimeBridgePolicy.requireInstance(command, current: instanceID)
        if command.operation == .rotatePairing {
            guard process == nil, let current = pairing else { throw ScrivError.conflict("Stop the owned Codex process before rotating local pairing.") }
            let next = RuntimeBridgePairing(ownerUID: geteuid(), port: current.port, secret: try randomSecret(), installationID: current.installationID)
            try writePairing(next); pairing = next; replay = RuntimeBridgeReplayWindow()
            return RuntimeBridgeReply(running: false, instanceID: instanceID)
        }
        if command.operation == .start {
            guard process == nil else { throw ScrivError.conflict("This companion already owns a runtime. Stop it from its owning Scriv window first.") }
            guard let path = command.executable, path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path), let rootPath = command.generationRoot else { throw ScrivError.invalid("Choose the installed Codex executable and a local generation directory.") }
            let chosen = URL(fileURLWithPath: path)
            let executable = chosen.resolvingSymlinksInPath()
            let codexNames: Set<String> = ["codex", "codex.js", "codex-aarch64-apple-darwin", "codex-arm64-apple-darwin", "codex-x86_64-apple-darwin"]
            guard codexNames.contains(chosen.lastPathComponent), codexNames.contains(executable.lastPathComponent) else { throw ScrivError.permission("Choose the installed Codex entry point (codex or codex.js), not a shell or another executable.") }
            let executableAttributes = try FileManager.default.attributesOfItem(atPath: executable.path)
            let mode = (executableAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            let uid = (executableAttributes[.ownerAccountID] as? NSNumber)?.uint32Value
            guard executableAttributes[.type] as? FileAttributeType == .typeRegular, uid == 0 || uid == geteuid(), mode & 0o022 == 0 else { throw ScrivError.permission("Choose a Codex executable owned by you or the system, not writable by other users.") }
            let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
            let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
            guard root.path.hasPrefix(home.path + "/"), root.lastPathComponent == "Generation", root.deletingLastPathComponent().lastPathComponent == "Scriv", root.resolvingSymlinksInPath() == root,
                  (try root.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true,
                  (try FileManager.default.attributesOfItem(atPath: root.path)[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid() else { throw ScrivError.permission("Generation must stay in this user's private Scriv generation directory, without symbolic links.") }
            stopOwned() // Close handles from an exited prior child before reusing this companion.
            let child = Process(), stdin = Pipe(), stdout = Pipe(), errors = Pipe()
            child.executableURL = executable; child.arguments = ["app-server"]; child.currentDirectoryURL = root
            var environment = ProcessInfo.processInfo.environment; environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? ""); child.environment = environment
            child.standardInput = stdin; child.standardOutput = stdout; child.standardError = errors
            ownerSession = command.sessionID; generationRoot = root; failure = nil; events = []; eventBytes = 0; nextSequence = 1; outputBuffer = Data(); leaseAt = Date()
            input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading; stderr = errors.fileHandleForReading; process = child
            let session = command.sessionID
            output?.readabilityHandler = { [weak self] handle in let data = handle.availableData; self?.queue.async { guard self?.ownerSession == session else { return }; self?.receive(data) } }
            stderr?.readabilityHandler = { handle in _ = handle.availableData }
            child.terminationHandler = { [weak self] _ in self?.queue.async { guard self?.ownerSession == session else { return }; self?.process = nil } }
            do { try child.run() } catch { stopOwned(); throw error }
            return RuntimeBridgeReply(running: true)
        }
        guard ownerSession == command.sessionID else { throw ScrivError.permission("Only the Scriv connection that started this runtime may control it.") }
        leaseAt = Date()
        switch command.operation {
        case .send:
            guard process?.isRunning == true, let message = command.message, message.count <= 32 * 1024 * 1024 else { throw ScrivError.unavailable("The owned Codex process is not running.") }
            try validateCodexMessage(message); try input?.write(contentsOf: message + Data([10])); return RuntimeBridgeReply(running: true)
        case .poll:
            let cursor = command.after ?? 0
            guard cursor >= 0, cursor < nextSequence else { throw ScrivError.invalid("Invalid runtime event cursor.") }
            if let first = events.first, cursor < first.sequence - 1 { throw ScrivError.unavailable("The runtime event buffer was exceeded. Disconnect and inspect the original turn; nothing was resubmitted.") }
            let result = events.filter { $0.sequence > cursor }
            // Acknowledged records are discarded only after a client advances.
            while let first = events.first, first.sequence <= cursor { eventBytes -= first.message.count; events.removeFirst() }
            return RuntimeBridgeReply(running: process?.isRunning == true, events: result, error: failure)
        case .stop: stopOwned(); return RuntimeBridgeReply(running: false)
        default: throw ScrivError.invalid("Unsupported local runtime operation.")
        }
    }
    private func validateCodexMessage(_ data: Data) throws {
        guard let generationRoot else { throw ScrivError.permission("The original generation workspace is unavailable.") }
        try RuntimeBridgePolicy.validateCodexMessage(data, generationRoot: generationRoot)
    }
    private func receive(_ bytes: Data) {
        guard !bytes.isEmpty else { return }; outputBuffer.append(bytes)
        guard outputBuffer.count <= 32 * 1024 * 1024 else { failure = "Codex sent an oversized message."; stopOwned(); return }
        while let newline = outputBuffer.firstIndex(of: 10) {
            let line = Data(outputBuffer.prefix(upTo: newline)); outputBuffer.removeSubrange(...newline)
            if !line.isEmpty {
                events.append(RuntimeBridgeEvent(sequence: nextSequence, message: line)); nextSequence += 1; eventBytes += line.count
                // Bounded backpressure is fail-closed, never silent data loss.
                if eventBytes > 20 * 1024 * 1024 { failure = "The runtime event queue filled. Inspect the original turn before retrying."; stopOwned(); return }
            }
        }
    }
    private func stopOwned() {
        let child = process; process = nil; child?.terminationHandler = nil
        if let child, child.isRunning {
            child.terminate()
            queue.asyncAfter(deadline: .now() + 3) {
                // Process retains the original child identity; never signal an
                // external runtime or a guessed PID after it has exited.
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }
        output?.readabilityHandler = nil; stderr?.readabilityHandler = nil
        try? input?.close(); try? output?.close(); try? stderr?.close(); input = nil; output = nil; stderr = nil
    }
    private func shutdown() {
        let owned = process
        stopOwned(); listener?.cancel(); leaseTimer?.cancel()
        // The headless process may exit immediately after this returns, so do
        // not rely solely on an asynchronous termination escalation here.
        if let owned {
            let limit = Date().addingTimeInterval(2)
            while owned.isRunning && Date() < limit { usleep(10_000) }
            if owned.isRunning { kill(owned.processIdentifier, SIGKILL) }
        }
        if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD); lockFD = -1 }
    }
}

private final class CompanionConnection {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let handler: (Data?, @escaping (Data?) -> Void) -> Void
    private var buffer = Data(), expected: Int?
    private var deadline: DispatchWorkItem?
    private var finished = false
    private var keepAlive: CompanionConnection?
    init(connection: NWConnection, queue: DispatchQueue, handler: @escaping (Data?, @escaping (Data?) -> Void) -> Void) { self.connection = connection; self.queue = queue; self.handler = handler }
    func start() {
        keepAlive = self
        let timer = DispatchWorkItem { [weak self] in self?.finish(nil) }; deadline = timer; queue.asyncAfter(deadline: .now() + 12, execute: timer)
        connection.stateUpdateHandler = { [weak self] state in if case .failed = state { self?.finish(nil) } }
        connection.start(queue: queue); receive()
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self, !self.finished else { return }; if let data { self.buffer.append(data) }
            if self.expected == nil, self.buffer.count >= 4 {
                let length = self.buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }; self.buffer.removeFirst(4)
                guard length > 0, length <= RuntimeBridgeEnvelope.maximumFrameBytes else { self.finish(nil); return }; self.expected = Int(length)
            }
            if let expected = self.expected, self.buffer.count >= expected { self.finish(self.buffer.count == expected ? self.buffer : nil); return }
            if error != nil || complete || self.buffer.count > RuntimeBridgeEnvelope.maximumFrameBytes { self.finish(nil) } else { self.receive() }
        }
    }
    private func finish(_ data: Data?) {
        guard !finished else { return }; finished = true; deadline?.cancel(); deadline = nil
        handler(data) { [self] response in
            guard let response, response.count <= RuntimeBridgeEnvelope.maximumFrameBytes else { close(); return }
            var count = UInt32(response.count).bigEndian
            let header = withUnsafeBytes(of: &count) { Data($0) }
            connection.send(content: header + response, completion: .contentProcessed { [self] _ in close() })
        }
    }
    private func close() { connection.stateUpdateHandler = nil; connection.cancel(); keepAlive = nil }
}

/// URL activation is consumed but cannot execute commands or carry secrets.
/// Starting the ordinary app already initializes its loopback listener.
private final class CompanionLaunchEvents: NSObject {
    @objc func receive(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let raw = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: raw), url.scheme == "scriv-runtime-companion", url.host == "open", url.query == nil, url.fragment == nil, url.user == nil, url.password == nil else { return }
    }
}

let companion = RuntimeCompanion()
do { try companion.start(); RunLoop.main.run() }
catch { fputs("Scriv Runtime Companion could not start. Check its installation and private pairing directory.\n", stderr); exit(EXIT_FAILURE) }
