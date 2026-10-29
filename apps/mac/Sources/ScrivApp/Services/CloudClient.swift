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
    var onSignal: ((PeerSignal) -> Void)?
    var onError: ((Error) -> Void)?
    var onEvent: ((CloudEvent) -> Void)?
    let sessionId = UUID().uuidString
    private(set) var epoch = 1
    private(set) var headSeq = 0
    private(set) var projectId: String?
    private(set) var items: [String: CloudItem] = [:]
    private var token: String?
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var reconnect: Task<Void, Never>?
    private var renewal: Task<Void, Never>?
    private var authSession: ASWebAuthenticationSession?
    private var heldLeases: [String: EditLease] = [:]
    private var stopped = false
    private var lastPresence: Date = .distantPast
    private var retryCount = 0
    private var serialCommit: Task<Void, Never>?
    private let urlSession: URLSession
    var baseURL: URL {
        get { URL(string: UserDefaults.standard.string(forKey: "cloudBaseURL") ?? Bundle.main.object(forInfoDictionaryKey: "ScrivCloudURL") as? String ?? "http://127.0.0.1:8787")! }
        set { guard Self.validEndpoint(newValue) else { return }; UserDefaults.standard.set(newValue.absoluteString, forKey: "cloudBaseURL") }
    }
    static func validEndpoint(_ url: URL) -> Bool { url.scheme == "https" || url.scheme == "http" && ["127.0.0.1","localhost","::1"].contains(url.host ?? "") }
    override init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 120
        urlSession = URLSession(configuration: configuration)
        super.init()
        token = try? KeychainToken.read(account: baseURL.absoluteString)
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor() }
    private func notify() { onState?() }
    func request<T: Decodable>(_ path: String, method: String = "GET", body: JSONValue? = nil) async throws -> T {
        let data = try await requestData(path, method: method, body: body)
        return try ScrivJSON.decoder.decode(T.self, from: data)
    }
    private func requestData(_ path: String, method: String, body: JSONValue? = nil, data: Data? = nil, headers: [String: String] = [:]) async throws -> Data {
        guard Self.validEndpoint(baseURL), let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else { throw ScrivError.invalid("Set a valid HTTPS Scriv server in Settings.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.setValue(sessionId, forHTTPHeaderField: "X-Scriv-Device-Id")
        if let body { request.httpBody = try ScrivJSON.encoder.encode(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let data { request.httpBody = data }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (responseData, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ScrivError.unavailable("The cloud response was not HTTP.") }
        guard (200..<300).contains(http.statusCode) else {
            let error = try? ScrivJSON.decoder.decode(JSONValue.self, from: responseData)
            let message = error?["error"]?["message"]?.string ?? "Cloud request failed (\(http.statusCode))."
            if http.statusCode == 401 { token = nil; account = nil; disconnect(); notify() }
            throw http.statusCode == 409 || http.statusCode == 423 ? ScrivError.conflict(message) : ScrivError.unavailable(message)
        }
        return responseData.isEmpty ? Data("{}".utf8) : responseData
    }
    func restoreSession() async {
        guard token != nil else { return }
        do { try await refreshAccount() } catch { status = "Offline — local work is saved"; onError?(error); notify() }
    }
    func signIn() async throws {
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
        defer { authSession = nil }
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
        account = result.user; teams = result.teams; projects = result.projects; status = projectId == nil ? "Signed in" : status; notify()
    }
    func signOut() async throws {
        if token != nil { let _: JSONValue = try await request("/auth/logout", method: "POST") }
        try KeychainToken.delete(account: baseURL.absoluteString); token = nil; account = nil; teams = []; projects = []; disconnect(); notify()
    }
    func createTeam(name: String) async throws -> CloudTeam { struct Response: Decodable { var team: CloudTeam }; let response: Response = try await request("/v1/teams", method: "POST", body: .object(["name":.string(name)])); try await refreshAccount(); return response.team }
    func joinTeam(token: String) async throws { let _: JSONValue = try await request("/v1/join/\(token)", method: "POST"); try await refreshAccount() }
    func joinLink(teamId: String) async throws -> URL { let result: JSONValue = try await request("/v1/teams/\(teamId)/join-links", method: "POST", body: .object(["role":.string("member"),"expiresInDays":.number(30)])); guard let string = result["url"]?.string, let url = URL(string: string) else { throw ScrivError.invalid("The server returned an invalid join link.") }; return url }
    func billing(teamId: String, portal: Bool) async throws -> URL { let result: JSONValue = try await request("/v1/teams/\(teamId)/billing/\(portal ? "portal" : "checkout")", method: "POST"); guard let string = result["url"]?.string, let url = URL(string: string), url.scheme == "https" else { throw ScrivError.invalid("The billing URL is invalid.") }; return url }
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
        let snapshot: CloudSnapshot = try await request("/v1/projects/\(projectId)/snapshot")
        epoch = snapshot.epoch; headSeq = snapshot.headSeq; items = Dictionary(uniqueKeysWithValues: snapshot.items.map { ($0.id,$0) }); status = realtime ? "Connecting…" : "Cloud sync"; notify()
        if realtime { connectSocket() }
        else { startHeartbeat(realtime: false) }
        return snapshot
    }
    func disconnect() {
        stopped = true; socket?.cancel(with: .normalClosure, reason: nil); socket = nil; receiver?.cancel(); heartbeat?.cancel(); reconnect?.cancel(); renewal?.cancel(); serialCommit?.cancel()
        receiver = nil; heartbeat = nil; renewal = nil; peers = []; leases = []; heldLeases = [:]; isConnected = false; projectId = nil; items = [:]; status = "Local only"; notify()
    }
    func acquireLease(_ itemId: String) async throws -> EditLease? {
        guard let projectId, items[itemId] != nil else { return nil }
        if let lease = heldLeases[itemId], lease.expiresAt > Int(Date().timeIntervalSince1970*1000)+5_000 { return lease }
        let lease: EditLease = try await request("/v1/projects/\(projectId)/leases", method: "POST", body: .object(["itemId":.string(itemId),"sessionId":.string(sessionId)]))
        heldLeases[itemId] = lease; leases.removeAll { $0.itemId == itemId }; leases.append(lease); notify(); startRenewal(); return lease
    }
    func releaseLease(_ itemId: String) async {
        guard let projectId, let lease = heldLeases.removeValue(forKey: itemId) else { return }
        do { let _: JSONValue = try await request("/v1/projects/\(projectId)/leases", method: "DELETE", body: leaseBody(lease)) } catch { /* Expiry fences this lease even if offline. */ }
        leases.removeAll { $0.itemId == itemId && $0.sessionId == sessionId }; notify()
    }
    private func leaseBody(_ lease: EditLease) -> JSONValue { .object(["itemId":.string(lease.itemId),"sessionId":.string(sessionId),"token":.string(lease.token ?? ""),"fence":.number(Double(lease.fence)),"epoch":.number(Double(epoch))]) }
    private func startRenewal() {
        guard renewal == nil else { return }
        renewal = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, let projectId = self.projectId else { return }
                for lease in Array(self.heldLeases.values) {
                    do { let renewed: EditLease = try await self.request("/v1/projects/\(projectId)/leases", method: "PUT", body: self.leaseBody(lease)); self.heldLeases[lease.itemId] = renewed; self.leases.removeAll { $0.itemId == lease.itemId }; self.leases.append(renewed) }
                    catch { self.heldLeases.removeValue(forKey: lease.itemId); self.leases.removeAll { $0.itemId == lease.itemId }; self.onError?(ScrivError.conflict("Editing lease expired. Your local draft is kept; reacquire the line before saving.")) }
                }
                self.notify()
            }
        }
    }
    func commit(before: ScrivProject, after: ScrivProject, label: String) async throws {
        guard let projectId else { return }
        let beforeItems = Dictionary(uniqueKeysWithValues: try CloudCodec.items(from: before).map { ($0.id,$0) })
        let afterItems = Dictionary(uniqueKeysWithValues: try CloudCodec.items(from: after).map { ($0.id,$0) })
        let changed = Set(beforeItems.keys).union(afterItems.keys).filter { beforeItems[$0]?.data != afterItems[$0]?.data || beforeItems[$0]?.kind != afterItems[$0]?.kind }.sorted()
        guard !changed.isEmpty else { return }
        guard changed.count <= 100 else { throw ScrivError.invalid("This edit changes more than 100 items. Split the operation into smaller edits.") }
        var operations: [JSONValue] = []
        for id in changed {
            let current = items[id]
            if let current, current.deleted != true, let baseline = beforeItems[id], current.data != baseline.data { throw ScrivError.conflict("This item changed on another Mac. Your draft is preserved; review the live version before retrying.") }
            var operation: [String: JSONValue] = ["id":.string(id),"expectedVersion":.number(Double(current?.version ?? 0)),"op":.string(afterItems[id] == nil ? "delete" : "put")]
            if let next = afterItems[id] { operation["kind"] = .string(next.kind); operation["data"] = next.data }
            if let lease = try await acquireLease(id) { operation["lease"] = .object(["token":.string(lease.token ?? ""),"fence":.number(Double(lease.fence))]) }
            operations.append(.object(operation))
        }
        let commandId = UUID().uuidString
        let payload: JSONValue = .object(["commandId":.string(commandId),"sessionId":.string(sessionId),"epoch":.number(Double(epoch)),"label":.string(label),"operations":.array(operations)])
        struct Receipt: Decodable { var seq: Int; var epoch: Int; var items: [CloudItem] }
        // Persist the precise idempotent request before sending; retries never acquire a new command identity.
        let pendingURL = try pendingDirectory().appendingPathComponent(commandId + ".json")
        try ScrivJSON.encoder.encode(JSONValue.object(["projectId":.string(projectId),"payload":payload])).write(to: pendingURL, options: .atomic)
        let receipt: Receipt
        do { receipt = try await request("/v1/projects/\(projectId)/commands", method: "POST", body: payload) }
        catch { status = "Needs attention — draft saved locally"; notify(); throw error }
        for item in receipt.items { items[item.id] = item }; epoch = receipt.epoch
        // Never jump the replay cursor: preceding remote events may not have arrived yet.
        if receipt.seq == headSeq + 1 { headSeq = receipt.seq }
        try? FileManager.default.removeItem(at: pendingURL)
        status = isConnected ? "Live" : "Cloud sync"; notify()
    }
    func seed(_ project: ScrivProject) async throws {
        let all = try CloudCodec.items(from: project)
        for start in stride(from: 0, to: all.count, by: 100) {
            let portion = Array(all[start..<min(all.count,start+100)])
            let operations: [JSONValue] = portion.map { .object(["op":.string("put"),"id":.string($0.id),"kind":.string($0.kind),"data":$0.data,"expectedVersion":.number(0)]) }
            guard let projectId else { throw ScrivError.unavailable("No cloud project is open.") }
            let result: JSONValue = try await request("/v1/projects/\(projectId)/commands", method: "POST", body: .object(["commandId":.string(UUID().uuidString),"sessionId":.string(sessionId),"epoch":.number(Double(epoch)),"label":.string("Import project"),"operations":.array(operations)]))
            if let changed = result["items"]?.array { for value in changed { let item = try value.decoded(CloudItem.self); items[item.id] = item } }
            if let seq = result["seq"]?.int { headSeq = seq }
        }
    }
    func retryPendingCommands() async throws {
        guard let projectId else { return }
        for url in try FileManager.default.contentsOfDirectory(at: pendingDirectory(), includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where url.pathExtension == "json" {
            let saved = try ScrivJSON.decoder.decode(JSONValue.self, from: Data(contentsOf: url))
            guard saved["projectId"]?.string == projectId, let payload = saved["payload"] else { continue }
            let _: JSONValue = try await request("/v1/projects/\(projectId)/commands", method: "POST", body: payload)
            try FileManager.default.removeItem(at: url)
        }
        try await replay()
    }
    private func pendingDirectory() throws -> URL { let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Scriv/Outbox"); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); return directory }
    private func connectSocket() {
        guard let projectId, let token, !stopped else { return }
        var components = URLComponents(url: baseURL.appendingPathComponent("v1/projects/\(projectId)/socket"), resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization"); request.setValue(sessionId, forHTTPHeaderField: "X-Scriv-Device-Id")
        let ws = urlSession.webSocketTask(with: request); socket = ws; ws.resume()
        receiver?.cancel()
        receiver = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await ws.receive(), data: Data
                    switch message { case .data(let value): data = value; case .string(let value): data = Data(value.utf8); @unknown default: continue }
                    if let event = try? ScrivJSON.decoder.decode(JSONValue.self, from: data) { try await self?.handle(event) }
                }
            } catch { guard let self, !self.stopped, !Task.isCancelled else { return }; self.isConnected = false; self.status = "Reconnecting…"; self.notify(); self.scheduleReconnect() }
        }
        startHeartbeat(realtime: true)
    }
    private func scheduleReconnect() {
        reconnect?.cancel(); retryCount += 1
        let delay = min(30.0,pow(2.0,Double(min(retryCount,5)))) + Double.random(in: 0...1)
        reconnect = Task { [weak self] in try? await Task.sleep(for: .seconds(delay)); guard let self, !Task.isCancelled, !self.stopped else { return }; self.connectSocket() }
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
        case "hello": isConnected = true; retryCount = 0; status = "Live"; notify(); try await send(.object(["type":.string("resume"),"after":.number(Double(headSeq))]))
        case "event": if let value = event["event"] { try await consume(try value.decoded(CloudEvent.self)) }
        case "events":
            for value in event["events"]?.array ?? [] { try await consume(try value.decoded(CloudEvent.self)) }
            if event["headSeq"]?.int ?? 0 > headSeq { try await replay() }
        case "watermark": if event["epoch"]?.int != epoch || (event["headSeq"]?.int ?? 0) > headSeq { try await replay() }
        case "presence": peers = try (event["peers"]?.array ?? []).map { try $0.decoded(PresencePeer.self) }; notify()
        case "leases": leases = try (event["leases"]?.array ?? []).map { try $0.decoded(EditLease.self) }; notify()
        case "message": if let value = event["message"] { onMessage?(try value.decoded(DiscussionMessage.self)) }
        case "signal":
            if let from = event["fromDeviceId"]?.string, let type = event["signalType"]?.string, let payload = event["payload"] { onSignal?(PeerSignal(fromDeviceId: from,toDeviceId: sessionId,type: type,payload: payload)) }
        case "error": onError?(ScrivError.unavailable(event["message"]?.string ?? "Live connection error."))
        default: break
        }
    }
    private func consume(_ event: CloudEvent) async throws {
        if event.seq <= headSeq { return }
        guard event.seq == headSeq + 1 else { try await replay(); return }
        if event.epoch != epoch { epoch = event.epoch; heldLeases = [:]; leases = [] }
        for change in event.changes { if let after = change.after { items[change.id] = after } else { items.removeValue(forKey: change.id) } }
        headSeq = event.seq; onItems?(Array(items.values)); onEvent?(event); notify()
    }
    func replay() async throws {
        guard let projectId else { return }
        struct Page: Decodable { var events: [CloudEvent]; var headSeq: Int; var hasMore: Bool }
        for _ in 0..<100 {
            let page: Page = try await request("/v1/projects/\(projectId)/events?after=\(headSeq)&limit=100")
            for event in page.events {
                guard event.seq == headSeq+1 || event.seq <= headSeq else { throw ScrivError.conflict("History has a sequence gap; reopen the cloud project to recover.") }
                if event.seq > headSeq { try await consume(event) }
            }
            if !page.hasMore { return }
        }
    }
    func presence(itemId: String?, selection: JSONValue? = nil, cursor: JSONValue? = nil) {
        guard isConnected, Date().timeIntervalSince(lastPresence) >= 0.2 else { return }; lastPresence = Date()
        var payload: [String:JSONValue] = ["type":.string("presence"),"itemId": itemId.map(JSONValue.string) ?? .null]
        if let selection { payload["selection"] = selection }; if let cursor { payload["cursor"] = cursor }
        Task { try? await send(.object(payload)) }
    }
    func send(_ value: JSONValue) async throws { guard let socket else { throw ScrivError.unavailable("Live connection is not ready.") }; try await socket.send(.data(ScrivJSON.encoder.encode(value))) }
    func signal(_ signal: PeerSignal) async throws {
        guard let projectId else { throw ScrivError.unavailable("Open a cloud project before peer synchronization.") }
        let _: JSONValue = try await request("/v1/projects/\(projectId)/signals", method: "POST", body: try .encoded(signal))
    }
    func thread(itemId: String?) async throws -> DiscussionThread {
        guard let projectId else { throw ScrivError.unavailable("Sync this project to use shared discussions.") }
        struct Response: Decodable { var thread: DiscussionThread }
        let response: Response = try await request("/v1/projects/\(projectId)/threads", method: "POST", body: .object(["itemId":itemId.map(JSONValue.string) ?? .null]))
        return response.thread
    }
    func messages(threadId: String) async throws -> [DiscussionMessage] {
        guard let projectId else { return [] }; struct Response: Decodable { var messages: [DiscussionMessage] }
        let response: Response = try await request("/v1/projects/\(projectId)/threads/\(threadId)/messages"); return response.messages
    }
    func postMessage(threadId: String, text: String) async throws -> DiscussionMessage {
        guard let projectId else { throw ScrivError.unavailable("No cloud project is open.") }; struct Response: Decodable { var message: DiscussionMessage }
        let response: Response = try await request("/v1/projects/\(projectId)/threads/\(threadId)/messages", method: "POST", body: .object(["id":.string(UUID().uuidString),"body":.string(text)])); return response.message
    }
    func resolve(threadId: String, resolved: Bool) async throws -> DiscussionThread {
        guard let projectId else { throw ScrivError.unavailable("No cloud project is open.") }; struct Response: Decodable { var thread: DiscussionThread }
        let response: Response = try await request("/v1/projects/\(projectId)/threads/\(threadId)", method: "PATCH", body: .object(["resolved":.bool(resolved)])); return response.thread
    }
    func history() async throws -> [CloudEvent] {
        guard let projectId else { return [] }; struct Page: Decodable { var events: [CloudEvent]; var hasMore: Bool }
        var output: [CloudEvent] = [], after = 0
        repeat { let page: Page = try await request("/v1/projects/\(projectId)/history?after=\(after)&limit=100"); output += page.events; after = page.events.last?.seq ?? after; if !page.hasMore { break } } while true
        return output.reversed()
    }
    func restore(seq: Int) async throws {
        guard let projectId else { return }
        let _: JSONValue = try await request("/v1/projects/\(projectId)/restore", method: "POST", body: .object(["commandId":.string(UUID().uuidString),"sessionId":.string(sessionId),"epoch":.number(Double(epoch)),"seq":.number(Double(seq))])); try await replay()
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

private extension Data { var base64URLEncoded: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") } }
private enum KeychainToken {
    static let service = "com.scriv.account"
    static func read(account: String) throws -> String? { var result: CFTypeRef?; let status = SecItemCopyMatching([kSecClass:kSecClassGenericPassword,kSecAttrService:service,kSecAttrAccount:account,kSecReturnData:true,kSecMatchLimit:kSecMatchLimitOne] as CFDictionary,&result); if status == errSecItemNotFound { return nil }; guard status == errSecSuccess, let data = result as? Data, let token = String(data:data,encoding:.utf8) else { throw ScrivError.unavailable("Could not read the saved account from Keychain.") }; return token }
    static func write(_ token: String, account: String) throws { try delete(account:account); let status = SecItemAdd([kSecClass:kSecClassGenericPassword,kSecAttrService:service,kSecAttrAccount:account,kSecValueData:Data(token.utf8),kSecAttrAccessible:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary,nil); guard status == errSecSuccess else { throw ScrivError.unavailable("Could not save the account in Keychain.") } }
    static func delete(account: String) throws { let status = SecItemDelete([kSecClass:kSecClassGenericPassword,kSecAttrService:service,kSecAttrAccount:account] as CFDictionary); guard status == errSecSuccess || status == errSecItemNotFound else { throw ScrivError.unavailable("Could not remove the account from Keychain.") } }
}
