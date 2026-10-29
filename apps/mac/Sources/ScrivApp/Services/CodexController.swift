import AppKit
import Foundation
import ScrivCore

/// A local JSON-RPC client. ChatGPT credentials remain in the user's Codex runtime.
@MainActor
final class CodexController: ObservableObject {
    @Published private(set) var status = "Stopped"
    @Published private(set) var isConnected = false
    @Published private(set) var isRunning = false
    @Published private(set) var isGenerating = false
    @Published private(set) var accountLabel: String?
    @Published private(set) var lastError: String?
    @Published private(set) var log = ""
    @Published var executablePath: String { didSet { UserDefaults.standard.set(executablePath, forKey: "codexExecutable") } }
    @Published var endpoint: String { didSet { UserDefaults.standard.set(endpoint, forKey: "codexEndpoint") } }
    @Published var selectedModel = ""
    @Published private(set) var availableModels: [String] = []
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errors: FileHandle?
    private var buffer = Data()
    private var socket: URLSessionWebSocketTask?
    private var socketReceiver: Task<Void,Never>?
    private var pending: [Int: CheckedContinuation<JSONValue,Error>] = [:]
    private var deadlines: [Int: Task<Void,Never>] = [:]
    private var nextID = 1
    private var activeThread: String?
    private var activeTurn: String?
    private var completedTurns: [String:JSONValue] = [:]
    private var generationTask: Task<Void,Never>?
    var onChange: (() -> Void)?
    init() {
        executablePath = UserDefaults.standard.string(forKey: "codexExecutable") ?? Self.locateExecutable() ?? "/opt/homebrew/bin/codex"
        endpoint = UserDefaults.standard.string(forKey: "codexEndpoint") ?? "ws://127.0.0.1:4500"
    }
    private static func locateExecutable() -> String? {
        let candidates = ["/opt/homebrew/bin/codex","/usr/local/bin/codex",FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".npm-global/bin/codex").path]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    func start() async throws {
        guard !isConnected && process == nil else { return }
        guard executablePath.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executablePath) else { throw ScrivError.unavailable("Install Codex on this Mac, then select its executable in Settings.") }
        status = "Starting…"; lastError = nil; onChange?()
        let child = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        child.executableURL = URL(fileURLWithPath: executablePath); child.arguments = ["app-server"]
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = stderr
        let directory = try generationRoot(); child.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        child.environment = environment
        output = stdout.fileHandleForReading; errors = stderr.fileHandleForReading; input = stdin.fileHandleForWriting
        output?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in if data.isEmpty { self?.transportClosed("Codex stopped.") } else { self?.receiveBytes(data) } }
        }
        // Drain stderr to avoid a full pipe. Runtime logs are not copied into cloud or project metadata.
        errors?.readabilityHandler = { handle in _ = handle.availableData }
        child.terminationHandler = { [weak self] _ in Task { @MainActor in self?.transportClosed("Codex stopped.") } }
        do { try child.run(); process = child; isRunning = true; try await initialize() }
        catch { stop(); lastError = error.localizedDescription; throw error }
    }
    func connect() async throws {
        guard !isConnected && process == nil else { throw ScrivError.invalid("Disconnect the current runtime first.") }
        guard let url = URL(string: endpoint), ["ws","wss"].contains(url.scheme ?? ""), ["localhost","127.0.0.1","::1"].contains(url.host ?? "") else { throw ScrivError.permission("The Codex connection must stay on this Mac's loopback interface.") }
        status = "Connecting…"; lastError = nil; onChange?()
        let ws = URLSession.shared.webSocketTask(with: url); socket = ws; ws.resume()
        socketReceiver = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await ws.receive()
                    switch message { case .data(let data): self?.receiveMessage(data); case .string(let value): self?.receiveMessage(Data(value.utf8)); @unknown default: break }
                }
            } catch { self?.transportClosed("Codex connection closed.") }
        }
        do { try await initialize() } catch { disconnect(); lastError = error.localizedDescription; throw error }
    }
    private func initialize() async throws {
        _ = try await rpc("initialize", .object(["clientInfo":.object(["name":.string("scriv_mac"),"title":.string("Scriv"),"version":.string("1.0.0")])]))
        try await send(.object(["method":.string("initialized"),"params":.object([:])]))
        isConnected = true; status = "Connected"; onChange?()
        try await readAccount()
        let result = try await rpc("model/list", .object(["limit":.number(100),"includeHidden":.bool(false)]))
        let models = result["data"]?.array ?? []
        availableModels = models.compactMap { $0["model"]?.string ?? $0["id"]?.string }
        if selectedModel.isEmpty { selectedModel = models.first(where: { $0["isDefault"] == .bool(true) })?["model"]?.string ?? availableModels.first ?? "" }
        onChange?()
    }
    func signIn() async throws {
        guard isConnected else { throw ScrivError.unavailable("Start or connect Codex first.") }
        let result = try await rpc("account/login/start", .object(["type":.string("chatgpt")]))
        guard let address = result["authUrl"]?.string, let url = URL(string: address), url.scheme == "https" else { throw ScrivError.invalid("Codex did not return a valid sign-in URL.") }
        NSWorkspace.shared.open(url); status = "Waiting for ChatGPT sign-in…"; onChange?()
    }
    func signOut() async throws { _ = try await rpc("account/logout", .object([:])); try await readAccount() }
    func readAccount() async throws {
        let result = try await rpc("account/read", .object(["refreshToken":.bool(false)]))
        if let account = result["account"], account != .null { accountLabel = account["email"]?.string ?? account["type"]?.string ?? "Signed in" }
        else { accountLabel = nil }
        onChange?()
    }
    func stop() {
        // Only terminate the child owned by this client, never an externally connected server.
        let owned = process; process = nil
        if let owned, owned.isRunning { owned.terminate() }
        disconnect()
    }
    func disconnect() {
        if process != nil { stop(); return }
        socketReceiver?.cancel(); socketReceiver = nil; socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        output?.readabilityHandler = nil; errors?.readabilityHandler = nil
        try? input?.close(); try? output?.close(); try? errors?.close(); input = nil; output = nil; errors = nil
        buffer.removeAll(); isConnected = false; isRunning = false; accountLabel = nil; status = "Stopped"
        failPending(ScrivError.unavailable("Codex disconnected.")); onChange?()
    }
    private func transportClosed(_ message: String) { process = nil; isConnected = false; isRunning = false; status = "Disconnected"; failPending(ScrivError.unavailable(message)); onChange?() }
    private func failPending(_ error: Error) { let callbacks = pending; pending = [:]; for deadline in deadlines.values { deadline.cancel() }; deadlines = [:]; for callback in callbacks.values { callback.resume(throwing: error) } }
    private func generationRoot() throws -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Scriv/Generation")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); return directory
    }
    func generate(prompt: String, references: [URL] = []) async throws -> URL {
        guard isConnected else { throw ScrivError.unavailable("Start Codex and sign into ChatGPT to generate an image.") }
        guard !isGenerating else { throw ScrivError.conflict("An image is already being generated on this Mac.") }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ScrivError.invalid("Write an image direction first.") }
        isGenerating = true; log = ""; status = "Generating image…"; lastError = nil; onChange?()
        defer { isGenerating = false; activeThread = nil; activeTurn = nil; status = isConnected ? "Connected" : "Stopped"; onChange?() }
        let directory = try generationRoot().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var input: [JSONValue] = []
        for (index, reference) in references.prefix(5).enumerated() {
            let target = directory.appendingPathComponent("reference-\(index).\(reference.pathExtension)")
            try FileManager.default.copyItem(at: reference, to: target)
            input.append(.object(["type":.string("localImage"),"path":.string(target.path)]))
        }
        let instruction = "Generate one cinematic storyboard image using the available image generation tool. Follow the user's direction below. Save the final generated PNG or JPEG in the current working directory as storyboard.png (or storyboard.jpg). Do not change reference files. If image generation is unavailable, explain the actual error and do not create a placeholder. The file is the requested deliverable. User direction:\n\n" + prompt
        input.insert(.object(["type":.string("text"),"text":.string(instruction)]),at:0)
        var threadParams: [String:JSONValue] = ["cwd":.string(directory.path),"approvalPolicy":.string("never"),"sandbox":.string("workspaceWrite")]
        if !selectedModel.isEmpty { threadParams["model"] = .string(selectedModel) }
        let thread = try await rpc("thread/start",.object(threadParams))
        guard let threadId = thread["thread"]?["id"]?.string else { throw ScrivError.invalid("Codex did not create a generation thread.") }; activeThread = threadId
        let turn = try await rpc("turn/start",.object(["threadId":.string(threadId),"input":.array(input)]))
        guard let turnId = turn["turn"]?["id"]?.string else { throw ScrivError.invalid("Codex did not start the image turn.") }; activeTurn = turnId
        let started = Date()
        while completedTurns[turnId] == nil {
            try Task.checkCancellation()
            guard isConnected else { throw ScrivError.unavailable("Codex disconnected during generation. Reconnect to inspect its thread.") }
            guard Date().timeIntervalSince(started) < 900 else { await cancelGeneration(); throw ScrivError.unavailable("Image generation timed out after 15 minutes. The Codex thread is retained locally.") }
            try await Task.sleep(for: .milliseconds(150))
        }
        let final = completedTurns.removeValue(forKey: turnId)!
        guard final["status"]?.string == "completed" else { let message = final["error"]?["message"]?.string ?? "Image generation was interrupted."; lastError = message; throw ScrivError.unavailable(message) }
        let candidates = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey,.isSymbolicLinkKey]).filter { ["png","jpg","jpeg","webp"].contains($0.pathExtension.lowercased()) && !$0.lastPathComponent.hasPrefix("reference-") }
        let exact = candidates.first { $0.deletingPathExtension().lastPathComponent == "storyboard" } ?? candidates.first
        guard let file = exact, try file.resourceValues(forKeys: [.isRegularFileKey,.isSymbolicLinkKey]).isRegularFile == true, file.resolvingSymlinksInPath().deletingLastPathComponent() == directory.resolvingSymlinksInPath() else { throw ScrivError.unavailable("Codex completed without a generated image file. The installed runtime or account may not offer image generation. Its response is available in the Codex panel.") }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue <= 25*1024*1024 else { throw ScrivError.invalid("The generated image exceeds the 25 MiB limit.") }
        return file
    }
    func cancelGeneration() async { guard let activeThread, let activeTurn else { return }; _ = try? await rpc("turn/interrupt",.object(["threadId":.string(activeThread),"turnId":.string(activeTurn)])) }
    private func rpc(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        let id = nextID; nextID += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            deadlines[id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(40)); guard !Task.isCancelled, let self, let continuation = self.pending.removeValue(forKey:id) else { return }
                self.deadlines.removeValue(forKey:id); continuation.resume(throwing: ScrivError.unavailable("Codex request timed out: \(method)."))
            }
            Task { do { try await send(.object(["id":.number(Double(id)),"method":.string(method),"params":params])) } catch { deadlines.removeValue(forKey:id)?.cancel(); pending.removeValue(forKey:id)?.resume(throwing:error) } }
        }
    }
    private func send(_ value: JSONValue) async throws {
        let data = try ScrivJSON.encoder.encode(value)
        if let socket { try await socket.send(.data(data)) }
        else if let input { try input.write(contentsOf:data+Data([10])) }
        else { throw ScrivError.unavailable("Codex is not connected.") }
    }
    private func receiveBytes(_ data: Data) {
        buffer.append(data)
        guard buffer.count <= 32*1024*1024 else { transportClosed("Codex sent an oversized message."); return }
        while let newline = buffer.firstIndex(of:10) { let line = buffer.prefix(upTo:newline); buffer.removeSubrange(...newline); if !line.isEmpty { receiveMessage(Data(line)) } }
    }
    private func receiveMessage(_ data: Data) {
        guard let message = try? ScrivJSON.decoder.decode(JSONValue.self,from:data) else { return }
        if let id = message["id"]?.int, let method = message["method"]?.string {
            // Respect sandbox/approval restrictions. This integration does not grant new tool permissions automatically.
            Task {
                let response: JSONValue
                if method.hasSuffix("requestApproval") { response = .object(["id":.number(Double(id)),"result":.object(["decision":.string("decline")])]); lastError = "Codex requested additional permissions. Review this generation in Codex before retrying." }
                else { response = .object(["id":.number(Double(id)),"error":.object(["code":.number(-32601),"message":.string("This client does not implement \(method).")])]) }
                try? await send(response); onChange?()
            }
            return
        }
        if let id = message["id"]?.int, let continuation = pending.removeValue(forKey:id) {
            deadlines.removeValue(forKey:id)?.cancel()
            if let error = message["error"] { continuation.resume(throwing:ScrivError.unavailable(error["message"]?.string ?? "Codex returned an error.")) }
            else { continuation.resume(returning:message["result"] ?? .null) }
            return
        }
        let params = message["params"] ?? .null
        switch message["method"]?.string {
        case "turn/completed": if let turn = params["turn"], let id = turn["id"]?.string { completedTurns[id] = turn }
        case "item/agentMessage/delta": if let delta = params["delta"]?.string { log += delta; if log.count > 32_000 { log = String(log.suffix(32_000)) } }
        case "account/login/completed", "account/updated": Task { try? await readAccount(); if isConnected { status = "Connected" }; onChange?() }
        case "error": lastError = params["error"]?["message"]?.string
        case "warning", "configWarning": lastError = params["message"]?.string ?? params["summary"]?.string
        default: break
        }
        onChange?()
    }
}
