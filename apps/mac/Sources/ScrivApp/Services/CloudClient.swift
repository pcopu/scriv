import Foundation
import AppKit
import AuthenticationServices
import Security
import ScrivCore

@MainActor
final class CloudClient: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published private(set) var account: CloudUser?
    @Published private(set) var teams: [CloudTeam] = []
    @Published private(set) var projects: [CloudProject] = []
    @Published private(set) var peers: [PresencePeer] = []
    @Published private(set) var leases: [EditLease] = []
    @Published private(set) var status = "Local only"
    @Published private(set) var isConnected = false
    var onState: (() -> Void)?
    var onItems: (([CloudItem]) -> Void)?
    var onMessage: ((DiscussionMessage) -> Void)?
    var onThread: ((DiscussionThread) -> Void)?
    var onSignal: ((PeerSignal) -> Void)?
    var onError: ((Error) -> Void)?
    var onEvent: ((CloudEvent) -> Void)?
    var onDiscussionRefresh: (() -> Void)?
    let sessionId = UUID().uuidString
    private(set) var epoch = 1
    private(set) var headSeq = 0
    private(set) var timingVersion = 0
    private(set) var canImport = false
    private(set) var projectId: String?
    private(set) var deviceId: String?
    private var generation = 0
    private var signalCursor = 0
    private var signalPolling: Task<Void, Never>?
    private var deliveredSignals: Set<String> = []
    private var signalOrder: [String] = []
    private(set) var items: [String: CloudItem] = [:]
    private(set) var threads: [String: DiscussionThread] = [:]
    private var token: String?
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var reconnect: Task<Void, Never>?
    private var renewal: Task<Void, Never>?
    private var authSession: ASWebAuthenticationSession?
    private var heldLeases: [String: EditLease] = [:]
    private let leaseReleases = LeaseReleaseBarrier()
    private var stopped = false
    private var lastPresence: Date = .distantPast
    private var retryCount = 0
    private let urlSession: URLSession
    var baseURL: URL {
        get {
            let configured = UserDefaults.standard.string(forKey: "cloudBaseURL") ?? Bundle.main.object(forInfoDictionaryKey: "ScrivCloudURL") as? String
            if let configured, let url = URL(string: configured), Self.validEndpoint(url) { return url }
            return URL(string: "http://127.0.0.1:8787")!
        }
        set {
            guard Self.validEndpoint(newValue), newValue != baseURL else { return }
            authSession?.cancel(); authSession = nil; disconnect(); account = nil; teams = []; projects = []; deviceId = nil
            UserDefaults.standard.set(newValue.absoluteString, forKey: "cloudBaseURL")
            token = try? KeychainToken.read(account: newValue.absoluteString)
            notify()
        }
    }
    static func validEndpoint(_ url: URL) -> Bool { CloudEndpoint.isValid(url) }
    override init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 120
        urlSession = URLSession(configuration: configuration, delegate: CloudRedirectPolicy(), delegateQueue: nil)
        super.init()
        if !ProcessInfo.processInfo.arguments.contains("--screenshots"), !ProcessInfo.processInfo.arguments.contains("--peer-smoke") { token = try? KeychainToken.read(account:baseURL.absoluteString) }
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor() }
    private func notify() { onState?() }
    func request<T: Decodable>(_ path: String, method: String = "GET", body: JSONValue? = nil) async throws -> T {
        let data = try await requestData(path, method: method, body: body)
        return try ScrivJSON.decoder.decode(T.self, from: data)
    }
    private func requestData(_ path: String, method: String, body: JSONValue? = nil, data: Data? = nil, headers: [String: String] = [:]) async throws -> Data {
        let url = try CloudEndpoint.apiURL(path:path,base:baseURL)
        let requestBase = baseURL, requestToken = token, requestGeneration = generation
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.setValue(sessionId, forHTTPHeaderField: "X-Scriv-Device-Id")
        if let body { request.httpBody = try ScrivJSON.encoder.encode(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let data { request.httpBody = data }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (responseData, response) = try await urlSession.data(for: request)
        guard requestBase == baseURL, requestToken == token, requestGeneration == generation, !Task.isCancelled else { throw CancellationError() }
        guard let http = response as? HTTPURLResponse else { throw ScrivError.unavailable("The cloud response was not HTTP.") }
        guard (200..<300).contains(http.statusCode) else {
            let error = try? ScrivJSON.decoder.decode(JSONValue.self, from: responseData)
            let message = error?["error"]?["message"]?.string ?? "Cloud request failed (\(http.statusCode))."
            if http.statusCode == 401 { token = nil; account = nil; disconnect(); notify() }
            throw CloudRequestError(status:http.statusCode,code:error?["error"]?["code"]?.string ?? "request_failed",message:message)
        }
        return responseData.isEmpty ? Data("{}".utf8) : responseData
    }
    func restoreSession() async {
        guard token != nil else { return }
        do { try await refreshAccount() } catch { status = "Offline — local work is saved"; onError?(error); notify() }
    }
    func signIn() async throws {
        guard authSession == nil else { throw ScrivError.conflict("A sign-in window is already open.") }
        let loginServer = baseURL, loginGeneration = generation
        defer { authSession = nil }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ScrivError.unavailable("Could not create a secure sign-in challenge.") }
        let verifier = Data(bytes).base64URLEncoded
        let challenge = Data(ScrivDigest.bytes(Data(verifier.utf8))).base64URLEncoded
        let state = UUID().uuidString
        var components = URLComponents(url: baseURL.appendingPathComponent("auth/github/start"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "codeChallenge", value: challenge), URLQueryItem(name: "state", value: state)]
        guard let url = components.url, Self.validEndpoint(baseURL) else { throw ScrivError.invalid("Set your Scriv cloud server URL in Settings.") }
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "scriv") { callback, error in
                if let error { continuation.resume(throwing: error) }
                else if let callback { continuation.resume(returning: callback) }
                else { continuation.resume(throwing: ScrivError.unavailable("Sign-in did not return an authorization code.")) }
            }
            session.presentationContextProvider = self; session.prefersEphemeralWebBrowserSession = false; authSession = session
            if !session.start() { continuation.resume(throwing: ScrivError.unavailable("The sign-in browser could not open.")) }
        }
        guard baseURL == loginServer, generation == loginGeneration else { throw ScrivError.conflict("The server changed during sign-in. Start sign-in again for the current server.") }
        let values = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard callback.scheme == "scriv", callback.host == "auth", callback.path == "/callback", values.first(where: { $0.name == "state" })?.value == state, let code = values.first(where: { $0.name == "code" })?.value else { throw ScrivError.permission("Sign-in callback did not match this Mac's request.") }
        struct Exchange: Decodable { var token: String; var user: CloudUser }
        let result: Exchange = try await request("/auth/exchange", method: "POST", body: .object(["code":.string(code),"codeVerifier":.string(verifier),"deviceName":.string(Host.current().localizedName ?? "Mac")]))
        try KeychainToken.write(result.token, account: baseURL.absoluteString)
        token = result.token; account = result.user
        try await refreshAccount()
    }
    func refreshAccount() async throws {
        struct Me: Decodable { var user: CloudUser; var teams: [CloudTeam]; var projects: [CloudProject] }
        let result: Me = try await request("/v1/me")
        account = result.user; teams = result.teams; projects = result.projects
        let sessions: JSONValue = try await request("/auth/sessions")
        deviceId = sessions["currentSessionId"]?.string
        status = projectId == nil ? "Signed in" : status; notify()
    }
    func signOut() async throws {
        authSession?.cancel(); authSession = nil
        if token != nil { let _: JSONValue = try await request("/auth/logout", method: "POST") }
        try KeychainToken.delete(account: baseURL.absoluteString); token = nil; account = nil; teams = []; projects = []; deviceId = nil; disconnect(); notify()
    }
    func createTeam(name: String) async throws -> CloudTeam { struct Response: Decodable { var team: CloudTeam }; let response: Response = try await request("/v1/teams", method: "POST", body: .object(["name":.string(name)])); try await refreshAccount(); return response.team }
    @discardableResult
    func joinTeam(token: String) async throws -> CloudTeam { struct Response: Decodable { var team: CloudTeam }; let response: Response = try await request("/v1/join/\(token)",method:"POST"); try await refreshAccount(); return response.team }
    func joinLink(teamId: String, role: String = "member", expiresInDays: Int = 30) async throws -> URL { let result: JSONValue = try await request("/v1/teams/\(teamId)/join-links", method: "POST", body: .object(["role":.string(role),"expiresInDays":.number(Double(expiresInDays))])); guard let string = result["url"]?.string, let url = URL(string: string) else { throw ScrivError.invalid("The server returned an invalid join link.") }; return url }
    func renameTeam(teamId: String, name: String) async throws { let _: JSONValue = try await request("/v1/teams/\(teamId)",method:"PATCH",body:.object(["name":.string(name)])); try await refreshAccount() }
    func billing(teamId: String, portal: Bool) async throws -> URL { let result: JSONValue = try await request("/v1/teams/\(teamId)/billing/\(portal ? "portal" : "checkout")", method: "POST"); guard let string = result["url"]?.string, let url = URL(string:string), url.scheme == "https", url.user == nil, url.password == nil, ["checkout.stripe.com","billing.stripe.com"].contains(url.host ?? "") else { throw ScrivError.invalid("The billing URL is invalid.") }; return url }
    func createProject(_ project: ScrivProject, teamId: String?) async throws -> CloudProject {
        var payload: [String:JSONValue] = ["title":.string(project.title)]
        if let teamId { payload["teamId"] = .string(teamId) }
        struct Response: Decodable { var project: CloudProject }
        let response: Response = try await request("/v1/projects", method: "POST", body: .object(payload))
        try await refreshAccount(); return response.project
    }
    func renameProject(_ title: String) async throws { guard let projectId else { return }; let _: JSONValue = try await request("/v1/projects/\(projectId)", method: "PATCH", body: .object(["title":.string(title)])) }
    func attach(projectId: String, realtime: Bool) async throws -> CloudSnapshot {
        disconnect(); stopped = false; self.projectId = projectId
        let operationGeneration = generation
        let snapshot: CloudSnapshot = try await request("/v1/projects/\(projectId)/snapshot")
        guard operationGeneration == generation, self.projectId == projectId else { throw CancellationError() }
        _ = try snapshot.validatedItems(for:projectId)
        canImport = snapshot.canImport ?? (snapshot.headSeq == 0 && snapshot.allItems.isEmpty)
        epoch = snapshot.epoch; headSeq = snapshot.headSeq; timingVersion = snapshot.timingVersion ?? 0; items = Dictionary(uniqueKeysWithValues: snapshot.allItems.map { ($0.id,$0) }); status = realtime ? "Connecting…" : "Cloud sync"; notify()
        if realtime { connectSocket() }
        else { startHeartbeat(realtime: false) }
        threads = Dictionary((snapshot.threads ?? []).map { ($0.id,$0) },uniquingKeysWith: { _,latest in latest })
        for thread in snapshot.threads ?? [] { onThread?(thread) }
        startSignalPolling()
        onDiscussionRefresh?()
        return snapshot
    }
    func disconnect() {
        generation += 1; signalCursor = 0; deliveredSignals = []; signalOrder = []; signalPolling?.cancel(); signalPolling = nil
        stopped = true; socket?.cancel(with: .normalClosure, reason: nil); socket = nil; receiver?.cancel(); heartbeat?.cancel(); reconnect?.cancel(); renewal?.cancel()
        receiver = nil; heartbeat = nil; reconnect = nil; renewal = nil; retryCount = 0; peers = []; leases = []; heldLeases = [:]; isConnected = false; projectId = nil; items = [:]; threads = [:]; canImport = false; status = "Local only"; notify()
    }
    func acquireLease(_ itemId: String) async throws -> EditLease? {
        guard let projectId, items[itemId] != nil else { return nil }
        let operationGeneration = generation
        await leaseReleases.task(for:"\(operationGeneration):\(itemId)")?.value
        guard generation == operationGeneration, self.projectId == projectId else { throw CancellationError() }
        if let lease = heldLeases[itemId], lease.expiresAt > Int(Date().timeIntervalSince1970*1000)+5_000 { return lease }
        let lease: EditLease = try await request("/v1/projects/\(projectId)/leases", method: "POST", body: .object(["itemId":.string(itemId),"sessionId":.string(sessionId)]))
        guard operationGeneration == generation, self.projectId == projectId else { throw CancellationError() }
        heldLeases[itemId] = lease; leases.removeAll { $0.itemId == itemId }; leases.append(lease); notify(); startRenewal(); return lease
    }
    func releaseLease(_ itemId: String) async {
        guard let projectId, let lease = heldLeases.removeValue(forKey:itemId) else { return }
        let currentGeneration = generation, leaseEpoch = epoch
        let pending = leaseReleases.enqueue(key:"\(currentGeneration):\(itemId)") { [weak self] in
            guard let self, self.generation == currentGeneration, self.epoch == leaseEpoch, self.projectId == projectId else { return }
            do { let _: JSONValue = try await self.request("/v1/projects/\(projectId)/leases",method:"DELETE",body:self.leaseBody(lease)) }
            catch { /* Expiry and the server fence make an offline release safe. */ }
            guard self.generation == currentGeneration else { return }
            self.leases.removeAll { $0.itemId == itemId && $0.sessionId == self.sessionId && $0.fence == lease.fence }
            self.notify()
        }
        await pending.value
    }
    private func leaseBody(_ lease: EditLease) -> JSONValue { .object(["itemId":.string(lease.itemId),"sessionId":.string(sessionId),"token":.string(lease.token ?? ""),"fence":.number(Double(lease.fence)),"epoch":.number(Double(epoch))]) }
    private func startRenewal() {
        guard renewal == nil else { return }
        renewal = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, !Task.isCancelled, let projectId = self.projectId else { return }
                let currentGeneration = self.generation
                for lease in Array(self.heldLeases.values) {
                    guard LeaseLifecycle.matches(self.heldLeases[lease.itemId],expected:lease,epoch:self.epoch) else { continue }
                    do {
                        let renewed: EditLease = try await self.request("/v1/projects/\(projectId)/leases",method:"PUT",body:self.leaseBody(lease))
                        guard self.generation == currentGeneration, !Task.isCancelled else { return }
                        guard LeaseLifecycle.matches(self.heldLeases[lease.itemId],expected:lease,epoch:self.epoch) else { continue }
                        guard LeaseLifecycle.matches(renewed,expected:lease,epoch:self.epoch) else { throw ScrivError.invalid("The renewed editing lease has a different fence or identity.") }
                        self.heldLeases[lease.itemId] = renewed; self.leases.removeAll { $0.itemId == lease.itemId }; self.leases.append(renewed)
                    } catch {
                        guard self.generation == currentGeneration, !Task.isCancelled else { return }
                        guard LeaseLifecycle.matches(self.heldLeases[lease.itemId],expected:lease,epoch:self.epoch) else { continue }
                        self.heldLeases.removeValue(forKey:lease.itemId); self.leases.removeAll { $0.itemId == lease.itemId && $0.fence == lease.fence }
                        self.onError?(ScrivError.conflict("Editing lease expired. Your local draft is kept; reacquire the line before saving."))
                    }
                }
                self.notify()
            }
        }
    }
    func commit(before: ScrivProject, after: ScrivProject, label: String) async throws {
        guard let projectId else { throw ScrivError.unavailable("Reconnect this cloud project before saving shared changes.") }
        let operationGeneration = generation
        let expectedTimingVersion = timingVersion, expectedEpoch = epoch
        guard try pendingCommands(projectId:projectId).isEmpty else { throw ScrivError.conflict("A previous cloud save needs retry. Your new edits are saved on this Mac.") }
        let beforeItems = Dictionary(uniqueKeysWithValues: try CloudCodec.items(from: before).map { ($0.id,$0) })
        let afterItems = Dictionary(uniqueKeysWithValues: try CloudCodec.items(from: after).map { ($0.id,$0) })
        let changed = Set(beforeItems.keys).union(afterItems.keys).filter { beforeItems[$0]?.data != afterItems[$0]?.data || beforeItems[$0]?.kind != afterItems[$0]?.kind }.sorted()
        guard !changed.isEmpty else { return }
        guard changed.count <= 100 else { throw ScrivError.invalid("This edit changes more than 100 items. Split the operation into smaller edits.") }
        var operations: [JSONValue] = []
        for id in changed {
            let current = items[id]
            let canonical = current?.deleted == true ? nil : current
            if canonical?.data != beforeItems[id]?.data || canonical?.kind != beforeItems[id]?.kind { throw ScrivError.conflict("This item changed on another Mac. Your draft is preserved; review the live version before retrying.") }
            var operation: [String: JSONValue] = ["id":.string(id),"expectedVersion":.number(Double(current?.version ?? 0)),"op":.string(afterItems[id] == nil ? "delete" : "put")]
            if let next = afterItems[id] { operation["kind"] = .string(next.kind); operation["data"] = next.data }
            if let lease = try await acquireLease(id) { operation["lease"] = .object(["token":.string(lease.token ?? ""),"fence":.number(Double(lease.fence))]) }
            guard generation == operationGeneration, self.projectId == projectId else { throw CancellationError() }
            operations.append(.object(operation))
        }
        let commandId = UUID().uuidString
        let payload: JSONValue = .object(["commandId":.string(commandId),"sessionId":.string(sessionId),"epoch":.number(Double(expectedEpoch)),"expectedTimingVersion":.number(Double(expectedTimingVersion)),"label":.string(label),"operations":.array(operations)])
        struct Receipt: Decodable { var seq: Int; var epoch: Int; var timingVersion: Int?; var items: [CloudItem] }
        // Persist the precise idempotent request before sending; retries never acquire a new command identity.
        let pendingURL = try pendingDirectory().appendingPathComponent(commandId + ".json")
        try ScrivJSON.encoder.encode(JSONValue.object(["projectId":.string(projectId),"createdAt":.number(Date().timeIntervalSince1970*1000),"endpoint":.string("commands"),"payload":payload])).write(to: pendingURL, options: .atomic)
        let receipt: Receipt
        do { receipt = try await request("/v1/projects/\(projectId)/commands", method: "POST", body: payload) }
        catch { status = "Needs attention — draft saved locally"; notify(); throw error }
        guard generation == operationGeneration, self.projectId == projectId else { throw CancellationError() }
        guard receipt.epoch == epoch else { throw ScrivError.conflict("Project history was restored while this edit was saving. Your local draft is retained for review.") }
        for item in receipt.items where item.version >= (items[item.id]?.version ?? 0) { items[item.id] = item }; epoch = max(epoch,receipt.epoch); timingVersion = max(timingVersion,receipt.timingVersion ?? 0)
        // Only event replay advances the cursor, including our own history entry.
        // Applying a receipt must not skip its event or an earlier remote event.
        try? FileManager.default.removeItem(at: pendingURL)
        canImport = false; status = isConnected ? "Live" : "Cloud sync"; notify()
    }
    func seed(_ project: ScrivProject) async throws {
        guard let projectId else { throw ScrivError.unavailable("No cloud project is open.") }
        let currentGeneration = generation
        let all = try CloudCodec.items(from: project)
        let savedURL = try pendingDirectory().appendingPathComponent("import-" + projectId + ".json")
        let payload: JSONValue
        if FileManager.default.fileExists(atPath:savedURL.path) {
            let record = try ScrivJSON.decoder.decode(JSONValue.self,from:Data(contentsOf:savedURL))
            guard record["projectId"]?.string == projectId, let previous = record["payload"] else { throw ScrivError.invalid("The saved import request is invalid.") }
            payload = previous
        } else {
            payload = .object(["commandId":.string(UUID().uuidString),"sessionId":.string(sessionId),"epoch":.number(Double(epoch)),"expectedTimingVersion":.number(Double(timingVersion)),"label":.string("Import project"),"items":try .encoded(all)])
            try ScrivJSON.encoder.encode(JSONValue.object(["projectId":.string(projectId),"createdAt":.number(Date().timeIntervalSince1970*1000),"endpoint":.string("import"),"payload":payload])).write(to:savedURL,options:.atomic)
        }
        guard try ScrivJSON.encoder.encode(payload).count <= 16*1024*1024 else { throw ScrivError.invalid("Project metadata exceeds the 16 MiB import limit.") }
        let _: JSONValue = try await request("/v1/projects/\(projectId)/import", method: "POST", body: payload)
        let snapshot: CloudSnapshot = try await request("/v1/projects/\(projectId)/snapshot")
        guard generation == currentGeneration, self.projectId == projectId else { throw CancellationError() }
        _ = try snapshot.validatedItems(for:projectId)
        items = Dictionary(uniqueKeysWithValues: snapshot.allItems.map { ($0.id,$0) }); epoch = snapshot.epoch; headSeq = snapshot.headSeq; timingVersion = snapshot.timingVersion ?? 0; canImport = snapshot.canImport ?? false
        try? FileManager.default.removeItem(at:savedURL)
        threads = Dictionary((snapshot.threads ?? []).map { ($0.id,$0) },uniquingKeysWith: { _,latest in latest })
        for thread in snapshot.threads ?? [] { onThread?(thread) }; onDiscussionRefresh?()
    }
    func retryPendingCommands() async throws {
        guard let projectId else { return }
        let currentGeneration = generation
        for url in try pendingCommands(projectId:projectId) {
            let saved = try ScrivJSON.decoder.decode(JSONValue.self, from: Data(contentsOf: url))
            guard saved["projectId"]?.string == projectId, let payload = saved["payload"] else { continue }
            let endpoint = saved["endpoint"]?.string == "import" ? "import" : "commands"
            do {
                let _: JSONValue = try await request("/v1/projects/\(projectId)/\(endpoint)", method: "POST", body: payload)
                guard generation == currentGeneration else { throw CancellationError() }
                try FileManager.default.removeItem(at:url)
            } catch let error as CloudRequestError where ["lease_required","item_locked","stale_epoch","version_conflict","timing_conflict"].contains(error.code) {
                // A recorded receipt is checked by the server before all these fences.
                // This exact request is definitively uncommitted; retain its audit copy,
                // then let three-way reconciliation decide whether a new edit is safe.
                guard generation == currentGeneration else { throw CancellationError() }
                try FileManager.default.moveItem(at:url,to:url.deletingPathExtension().appendingPathExtension("rejected"))
            }
        }
        try await replay()
    }
    private func pendingCommands(projectId: String) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at:pendingDirectory(),includingPropertiesForKeys:[.creationDateKey]).filter { url in
            guard url.pathExtension == "json" else { return false }
            let record = try ScrivJSON.decoder.decode(JSONValue.self,from:Data(contentsOf:url))
            return record["projectId"]?.string == projectId
        }.sorted { ((try? $0.resourceValues(forKeys:[.creationDateKey]).creationDate) ?? .distantPast) < ((try? $1.resourceValues(forKeys:[.creationDateKey]).creationDate) ?? .distantPast) }
    }
    /// Opening the canonical cloud version is an explicit conflict-resolution action.
    /// Retain unsent payloads for recovery, but do not replay them over that choice later.
    func keepPendingAsLocalDrafts() throws {
        guard let projectId else { return }
        for url in try pendingCommands(projectId:projectId) { try FileManager.default.moveItem(at:url,to:url.deletingPathExtension().appendingPathExtension("local-draft")) }
    }
    private func pendingDirectory() throws -> URL { guard let account else { throw ScrivError.unavailable("Sign in before saving cloud edits.") }; let scope = ScrivDigest.sha256(Data((baseURL.absoluteString + "/" + account.id).utf8)); let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Scriv/Outbox").appendingPathComponent(scope); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); return directory }
    private func connectSocket() {
        guard let projectId, let token, !stopped else { return }
        var components = URLComponents(url: baseURL.appendingPathComponent("v1/projects/\(projectId)/socket"), resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization"); request.setValue(sessionId, forHTTPHeaderField: "X-Scriv-Device-Id")
        let currentGeneration = generation
        socket?.cancel(with:.goingAway,reason:nil)
        let ws = urlSession.webSocketTask(with: request); socket = ws; ws.resume()
        receiver?.cancel()
        receiver = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await ws.receive(), data: Data
                    switch message { case .data(let value): data = value; case .string(let value): data = Data(value.utf8); @unknown default: continue }
                    guard let self, self.generation == currentGeneration, self.socket === ws else { return }
                    if let event = try? ScrivJSON.decoder.decode(JSONValue.self, from: data) { try await self.handle(event) }
                }
            } catch { guard let self, self.generation == currentGeneration, self.socket === ws, !self.stopped, !Task.isCancelled else { return }; self.isConnected = false; self.status = "Reconnecting…"; self.notify(); self.scheduleReconnect() }
        }
        startHeartbeat(realtime: true)
    }
    private func scheduleReconnect() {
        reconnect?.cancel(); retryCount += 1
        let delay = min(30.0,pow(2.0,Double(min(retryCount,5)))) + Double.random(in: 0...1)
        let currentGeneration = generation
        reconnect = Task { [weak self] in try? await Task.sleep(for: .seconds(delay)); guard let self, self.generation == currentGeneration, !Task.isCancelled, !self.stopped else { return }; self.connectSocket() }
    }
    private func startHeartbeat(realtime: Bool) {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(realtime ? 2 : 5))
                guard let self, !Task.isCancelled, self.projectId != nil else { return }
                do { if realtime { try await self.send(.object(["type":.string("ping"),"after":.number(Double(self.headSeq))])) } else { try await self.replay() } }
                catch { if !realtime { self.status = "Offline — local work is saved"; self.notify() } }
            }
        }
    }
    private func handle(_ event: JSONValue) async throws {
        switch event["type"]?.string {
        case "hello": deviceId = event["deviceId"]?.string ?? deviceId; isConnected = true; retryCount = 0; status = "Live"; notify(); try await send(.object(["type":.string("resume"),"after":.number(Double(headSeq))])); onDiscussionRefresh?()
        case "event": if let value = event["event"] { try await consume(try value.decoded(CloudEvent.self)) }
        case "events":
            let startSeq = headSeq
            for value in event["events"]?.array ?? [] { try await consume(try value.decoded(CloudEvent.self),notifyItems:false) }
            if headSeq != startSeq { onItems?(Array(items.values)); notify() }
            if event["headSeq"]?.int ?? 0 > headSeq { try await replay() }
        case "watermark": if event["epoch"]?.int != epoch || (event["headSeq"]?.int ?? 0) > headSeq { try await replay() }
        case "presence": peers = try (event["peers"]?.array ?? []).map { try $0.decoded(PresencePeer.self) }; notify()
        case "leases": leases = try (event["leases"]?.array ?? []).map { try $0.decoded(EditLease.self) }; notify()
        case "message": if let value = event["message"] { onMessage?(try value.decoded(DiscussionMessage.self)) }
        case "thread": if let value = event["thread"] { let thread = try value.decoded(DiscussionThread.self); threads[thread.id] = thread; onThread?(thread) }
        case "signal":
            if let from = event["fromDeviceId"]?.string, let type = event["signalType"]?.string, let payload = event["payload"] { deliverSignal(PeerSignal(fromDeviceId: from,toDeviceId: deviceId ?? "",type: type,payload: payload)) }
        case "error": onError?(ScrivError.unavailable(event["error"]?["message"]?.string ?? event["message"]?.string ?? "Live connection error."))
        default: break
        }
    }
    private func consume(_ event: CloudEvent, notifyItems: Bool = true) async throws {
        if event.seq <= headSeq { return }
        guard event.seq == headSeq + 1 else { try await replay(); return }
        if event.data?["snapshotRequired"] == .bool(true) {
            guard let projectId else { return }; let currentGeneration = generation
            let snapshot: CloudSnapshot = try await request("/v1/projects/\(projectId)/snapshot")
            guard generation == currentGeneration, self.projectId == projectId else { throw CancellationError() }
            _ = try snapshot.validatedItems(for:projectId)
            if epoch != snapshot.epoch { heldLeases = [:]; leases = [] }
            items = Dictionary(uniqueKeysWithValues:snapshot.allItems.map { ($0.id,$0) }); epoch = snapshot.epoch; headSeq = snapshot.headSeq; timingVersion = snapshot.timingVersion ?? timingVersion; canImport = snapshot.canImport ?? false
            threads = Dictionary((snapshot.threads ?? []).map { ($0.id,$0) },uniquingKeysWith: { _,latest in latest })
        for thread in snapshot.threads ?? [] { onThread?(thread) }
            onDiscussionRefresh?()
            if notifyItems { onItems?(Array(items.values)); notify() }; onEvent?(event); return
        }
        if event.epoch != epoch { epoch = event.epoch; heldLeases = [:]; leases = [] }
        for change in event.changes {
            if let after = change.after { if after.version >= (items[change.id]?.version ?? 0) { items[change.id] = after } }
            else { items.removeValue(forKey: change.id) }
        }
        if let value = event.data?["thread"], event.kind.hasPrefix("discussion.") { let thread = try value.decoded(DiscussionThread.self); threads[thread.id] = thread; onThread?(thread) }
        if let message = event.data?["message"], event.kind == "discussion.message-created" { onMessage?(try message.decoded(DiscussionMessage.self)) }
        if !event.changes.isEmpty { canImport = false }
        headSeq = event.seq; timingVersion = max(timingVersion,event.data?["timingVersion"]?.int ?? 0)
        if notifyItems { onItems?(Array(items.values)); notify() }; onEvent?(event)
    }
    func replay() async throws {
        guard let projectId else { return }
        let currentGeneration = generation
        struct Page: Decodable { var events: [CloudEvent]; var headSeq: Int; var hasMore: Bool }
        for _ in 0..<100 {
            let startSeq = headSeq
            let page: Page = try await request("/v1/projects/\(projectId)/events?after=\(headSeq)&limit=100")
            guard generation == currentGeneration, self.projectId == projectId else { throw CancellationError() }
            for event in page.events {
                guard event.seq == headSeq+1 || event.seq <= headSeq else { throw ScrivError.conflict("History has a sequence gap; reopen the cloud project to recover.") }
                if event.seq > headSeq { try await consume(event,notifyItems:false) }
            }
            if headSeq != startSeq { onItems?(Array(items.values)); notify() }
            if !page.hasMore { return }
            guard !page.events.isEmpty else { throw ScrivError.invalid("The server returned an empty history page with more events pending.") }
        }
        throw ScrivError.unavailable("History catch-up is still in progress; retry synchronization to continue.")
    }
    func presence(itemId: String?, selection: JSONValue? = nil, cursor: JSONValue? = nil) {
        guard isConnected, Date().timeIntervalSince(lastPresence) >= 0.2 else { return }; lastPresence = Date()
        var payload: [String:JSONValue] = ["type":.string("presence"),"itemId": itemId.map(JSONValue.string) ?? .null]
        if let selection { payload["selection"] = selection }; if let cursor { payload["cursor"] = cursor }
        let currentGeneration = generation
        Task { guard currentGeneration == generation else { return }; try? await send(.object(payload)) }
    }
    func send(_ value: JSONValue) async throws { guard let socket else { throw ScrivError.unavailable("Live connection is not ready.") }; try await socket.send(.data(ScrivJSON.encoder.encode(value))) }
    func signal(_ signal: PeerSignal) async throws {
        guard let projectId else { throw ScrivError.unavailable("Open a cloud project before peer synchronization.") }
        let _: JSONValue = try await request("/v1/projects/\(projectId)/signals", method: "POST", body: try .encoded(signal))
    }
    func teamDetails(_ teamId: String) async throws -> JSONValue { try await request("/v1/teams/\(teamId)") }
    func revokeJoinLink(teamId: String, linkId: String) async throws { let _: JSONValue = try await request("/v1/teams/\(teamId)/join-links/\(linkId)", method: "DELETE") }
    func setMemberRole(teamId: String, userId: String, role: String) async throws { let _: JSONValue = try await request("/v1/teams/\(teamId)/members/\(userId)", method: "PATCH", body: .object(["role":.string(role)])) }
    func removeMember(teamId: String, userId: String) async throws { let _: JSONValue = try await request("/v1/teams/\(teamId)/members/\(userId)", method: "DELETE") }
    func peerConfiguration() async throws -> JSONValue { guard let projectId else { throw ScrivError.unavailable("Open a cloud project first.") }; let result: JSONValue = try await request("/v1/projects/\(projectId)/ice-servers"); return result["iceServers"] ?? .array([]) }
    func peerDevices() async throws -> [JSONValue] { guard let projectId else { return [] }; let result: JSONValue = try await request("/v1/projects/\(projectId)/devices"); return result["devices"]?.array ?? [] }
    private func deliverSignal(_ signal: PeerSignal) {
        guard let encoded = try? ScrivJSON.encoder.encode(signal) else { return }
        let fingerprint = ScrivDigest.sha256(encoded)
        guard !deliveredSignals.contains(fingerprint) else { return }
        deliveredSignals.insert(fingerprint); signalOrder.append(fingerprint)
        if signalOrder.count > 2000 { deliveredSignals.remove(signalOrder.removeFirst()) }
        onSignal?(signal)
    }
    private func startSignalPolling() {
        signalPolling?.cancel()
        signalPolling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let projectId = self.projectId, let deviceId = self.deviceId else { return }
                let currentGeneration = self.generation
                do {
                    // Polling also repairs a missed final signal across WebSocket reconnects.
                    let result: JSONValue = try await self.request("/v1/projects/\(projectId)/signals?deviceId=\(deviceId)&after=\(self.signalCursor)")
                    guard self.generation == currentGeneration else { return }
                    for value in result["signals"]?.array ?? [] {
                        if let id = value["id"]?.int { self.signalCursor = max(self.signalCursor,id) }
                        if let from = value["fromDeviceId"]?.string, let type = value["type"]?.string, let payload = value["payload"] {
                            self.deliverSignal(PeerSignal(fromDeviceId:from,toDeviceId:deviceId,type:type,payload:payload))
                        }
                    }
                } catch { if !Task.isCancelled { self.status = "Peer discovery reconnecting"; self.notify() } }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
    func thread(itemId: String?, anchor: JSONValue? = nil) async throws -> DiscussionThread {
        guard let projectId else { throw ScrivError.unavailable("Sync this project to use shared discussions.") }
        struct Response: Decodable { var thread: DiscussionThread }
        var body: [String:JSONValue] = ["itemId":itemId.map(JSONValue.string) ?? .null]
        if let anchor { body["anchor"] = anchor }
        let response: Response = try await request("/v1/projects/\(projectId)/threads", method: "POST", body: .object(body))
        threads[response.thread.id] = response.thread; return response.thread
    }
    func refreshThreads() async throws {
        guard let projectId else { return }
        struct Page: Decodable { var threads: [DiscussionThread]; var hasMore: Bool; var nextCursor: String? }
        let operation = generation
        var cursor = ""
        while true {
            let page: Page = try await request("/v1/projects/\(projectId)/threads?scope=all&limit=100&after=\(CloudEndpoint.queryValue(cursor))")
            guard generation == operation else { throw CancellationError() }
            for thread in page.threads { threads[thread.id] = thread }
            if !page.hasMore { return }
            guard let next = page.nextCursor, next > cursor else { throw ScrivError.invalid("The discussion directory stopped advancing.") }
            cursor = next
        }
    }
    func projectMembers() async throws -> [DiscussionMember] {
        guard let projectId else { throw ScrivError.unavailable("Sync this project to choose team members.") }
        struct Page: Decodable { var members: [DiscussionMember]; var hasMore: Bool; var nextCursor: String? }
        let operation = generation
        var result: [String:DiscussionMember] = [:], cursor = ""
        while true {
            let page: Page = try await request("/v1/projects/\(projectId)/members?limit=200&after=\(CloudEndpoint.queryValue(cursor))")
            guard generation == operation else { throw CancellationError() }
            for member in page.members { result[member.id] = member }
            if !page.hasMore { return result.values.sorted { ($0.name.localizedLowercase,$0.id) < ($1.name.localizedLowercase,$1.id) } }
            guard let next = page.nextCursor, next > cursor else { throw ScrivError.invalid("The member directory stopped advancing.") }
            cursor = next
        }
    }
    func messages(threadId: String) async throws -> [DiscussionMessage] {
        guard let projectId else { return [] }
        struct Response: Decodable { var messages: [DiscussionMessage]; var hasMore: Bool?; var nextCursor: JSONValue? }
        let currentGeneration = generation
        var collected: [String:DiscussionMessage] = [:], after = 0, afterID = ""
        while true {
            let response: Response = try await request("/v1/projects/\(projectId)/threads/\(threadId)/messages?after=\(after)&afterId=\(CloudEndpoint.queryValue(afterID))")
            guard generation == currentGeneration else { throw CancellationError() }
            for message in response.messages { collected[message.id] = message }
            if response.hasMore != true { return collected.values.sorted { ($0.createdAt ?? $0.at ?? 0,$0.id) < ($1.createdAt ?? $1.at ?? 0,$1.id) } }
            guard let next = response.nextCursor, let timestamp = next["at"]?.int, let identifier = next["id"]?.string,
                  (timestamp,identifier) > (after,afterID) else { throw ScrivError.invalid("Discussion pagination stopped advancing.") }
            after = timestamp; afterID = identifier
        }
    }
    func postMessage(threadId: String, text: String, replyToId: String? = nil, attachments: [JSONValue] = [], mentionedUserIds: [String] = [], messageId: String = UUID().uuidString) async throws -> DiscussionMessage {
        guard let projectId else { throw ScrivError.unavailable("No cloud project is open.") }; struct Response: Decodable { var message: DiscussionMessage }
        let response: Response = try await request("/v1/projects/\(projectId)/threads/\(threadId)/messages", method: "POST", body: .object(["id":.string(messageId),"body":.string(text),"replyToId":replyToId.map(JSONValue.string) ?? .null,"attachments":.array(attachments),"mentionedUserIds":.array(mentionedUserIds.map(JSONValue.string))])); return response.message
    }
    func resolve(threadId: String, resolved: Bool) async throws -> DiscussionThread {
        guard let projectId else { throw ScrivError.unavailable("No cloud project is open.") }; struct Response: Decodable { var thread: DiscussionThread }
        let response: Response = try await request("/v1/projects/\(projectId)/threads/\(threadId)", method: "PATCH", body: .object(["resolved":.bool(resolved)])); return response.thread
    }
    func history() async throws -> [CloudEvent] {
        guard let projectId else { return [] }; struct Page: Decodable { var events: [CloudEvent]; var hasMore: Bool }
        let currentGeneration = generation
        var output: [CloudEvent] = [], after = 0
        while true {
            let page: Page = try await request("/v1/projects/\(projectId)/history?after=\(after)&limit=100")
            guard generation == currentGeneration else { throw CancellationError() }
            output += page.events
            if !page.hasMore { return output.reversed() }
            guard let last = page.events.last, last.seq > after else { throw ScrivError.invalid("Cloud history pagination stopped advancing.") }
            after = last.seq
        }
    }
    func historicalSnapshot(seq: Int) async throws -> CloudSnapshot {
        guard let projectId else { throw ScrivError.unavailable("Reconnect this project to preview cloud history.") }
        let operation = generation
        var combined: CloudSnapshot?, cursor = ""
        while true {
            let page: CloudSnapshot = try await request("/v1/projects/\(projectId)/snapshot?seq=\(seq)&limit=200&after=\(CloudEndpoint.queryValue(cursor))")
            guard operation == generation else { throw CancellationError() }
            _ = try page.validatedItems(for:projectId)
            guard page.headSeq == seq else { throw ScrivError.invalid("The server returned a different history revision.") }
            if var existing = combined {
                guard existing.epoch == page.epoch, existing.timingVersion == page.timingVersion else { throw ScrivError.invalid("Historical snapshot pages disagree.") }
                existing.items += page.items; existing.deletedItems = (existing.deletedItems ?? []) + (page.deletedItems ?? [])
                combined = existing
            } else { combined = page }
            if page.hasMore != true {
                guard var result = combined else { throw ScrivError.invalid("No history snapshot was returned.") }
                result.hasMore = false; result.nextCursor = nil; _ = try result.validatedItems(for:projectId)
                return result
            }
            guard let next = page.nextCursor, next > cursor else { throw ScrivError.invalid("Historical snapshot pagination stopped advancing.") }
            cursor = next
        }
    }
    func restore(seq: Int) async throws {
        guard let projectId else { return }
        let _: JSONValue = try await request("/v1/projects/\(projectId)/restore", method: "POST", body: .object(["commandId":.string(UUID().uuidString),"sessionId":.string(sessionId),"epoch":.number(Double(epoch)),"expectedTimingVersion":.number(Double(timingVersion)),"seq":.number(Double(seq))])); try await replay()
    }
    func upload(_ asset: ImageAsset, data: Data) async throws {
        guard let projectId, ScrivDigest.sha256(data) == asset.sha256 else { throw ScrivError.invalid("Image integrity check failed.") }
        _ = try await requestData("/v1/projects/\(projectId)/assets/\(asset.sha256)", method: "PUT", data: data, headers: ["Content-Type":asset.mimeType,"X-Scriv-Asset-Id":asset.id])
    }
    func download(_ asset: ImageAsset) async throws -> Data {
        guard let projectId else { throw ScrivError.unavailable("No cloud project is open.") }
        let data = try await requestData("/v1/projects/\(projectId)/assets/\(asset.sha256)", method: "GET")
        guard data.count == asset.byteCount, ScrivDigest.sha256(data) == asset.sha256 else { throw ScrivError.invalid("Downloaded image failed its integrity check.") }; return data
    }
}

