import Foundation
import Combine
#if targetEnvironment(macCatalyst)
import UIKit
#else
import AppKit
#endif
import ScrivCore

/// A local JSON-RPC client. ChatGPT credentials remain in the user's Codex runtime.
@MainActor
final class CodexController: ObservableObject {
    @Published private(set) var status = "Stopped"
    @Published private(set) var isConnected = false
    @Published private(set) var isRunning = false
    @Published private(set) var isGenerating = false
    @Published private(set) var accountLabel: String?
    @Published private(set) var accountChecked = false
    @Published private(set) var lastError: String?
    @Published private(set) var log = ""
    @Published var executablePath: String { didSet { UserDefaults.standard.set(executablePath, forKey: "codexExecutable") } }
    @Published var endpoint: String { didSet { UserDefaults.standard.set(endpoint, forKey: "codexEndpoint") } }
    @Published var selectedModel = ""
    @Published private(set) var availableModels: [String] = []
    @Published private(set) var jobs: [LocalGenerationJob] = []
    @Published private(set) var journalError: String?
    @Published private(set) var inspectingJobID: String?
    @Published var sharedJobs: [CloudGenerationJob] = []
    @Published var sharedJobsError: String?
    var onRefreshSharedJobs: (() -> Void)?
    private var journal: GenerationJournal?
    private var installationID = ""
    private var sleepObserver: NSObjectProtocol?
    var onJobChange: ((LocalGenerationJob) -> Void)?
    var onRecoverJob: ((LocalGenerationJob) -> Void)?
    var onRetryJob: ((LocalGenerationJob) -> Void)?
    #if targetEnvironment(macCatalyst)
    private var bridge: MacRuntimeBridge?
    private var scopedGenerationRoot: URL?
    private var generationRootIssue: String?
    private struct SavedGenerationLocation: Codable { let bookmark: Data; let installationID: String }
    /// Explicit migration only. The original journal/artifacts remain in place;
    /// their installation identity is retained rather than forging new owners.
    func useExistingGenerationFolder(_ url: URL) throws {
        guard !isConnected, !isConnecting, !isGenerating else { throw ScrivError.conflict("Disconnect Codex before choosing existing generation history.") }
        let scoped = url.startAccessingSecurityScopedResource()
        do {
            let root = url.standardizedFileURL
            var isDirectory: ObjCBool = false
            guard root.lastPathComponent == "Generation", root.deletingLastPathComponent().lastPathComponent == "Scriv", root == root.resolvingSymlinksInPath(), FileManager.default.fileExists(atPath: root.appendingPathComponent("Journal").path, isDirectory: &isDirectory), isDirectory.boolValue else { throw ScrivError.invalid("Choose the original Scriv/Generation folder containing its Journal. No files were moved or replaced.") }
            let candidate = try GenerationJournal(root: root.appendingPathComponent("Journal")), loaded = try candidate.load()
            let owners = Set(loaded.jobs.map(\.ownerInstallationID))
            guard owners.count <= 1 else { throw ScrivError.permission("This folder contains jobs from different installations. Keep it unchanged and recover each installation separately.") }
            let owner = owners.first ?? installationID
            guard UUID(uuidString: owner) != nil else { throw ScrivError.invalid("The original generation owner identity is invalid.") }
            let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            let saved = try JSONEncoder().encode(SavedGenerationLocation(bookmark: bookmark, installationID: owner))
            scopedGenerationRoot?.stopAccessingSecurityScopedResource(); scopedGenerationRoot = url
            generationRootIssue = nil; installationID = owner; journal = candidate; jobs = loaded.jobs
            UserDefaults.standard.set(saved, forKey: "ScrivUIKitGenerationLocation.v1")
            UserDefaults.standard.set(owner, forKey: "generationInstallationID")
            journalError = loaded.unreadable > 0 ? "\(loaded.unreadable) unreadable generation records were preserved on disk, not discarded." : nil
            for var job in loaded.jobs where job.status == .running || job.status == .queued {
                job.recoverAfterRestart()
                do { try persist(job) } catch { journalError = "Existing records were retained, but recovery progress could not be saved: " + error.localizedDescription }
            }
            onChange?()
        } catch { if scoped { url.stopAccessingSecurityScopedResource() }; throw error }
    }
    @Published private(set) var bridgePaired = MacRuntimeBridge.isPaired
    func importRuntimePairing(from url: URL) throws {
        guard !isConnected, !isConnecting else { throw ScrivError.conflict("Disconnect before changing local pairing.") }
        try MacRuntimeBridge.importPairing(from: url); bridgePaired = true; onChange?()
    }
    func rotateRuntimePairing() async throws {
        guard !isConnected, !isConnecting else { throw ScrivError.conflict("Disconnect before rotating local pairing.") }
        try await MacRuntimeBridge().rotatePairing(); bridgePaired = false; onChange?()
    }
    func forgetRuntimePairing() {
        guard !isConnected, !isConnecting else { return }
        MacRuntimeBridge.forgetPairing(); bridgePaired = false; onChange?()
    }
    func openRuntimeCompanion() async throws { try await MacRuntimeBridge.openCompanion() }
    private var ownsTransport: Bool { bridge != nil }
    #else
    private var process: Process?
    private var ownsTransport: Bool { process != nil }
    #endif
    private var input: FileHandle?
    private var output: FileHandle?
    private var errors: FileHandle?
    private var buffer = Data()
    private var socket: URLSessionWebSocketTask?
    private var socketReceiver: Task<Void,Never>?
    private var pending: [Int: CheckedContinuation<JSONValue,Error>] = [:]
    private var deadlines: [Int: Task<Void,Never>] = [:]
    private var nextID = 1
    private var generationState = CodexGenerationState()
    private var generationJobID: String?
    var activeGenerationJob: LocalGenerationJob? { generationJobID.flatMap { id in jobs.first(where: { $0.id == id }) } }
    var isCancellingGeneration: Bool { isGenerating && generationState.cancellationRequested }
    @Published private(set) var pendingLoginID: String?
    private var loginStarting = false
    private var earlyLoginCompletions: [String: JSONValue] = [:]
    private var connectionGeneration = 0
    @Published private(set) var isConnecting = false
    private var activeDirectory: URL?
    private var generatedArtifacts: [URL] = []
    private var imageGenerationError: String?
    var onChange: (() -> Void)?
    init() {
        executablePath = UserDefaults.standard.string(forKey: "codexExecutable") ?? Self.locateExecutable() ?? "/opt/homebrew/bin/codex"
        endpoint = UserDefaults.standard.string(forKey: "codexEndpoint") ?? "ws://127.0.0.1:4500"
        let verification = ProcessInfo.processInfo.arguments.contains("--screenshots") || ProcessInfo.processInfo.arguments.contains("--peer-smoke")
        installationID = verification ? UUID().uuidString : UserDefaults.standard.string(forKey: "generationInstallationID") ?? UUID().uuidString
        if UUID(uuidString: installationID) == nil { installationID = UUID().uuidString }
        if !verification { UserDefaults.standard.set(installationID, forKey: "generationInstallationID") }
        #if targetEnvironment(macCatalyst)
        if !verification, let data = UserDefaults.standard.data(forKey: "ScrivUIKitGenerationLocation.v1") {
            do {
                let saved = try JSONDecoder().decode(SavedGenerationLocation.self, from: data)
                guard UUID(uuidString: saved.installationID) != nil else { throw ScrivError.invalid("The saved generation identity is invalid.") }
                var stale = false
                let url = try URL(resolvingBookmarkData: saved.bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
                _ = url.startAccessingSecurityScopedResource(); scopedGenerationRoot = url; installationID = saved.installationID
                if stale { let updated = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil); UserDefaults.standard.set(try JSONEncoder().encode(SavedGenerationLocation(bookmark: updated, installationID: installationID)), forKey: "ScrivUIKitGenerationLocation.v1") }
            } catch { generationRootIssue = "Existing generation history needs access again. Choose its original folder in Settings. " + error.localizedDescription }
        }
        #endif
        do {
            journal = try GenerationJournal(root: generationRoot().appendingPathComponent("Journal"))
            let loaded = try journal!.load()
            jobs = loaded.jobs
            for var job in loaded.jobs where job.ownerInstallationID == installationID && (job.status == .running || job.status == .queued) {
                job.recoverAfterRestart(); try persist(job)
            }
            if loaded.unreadable > 0 { journalError = "\(loaded.unreadable) unreadable generation records were preserved on disk, not discarded." }
        } catch { journalError = "Generation recovery storage could not open: \(error.localizedDescription)" }
        #if !targetEnvironment(macCatalyst)
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.recordProgress(.waiting, "Waiting for this Mac to wake; no generation will be resubmitted.") }
        }
        #endif
    }
    private static func isReadableImage(_ url: URL) -> Bool {
        #if targetEnvironment(macCatalyst)
        return UIImage(contentsOfFile: url.path) != nil
        #else
        return NSImage(contentsOf: url) != nil
        #endif
    }
    private static func locateExecutable() -> String? {
        let candidates = ["/opt/homebrew/bin/codex","/usr/local/bin/codex",FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".npm-global/bin/codex").path]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    func start() async throws {
        guard !isConnecting, !isConnected, !ownsTransport, socket == nil else { throw ScrivError.conflict("Disconnect the current runtime first.") }
        #if targetEnvironment(macCatalyst)
        guard executablePath.hasPrefix("/") else { throw ScrivError.unavailable("Choose the absolute path of Codex installed on this Mac.") }
        disconnect(); isConnecting = true; defer { isConnecting = false }
        let sessionGeneration = connectionGeneration
        status = "Starting local companion connection…"; lastError = nil; onChange?()
        let local: MacRuntimeBridge
        do { local = try MacRuntimeBridge() } catch { status = "Stopped"; lastError = error.localizedDescription; onChange?(); throw error }
        bridge = local
        local.onMessage = { [weak self] data in guard let self, self.connectionGeneration == sessionGeneration else { return }; self.receiveMessage(data) }
        local.onClose = { [weak self] message in self?.transportClosed(message, generation: sessionGeneration) }
        do {
            try await local.start(executable: executablePath, generationRoot: generationRoot())
            guard connectionGeneration == sessionGeneration else { local.stop(); throw CancellationError() }
            isRunning = true; try await initialize(generation: sessionGeneration)
        } catch { if connectionGeneration == sessionGeneration { stop(); lastError = error.localizedDescription }; throw error }
        #else
        guard executablePath.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executablePath) else { throw ScrivError.unavailable("Install Codex on this Mac, then select its executable in Settings.") }
        disconnect(); isConnecting = true; defer { isConnecting = false }
        let sessionGeneration = connectionGeneration
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
            Task { @MainActor in guard let self, self.connectionGeneration == sessionGeneration else { return }; if data.isEmpty { self.transportClosed("Codex stopped.",generation:sessionGeneration) } else { self.receiveBytes(data) } }
        }
        // Drain stderr to avoid a full pipe. Runtime logs are not copied into cloud or project metadata.
        errors?.readabilityHandler = { handle in _ = handle.availableData }
        child.terminationHandler = { [weak self] _ in Task { @MainActor in self?.transportClosed("Codex stopped.",generation:sessionGeneration) } }
        process = child
        do { try child.run(); isRunning = true; try await initialize(generation:sessionGeneration) }
        catch { if connectionGeneration == sessionGeneration { stop(); lastError = error.localizedDescription }; throw error }
        #endif
    }

    func connect() async throws {
        guard !isConnecting, !isConnected, !ownsTransport, socket == nil else { throw ScrivError.invalid("Disconnect the current runtime first.") }
        guard let url = URL(string: endpoint), ["ws","wss"].contains(url.scheme ?? ""), ["localhost","127.0.0.1","::1","[::1]"].contains(url.host ?? ""), url.user == nil, url.password == nil, url.fragment == nil else { throw ScrivError.permission("The Codex connection must stay on this Mac's loopback interface.") }
        disconnect(); isConnecting = true; defer { isConnecting = false }
        let sessionGeneration = connectionGeneration
        status = "Connecting…"; lastError = nil; onChange?()
        let ws = URLSession.shared.webSocketTask(with: url); ws.maximumMessageSize = 32*1024*1024; socket = ws; ws.resume()
        socketReceiver = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await ws.receive()
                    guard let self, self.connectionGeneration == sessionGeneration else { return }
                    switch message { case .data(let data): self.receiveMessage(data); case .string(let value): self.receiveMessage(Data(value.utf8)); @unknown default: break }
                }
            } catch { self?.transportClosed("Codex connection closed.",generation:sessionGeneration) }
        }
        do { try await initialize(generation:sessionGeneration) } catch { if connectionGeneration == sessionGeneration { disconnect(); lastError = error.localizedDescription }; throw error }
    }
    private func initialize(generation: Int) async throws {
        _ = try await rpc("initialize", .object(["clientInfo":.object(["name":.string("scriv_mac"),"title":.string("Scriv"),"version":.string("1.0.0")])]))
        try await send(.object(["method":.string("initialized")]))
        guard generation == connectionGeneration else { throw CancellationError() }
        isConnected = true; status = "Connected"; onChange?()
        try await readAccount()
        try await readModels()
    }
    private func readModels() async throws {
        let generation = connectionGeneration
        var models: [JSONValue] = [], cursor: String?, seenCursors: Set<String> = []
        repeat {
            var parameters: [String:JSONValue] = ["limit":.number(100),"includeHidden":.bool(false)]
            if let cursor { parameters["cursor"] = .string(cursor) }
            let result = try await rpc("model/list",.object(parameters))
            guard generation == connectionGeneration else { throw CancellationError() }
            models += result["data"]?.array ?? []; cursor = result["nextCursor"]?.string
            if let cursor { guard !seenCursors.contains(cursor) else { throw ScrivError.invalid("Codex model pagination did not advance.") }; seenCursors.insert(cursor) }
        } while cursor != nil
        var seenModels: Set<String> = []
        availableModels = models.compactMap { $0["model"]?.string ?? $0["id"]?.string }.filter { !$0.isEmpty && seenModels.insert($0).inserted }
        if !availableModels.contains(selectedModel) { selectedModel = models.first(where: { $0["isDefault"] == .bool(true) })?["model"]?.string ?? availableModels.first ?? "" }
        onChange?()
    }
    func signIn() async throws {
        guard isConnected else { throw ScrivError.unavailable("Start or connect Codex first.") }
        guard !loginStarting, pendingLoginID == nil else { throw ScrivError.conflict("A ChatGPT sign-in is already open. Complete it in your browser, or cancel sign-in before retrying.") }
        guard !isGenerating else { throw ScrivError.conflict("Wait for image generation to finish before changing the Codex account.") }
        let generation = connectionGeneration
        loginStarting = true
        defer { if generation == connectionGeneration { loginStarting = false } }
        do {
            let result = try await rpc("account/login/start", .object(["type":.string("chatgpt")]))
            guard generation == connectionGeneration else { throw CancellationError() }
            guard let loginID = result["loginId"]?.string, !loginID.isEmpty,
                  let address = result["authUrl"]?.string, let url = URL(string: address), url.scheme == "https" else { throw ScrivError.invalid("Codex did not return a valid sign-in URL.") }
            pendingLoginID = loginID
            if let completion = earlyLoginCompletions.removeValue(forKey: loginID) { completeLogin(completion); return }
            #if targetEnvironment(macCatalyst)
            guard await UIApplication.shared.open(url) else { throw ScrivError.unavailable("The sign-in browser could not be opened. Check your default browser and retry.") }
            #else
            guard NSWorkspace.shared.open(url) else { throw ScrivError.unavailable("The sign-in browser could not be opened. Check your default browser and retry.") }
            #endif
            status = "Waiting for ChatGPT sign-in…"; lastError = nil; onChange?()
        } catch {
            if generation == connectionGeneration { pendingLoginID = nil; earlyLoginCompletions.removeAll(); status = isConnected ? "Connected" : "Stopped" }
            throw error
        }
    }
    func cancelSignIn() async throws {
        guard let loginID = pendingLoginID else { return }
        let generation = connectionGeneration
        _ = try await rpc("account/login/cancel", .object(["loginId": .string(loginID)]))
        guard generation == connectionGeneration else { throw CancellationError() }
        if pendingLoginID == loginID { pendingLoginID = nil }
        earlyLoginCompletions.removeAll(); lastError = nil
        status = "Connected"; try await readAccount(); onChange?()
    }
    func signOut() async throws {
        guard isConnected else { throw ScrivError.unavailable("Start or connect Codex first.") }
        guard !isGenerating else { throw ScrivError.conflict("Wait for image generation to finish before changing the Codex account.") }
        let generation = connectionGeneration
        _ = try await rpc("account/logout", .null)
        guard generation == connectionGeneration else { throw CancellationError() }
        pendingLoginID = nil; earlyLoginCompletions.removeAll(); try await readAccount()
        status = "Connected"; onChange?()
    }
    private func completeLogin(_ params: JSONValue) {
        guard let loginID = params["loginId"]?.string, loginID == pendingLoginID else { return }
        pendingLoginID = nil; earlyLoginCompletions.removeAll()
        status = isConnected ? "Connected" : "Stopped"
        if params["success"] != .bool(true) {
            lastError = params["error"]?.string ?? "ChatGPT sign-in was not completed."; onChange?(); return
        }
        let generation = connectionGeneration
        Task {
            guard generation == connectionGeneration else { return }
            do {
                try await readAccount(); try await readModels()
                guard generation == connectionGeneration else { return }
                lastError = nil
            } catch { if generation == connectionGeneration { lastError = error.localizedDescription } }
            onChange?()
        }
    }
    func readAccount() async throws {
        let generation = connectionGeneration
        let result = try await rpc("account/read", .object(["refreshToken":.bool(false)]))
        guard generation == connectionGeneration else { throw CancellationError() }
        if let account = result["account"], account != .null { accountLabel = account["email"]?.string ?? account["type"]?.string ?? "Signed in" }
        else { accountLabel = nil }
        accountChecked = true; onChange?()
    }
    func stop() { disconnect() }
    func disconnect() {
        if isGenerating { recordProgress(.waiting, "Connection ended. Inspect the original turn before retrying.") }
        connectionGeneration += 1
        // Only terminate the child owned by this client, never an externally connected server.
        #if targetEnvironment(macCatalyst)
        let owned = bridge; bridge = nil; owned?.onMessage = nil; owned?.onClose = nil; owned?.stop()
        #else
        let owned = process; process = nil; owned?.terminationHandler = nil
        if let owned, owned.isRunning { owned.terminate() }
        #endif
        socketReceiver?.cancel(); socketReceiver = nil; socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        output?.readabilityHandler = nil; errors?.readabilityHandler = nil
        try? input?.close(); try? output?.close(); try? errors?.close(); input = nil; output = nil; errors = nil
        pendingLoginID = nil; loginStarting = false; earlyLoginCompletions.removeAll()
        buffer.removeAll(); isConnected = false; isRunning = false; accountLabel = nil; accountChecked = false; availableModels = []; status = "Stopped"
        failPending(ScrivError.unavailable("Codex disconnected.")); onChange?()
    }
    private func transportClosed(_ message: String, generation: Int) { guard generation == connectionGeneration else { return }; disconnect(); status = "Disconnected"; lastError = message; onChange?() }
    private func failPending(_ error: Error) { let callbacks = pending; pending = [:]; for deadline in deadlines.values { deadline.cancel() }; deadlines = [:]; for callback in callbacks.values { callback.resume(throwing: error) } }
    private func generationRoot() throws -> URL {
        #if targetEnvironment(macCatalyst)
        if let generationRootIssue { throw ScrivError.unavailable(generationRootIssue) }
        if let scopedGenerationRoot {
            guard (try scopedGenerationRoot.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else { throw ScrivError.unavailable("The original generation folder is unavailable. Choose it again in Settings; no new empty history was substituted.") }
            return scopedGenerationRoot
        }
        #endif
        let directory: URL
        if ProcessInfo.processInfo.arguments.contains("--screenshots") || ProcessInfo.processInfo.arguments.contains("--peer-smoke") {
            let root = ProcessInfo.processInfo.environment["SCRIV_VERIFICATION_ROOT"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory.appendingPathComponent("ScrivVerification-\(ProcessInfo.processInfo.processIdentifier)")
            directory = root.appendingPathComponent("Generation")
        } else { directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Scriv/Generation") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); return directory
    }
    func generate(prompt: String, submittedPrompt suppliedPrompt: String? = nil, references: [URL] = [], context: GenerationJobContext? = nil, jobID proposedID: String = UUID().uuidString, retryOf: String? = nil) async throws -> URL {
        let jobID = proposedID.lowercased()
        if let blocker = CodexConnectionReadiness(isConnected: isConnected, accountChecked: accountChecked, accountLabel: accountLabel).generationBlocker { throw ScrivError.unavailable(blocker) }
        guard !isGenerating else { throw ScrivError.conflict("An image is already being generated on this Mac.") }
        guard !loginStarting, pendingLoginID == nil else { throw ScrivError.conflict("Complete or cancel the pending ChatGPT sign-in before generating.") }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ScrivError.invalid("Write an image direction first.") }
        let submittedPrompt = suppliedPrompt ?? GenerationPrompt.submitted(brief:prompt)
        try GenerationPrompt.validateBeforeGeneration(submittedPrompt:submittedPrompt,manualDirection:context?.userDirection ?? prompt,predecessor:nil)
        let generation = connectionGeneration
        try Task.checkCancellation()
        guard references.count <= 5 else { throw ScrivError.invalid("Use at most five reference images per generation.") }
        generationState = CodexGenerationState()
        guard UUID(uuidString: jobID) != nil, !jobs.contains(where: { $0.id == jobID }) else { throw ScrivError.conflict("This generation identity already exists. Inspect it instead of submitting again.") }
        let job = LocalGenerationJob(id: jobID, ownerInstallationID: installationID, context: context, prompt: prompt, submittedPrompt: submittedPrompt, model: selectedModel, runtimeIdentity: runtimeIdentity, retryOf: retryOf)
        try persist(job) // Persist intent before any usage-producing request.
        generationJobID = jobID
        isGenerating = true; generatedArtifacts = []; imageGenerationError = nil; log = ""; status = "Generating image…"; lastError = nil; onChange?()
        defer { isGenerating = false; generationJobID = nil; generationState = CodexGenerationState(); activeDirectory = nil; status = isConnected ? "Connected" : "Stopped"; onChange?() }
        return try await withTaskCancellationHandler {
            do {
                let file = try await generateImage(submittedPrompt: submittedPrompt, references: references, generation: generation)
                try completeJob(jobID, file: file)
                return file
            }
            catch {
                if error is CancellationError { if connectionGeneration == generation { await cancelGeneration() } }
                else { lastError = error.localizedDescription }
                let uncertain = connectionGeneration != generation || generationState.turnID == nil && generationState.threadID != nil
                let cancelled = error is CancellationError && !uncertain
                recordProgress(uncertain ? .waiting : cancelled ? .cancelled : .failed,
                               uncertain ? "The original turn may still exist. Inspect it before retrying." : cancelled ? "Cancellation requested; inspect the original turn before retrying." : "Generation did not produce an accepted image.",
                               error: error.localizedDescription, errorCode: uncertain ? "runtime_unreachable" : cancelled ? "cancelled" : "generation_failed")
                throw error
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.generationJobID == jobID, self.connectionGeneration == generation else { return }
                await self.cancelGeneration()
            }
        }
    }
    private func generateImage(submittedPrompt: String, references: [URL], generation: Int) async throws -> URL {
        guard let jobID = generationJobID else { throw ScrivError.invalid("Generation identity is missing.") }
        let directory = try generationRoot().appendingPathComponent(jobID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        activeDirectory = directory
        var input: [JSONValue] = []
        for (index, reference) in references.enumerated() {
            try Task.checkCancellation()
            guard reference.isFileURL, let values = try? reference.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true,
                  let count = values.fileSize, count > 0, count <= CodexImageArtifacts.maximumBytes, Self.isReadableImage(reference) else { throw ScrivError.invalid("Each reference must be a readable image no larger than 25 MiB.") }
            let target = directory.appendingPathComponent("reference-\(index).\(reference.pathExtension)")
            try FileManager.default.copyItem(at: reference, to: target)
            try updateJob(jobID) { $0.references.append(.init(fileName: target.lastPathComponent, sha256: ScrivDigest.sha256(try Data(contentsOf: target)))) }
            input.append(.object(["type":.string("localImage"),"path":.string(target.path)]))
        }
        // The exact effective text was durably captured before entering this
        // method. Never rebuild it from today's script or instruction wrapper.
        input.insert(.object(["type":.string("text"),"text":.string(submittedPrompt)]),at:0)
        // Verified against `codex app-server generate-json-schema` from Codex 0.165.0.
        // ThreadStartParams.SandboxMode is kebab-case; TurnStartParams.sandboxPolicy uses camelCase.
        var threadParams: [String:JSONValue] = ["cwd":.string(directory.path),"approvalPolicy":.string("never"),"sandbox":.string("workspace-write")]
        if !selectedModel.isEmpty { threadParams["model"] = .string(selectedModel) }
        try Task.checkCancellation()
        guard !generationState.cancellationRequested, connectionGeneration == generation else { throw CancellationError() }
        let thread = try await rpc("thread/start",.object(threadParams))
        guard !generationState.cancellationRequested, connectionGeneration == generation else { throw CancellationError() }
        guard let threadId = thread["thread"]?["id"]?.string else { throw ScrivError.invalid("Codex did not create a generation thread.") }; generationState.startThread(threadId)
        try updateJob(jobID) { $0.threadID = threadId; $0.status = .running; $0.progressText = "Submitting image turn" }
        let turn = try await rpc("turn/start",.object(["threadId":.string(threadId),"input":.array(input)]))
        guard let turnId = turn["turn"]?["id"]?.string else { throw ScrivError.invalid("Codex did not start the image turn.") }
        let lateCancellation = generationState.startTurn(turnId)
        try updateJob(jobID) { $0.turnID = turnId; $0.progressText = "Waiting for the image tool" }
        if let lateCancellation, connectionGeneration == generation { await interrupt(lateCancellation) }
        try Task.checkCancellation()
        guard !generationState.cancellationRequested, connectionGeneration == generation else { throw CancellationError() }
        let started = Date()
        while generationState.completion == nil {
            try Task.checkCancellation()
            guard !generationState.cancellationRequested, connectionGeneration == generation else { throw CancellationError() }
            guard isConnected else { throw ScrivError.unavailable("Codex disconnected during generation. Reconnect to inspect its thread.") }
            guard Date().timeIntervalSince(started) < 900 else { await cancelGeneration(); throw ScrivError.unavailable("Image generation timed out after 15 minutes. The Codex thread is retained locally.") }
            try await Task.sleep(for: .milliseconds(150))
        }
        guard !generationState.cancellationRequested, connectionGeneration == generation else { throw CancellationError() }
        guard let final = generationState.completion else { throw ScrivError.invalid("Codex did not provide a completed turn.") }
        guard final["status"]?.string == "completed" else { let message = final["error"]?["message"]?.string ?? "Image generation was interrupted."; lastError = message; throw ScrivError.unavailable(message) }
        for item in final["items"]?.array ?? [] { recordImageArtifact(item) }
        let candidates = try CodexImageArtifacts.candidates(in: directory, reported: generatedArtifacts)
        // A malformed or incomplete preferred filename must not hide a valid tool artifact.
        guard let file = candidates.first(where: { Self.isReadableImage($0) }) else {
            throw ScrivError.unavailable(imageGenerationError ?? "Codex completed without a valid generated image (maximum 25 MiB). The installed runtime or account may not offer image generation. Its response is available in the Codex panel.")
        }
        return file
    }
    func cancelGeneration() async {
        guard isGenerating else { return }
        recordProgress(.running, "Requesting cancellation")
        status = "Cancelling image…"; onChange?()
        if let turn = generationState.requestCancellation() { await interrupt(turn) }
    }
    private func interrupt(_ turn: CodexGenerationState.Turn) async {
        let generation = connectionGeneration, jobID = generationJobID
        do { _ = try await rpc("turn/interrupt", .object(["threadId": .string(turn.threadID), "turnId": .string(turn.turnID)]), timeout: .seconds(5)) }
        catch {
            if generation == connectionGeneration, generationJobID == nil || generationJobID == jobID {
                lastError = "Codex cancellation could not be confirmed. The turn may still be running in the local runtime. " + error.localizedDescription
                onChange?()
            }
        }
    }
    private func rpc(_ method: String, _ params: JSONValue, timeout: Duration = .seconds(40)) async throws -> JSONValue {
        let id = nextID, generation = connectionGeneration; nextID += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            deadlines[id] = Task { [weak self] in
                try? await Task.sleep(for: timeout); guard !Task.isCancelled, let self, let continuation = self.pending.removeValue(forKey:id) else { return }
                self.deadlines.removeValue(forKey:id); continuation.resume(throwing: ScrivError.unavailable("Codex request timed out: \(method)."))
            }
            Task { do { guard generation == connectionGeneration else { throw CancellationError() }; try await send(.object(["id":.number(Double(id)),"method":.string(method),"params":params])) } catch { deadlines.removeValue(forKey:id)?.cancel(); pending.removeValue(forKey:id)?.resume(throwing:error) } }
        }
    }
    private func send(_ value: JSONValue) async throws {
        let data = try ScrivJSON.encoder.encode(value)
        #if targetEnvironment(macCatalyst)
        if let bridge { try await bridge.send(data); return }
        #endif
        if let socket { try await socket.send(.string(String(decoding:data,as:UTF8.self))) }
        else if let input { try input.write(contentsOf:data+Data([10])) }
        else { throw ScrivError.unavailable("Codex is not connected.") }
    }
    private func receiveBytes(_ data: Data) {
        buffer.append(data)
        guard buffer.count <= 32*1024*1024 else { transportClosed("Codex sent an oversized message.",generation:connectionGeneration); return }
        while let newline = buffer.firstIndex(of:10) { let line = buffer.prefix(upTo:newline); buffer.removeSubrange(...newline); if !line.isEmpty { receiveMessage(Data(line)) } }
    }
    private func receiveMessage(_ data: Data) {
        guard data.count <= 32*1024*1024 else { transportClosed("Codex sent an oversized message.",generation:connectionGeneration); return }
        guard let message = try? ScrivJSON.decoder.decode(JSONValue.self,from:data) else { return }
        if let id = message["id"], let method = message["method"]?.string {
            let generation = connectionGeneration
            // Respect sandbox/approval restrictions. This integration does not grant new tool permissions automatically.
            Task {
                let response: JSONValue
                guard generation == connectionGeneration else { return }
                switch method {
                case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
                    response = .object(["id":id,"result":.object(["decision":.string("decline")])])
                    lastError = "Codex requested additional permissions. Review this generation in Codex before retrying."
                case "item/permissions/requestApproval":
                    response = .object(["id":id,"result":.object(["permissions":.object([:]),"scope":.string("turn")])])
                    lastError = "Codex requested additional permissions. No extra access was granted."
                case "mcpServer/elicitation/request":
                    response = .object(["id":id,"result":.object(["action":.string("decline"),"content":.null])])
                    lastError = "A connected Codex tool requested additional input. Review it in Codex before retrying."
                case "item/tool/requestUserInput":
                    response = .object(["id":id,"result":.object(["answers":.object([:])])])
                    lastError = "Codex needs additional input. Add the details to the image direction and retry."
                default: response = .object(["id":id,"error":.object(["code":.number(-32601),"message":.string("This client does not implement \(method).")])])
                }
                try? await send(response); onChange?()
                if method == "item/tool/requestUserInput" { await cancelGeneration() }
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
        case "item/started":
            if isGenerating, params["threadId"]?.string == generationState.threadID, let item = params["item"] {
                let stage = item["type"]?.string == "imageGeneration" ? "Image generation tool is running" : "Codex is preparing the image"
                recordProgress(.running, stage)
            }
        case "turn/completed": if isGenerating, let turn = params["turn"] { generationState.recordCompletion(threadID: params["threadId"]?.string, turn: turn) }
        case "item/completed": if isGenerating, params["threadId"]?.string == generationState.threadID, let item = params["item"] { recordImageArtifact(item) }
        case "item/agentMessage/delta": if isGenerating, generationState.threadID != nil, params["threadId"]?.string == generationState.threadID, let delta = params["delta"]?.string { log += delta; if log.count > 32_000 { log = String(log.suffix(32_000)) } }
        case "account/login/completed":
            if let id = params["loginId"]?.string, loginStarting && pendingLoginID == nil {
                if earlyLoginCompletions.count < 8 { earlyLoginCompletions[id] = params }
            } else { completeLogin(params) }
        case "account/updated":
            let generation = connectionGeneration
            Task {
                guard generation == connectionGeneration else { return }
                do { try await readAccount() }
                catch { if generation == connectionGeneration { lastError = error.localizedDescription } }
                if generation == connectionGeneration, isConnected, !isGenerating, pendingLoginID == nil { status = "Connected" }
                onChange?()
            }
        case "error": lastError = params["error"]?["message"]?.string
        case "warning", "configWarning": lastError = params["message"]?.string ?? params["summary"]?.string
        default: break
        }
        onChange?()
    }
    private func recordImageArtifact(_ item: JSONValue) {
        guard item["type"]?.string == "imageGeneration", let directory = activeDirectory else { return }
        if item["failure"]?["type"]?.string == "usageLimitExceeded" { imageGenerationError = "The connected ChatGPT account reached its image generation usage limit."; lastError = imageGenerationError }
        guard let path = item["savedPath"]?.string, path.hasPrefix("/") else { return }
        let file = URL(fileURLWithPath:path)
        // Runtime-reported artifacts are accepted only inside this isolated generation folder.
        // The prompt asks Codex to copy its final image here if its tool initially saves elsewhere.
        guard file.resolvingSymlinksInPath().path.hasPrefix(directory.resolvingSymlinksInPath().path + "/"),
              !file.lastPathComponent.hasPrefix("reference-"), ["png","jpg","jpeg","webp"].contains(file.pathExtension.lowercased()) else { return }
        if !generatedArtifacts.contains(file) { generatedArtifacts.append(file) }
    }

    private var runtimeIdentity: String { ownsTransport ? "managed:" + executablePath : "external:" + endpoint }
    private func persist(_ job: LocalGenerationJob) throws {
        guard let journal else { throw ScrivError.unavailable("Generation journal is unavailable. Repair local storage before starting a new image.") }
        try journal.save(job)
        if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index] = job } else { jobs.insert(job, at: 0) }
        onJobChange?(job); onChange?()
    }
    private func updateJob(_ id: String, _ change: (inout LocalGenerationJob) throws -> Void) throws {
        let id = id.lowercased()
        guard var job = jobs.first(where: { $0.id == id }), job.ownerInstallationID == installationID else { throw ScrivError.permission("This Mac does not own that local generation.") }
        try change(&job); job.updatedAt = ScrivClock.now; try persist(job)
    }
    private func recordProgress(_ state: LocalGenerationJob.Status, _ text: String, error: String? = nil, errorCode: String? = nil) {
        guard let id = generationJobID else { return }
        do { try updateJob(id) { $0.status = state; $0.progressText = text; $0.errorDetail = error; $0.errorCode = errorCode } }
        catch { journalError = "Generation progress could not be saved: \(error.localizedDescription)"; onChange?() }
    }
    private func jobDirectory(_ id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw ScrivError.invalid("Invalid generation identity.") }
        let root = try generationRoot().resolvingSymlinksInPath(), directory = root.appendingPathComponent(id)
        guard directory.resolvingSymlinksInPath() == directory else { throw ScrivError.invalid("Generation folders must not be symbolic links.") }
        return directory
    }
    private func completeJob(_ id: String, file: URL, confirmedComplete: Bool = true) throws {
        let directory = try jobDirectory(id)
        guard CodexImageArtifacts.isEligible(file, in: directory), Self.isReadableImage(file) else { throw ScrivError.invalid("The recovered image is not a valid artifact of this generation.") }
        let relative = String(file.resolvingSymlinksInPath().path.dropFirst(directory.path.count + 1))
        let hash = ScrivDigest.sha256(try Data(contentsOf: file))
        try updateJob(id) {
            if confirmedComplete {
                $0.status = .completed; $0.progressText = "Image ready to attach to its original project"; $0.errorDetail = nil; $0.errorCode = nil
            } else { $0.progressText = "A valid local image is available as a candidate; the original turn's final state is not confirmed." }
            $0.artifactRelativePath = relative; $0.artifactSha256 = hash
        }
    }
    func markJobAttached(id: String, imageID: String) {
        do { try updateJob(id) { $0.outputImageID = imageID; $0.progressText = "Saved as an immutable project image" } }
        catch { journalError = error.localizedDescription }
    }
    func artifactURL(for jobID: String) throws -> URL {
        let jobID = jobID.lowercased()
        guard let job = jobs.first(where: { $0.id == jobID }), job.ownerInstallationID == installationID,
              let path = job.artifactRelativePath, let hash = job.artifactSha256 else { throw ScrivError.unavailable("Inspect this generation to recover its image first.") }
        let directory = try jobDirectory(jobID), file = directory.appendingPathComponent(path)
        guard CodexImageArtifacts.isEligible(file, in: directory), Self.isReadableImage(file),
              ScrivDigest.sha256(try Data(contentsOf: file)) == hash else { throw ScrivError.invalid("The saved generation image is missing or has changed.") }
        return file
    }
    func referenceURLs(for jobID: String) throws -> [URL] {
        let jobID = jobID.lowercased()
        guard let job = jobs.first(where: { $0.id == jobID }), job.ownerInstallationID == installationID else { throw ScrivError.permission("This Mac does not own that generation.") }
        let directory = try jobDirectory(jobID)
        return try job.references.map { reference in
            let file = directory.appendingPathComponent(reference.fileName)
            guard file.resolvingSymlinksInPath().deletingLastPathComponent() == directory,
                  let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= CodexImageArtifacts.maximumBytes,
                  Self.isReadableImage(file), ScrivDigest.sha256(try Data(contentsOf: file)) == reference.sha256 else { throw ScrivError.invalid("An original reference image is missing or changed. Choose new references instead.") }
            return file
        }
    }
    /// Explicit user action only. Never called automatically by reconnect/startup.
    func retry(jobID: String) async throws -> URL {
        let jobID = jobID.lowercased()
        guard let job = jobs.first(where: { $0.id == jobID }), job.canRetry else { throw ScrivError.conflict("Inspect the existing generation before retrying.") }
        return try await generate(prompt: job.prompt, submittedPrompt: job.submittedPrompt, references: referenceURLs(for: jobID), context: job.context, retryOf: job.id)
    }
    /// Reads an already-recorded thread; does not resume a turn or invoke a model.
    func inspectJob(_ id: String) async throws {
        let id = id.lowercased()
        guard !isGenerating, inspectingJobID == nil, let job = jobs.first(where: { $0.id == id }), job.ownerInstallationID == installationID else { throw ScrivError.conflict("Finish the active operation before inspecting recovery.") }
        inspectingJobID = id; defer { inspectingJobID = nil }
        let directory = try jobDirectory(id)
        if job.status == .completed { _ = try artifactURL(for: id); return }
        // A lost runtime/history response must not hide a valid file already on
        // this Mac. Expose it as a candidate, not proof the original turn ended.
        if let candidate = (try? CodexImageArtifacts.candidates(in: directory, reported: []))?.first(where: { Self.isReadableImage($0) }) {
            try completeJob(id, file: candidate, confirmedComplete: false)
        }
        guard isConnected, runtimeIdentity == job.runtimeIdentity, let threadID = job.threadID else {
            try updateJob(id) { $0.status = .waiting; $0.progressText = "Connect the original runtime to inspect its saved turn. Nothing was resubmitted." }
            throw ScrivError.unavailable("Connect the original Codex runtime. A missing response does not prove generation failed; retrying may consume additional usage.")
        }
        let generation = connectionGeneration
        let response = try await rpc("thread/read", .object(["threadId": .string(threadID), "includeTurns": .bool(true)]))
        guard connectionGeneration == generation else { throw CancellationError() }
        guard response["thread"]?["id"]?.string == threadID else { throw ScrivError.invalid("Codex returned a different thread during recovery.") }
        let turns = response["thread"]?["turns"]?.array ?? []
        let turn = job.turnID.flatMap { id in turns.first(where: { $0["id"]?.string == id }) } ?? (job.turnID == nil && turns.count == 1 ? turns.first : nil)
        guard let turn, let turnID = turn["id"]?.string else {
            try updateJob(id) { $0.status = .waiting; $0.progressText = "The original turn is not visible yet. No new generation was submitted." }
            return
        }
        try updateJob(id) { $0.turnID = turnID }
        switch turn["status"]?.string {
        case "completed":
            let reported = (turn["items"]?.array ?? []).compactMap { item -> URL? in
                guard item["type"]?.string == "imageGeneration", let path = item["savedPath"]?.string, path.hasPrefix("/") else { return nil }
                return URL(fileURLWithPath: path)
            }
            guard let file = try CodexImageArtifacts.candidates(in: directory, reported: reported).first(where: { Self.isReadableImage($0) }) else {
                try updateJob(id) { $0.status = .failed; $0.progressText = "The saved turn completed without a valid local image"; $0.errorCode = "artifact_missing" }
                return
            }
            try completeJob(id, file: file)
        case "failed", "interrupted":
            try updateJob(id) { $0.status = turn["status"]?.string == "interrupted" ? .cancelled : .failed; $0.progressText = "Original turn ended without an accepted image"; $0.errorDetail = turn["error"]?["message"]?.string; $0.errorCode = "generation_failed" }
        default:
            try updateJob(id) { $0.status = .waiting; $0.progressText = "Original turn is still in progress. Inspect again later; do not submit a duplicate." }
        }
    }
}