private final class CloudRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

struct CloudRequestError: LocalizedError {
    let status: Int
    let code: String
    let message: String
    var errorDescription: String? { message }
}

private extension Data { var base64URLEncoded: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") } }
private enum KeychainToken {
    static let service = "com.scriv.account"
    static func read(account: String) throws -> String? { var result: CFTypeRef?; let status = SecItemCopyMatching([kSecClass:kSecClassGenericPassword,kSecAttrService:service,kSecAttrAccount:account,kSecReturnData:true,kSecMatchLimit:kSecMatchLimitOne] as CFDictionary,&result); if status == errSecItemNotFound { return nil }; guard status == errSecSuccess, let data = result as? Data, let token = String(data:data,encoding:.utf8) else { throw ScrivError.unavailable("Could not read the saved account from Keychain.") }; return token }
    static func write(_ token: String, account: String) throws { try delete(account:account); let status = SecItemAdd([kSecClass:kSecClassGenericPassword,kSecAttrService:service,kSecAttrAccount:account,kSecValueData:Data(token.utf8),kSecAttrAccessible:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary,nil); guard status == errSecSuccess else { throw ScrivError.unavailable("Could not save the account in Keychain.") } }
    static func delete(account: String) throws { let status = SecItemDelete([kSecClass:kSecClassGenericPassword,kSecAttrService:service,kSecAttrAccount:account] as CFDictionary); guard status == errSecSuccess || status == errSecItemNotFound else { throw ScrivError.unavailable("Could not remove the account from Keychain.") } }
}
