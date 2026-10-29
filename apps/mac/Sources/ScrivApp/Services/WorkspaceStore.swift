import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers
import ScrivCore

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published var project: ScrivProject { didSet { synchronizeAudio() } }
    @Published var selectedSceneID: String { didSet { synchronizeAudio() } }
    @Published var selectedEntryID: String?
    @Published var selectedCharacterID: String?
    @Published var selectedCueID: String?
    @Published var selectedWordIDs: Set<String> = []
    @Published var tab: WorkspaceTab = .script
    @Published var playheadMs: Double = 0 { didSet { synchronizeAudio() } }
    @Published var isPlaying = false { didSet { synchronizeAudio() } }
    @Published var followPlayback = true
    @Published var statusMessage = "Saved on this Mac"
    @Published var errorMessage: String?
    @Published var history: [HistoryEntry] = []
    @Published var cloudHistory: [CloudEvent] = [] { didSet { ingestMentionHistory() } }
    @Published var showDiscussion = false
    @Published var discussionItemID: String?
    @Published var messages: [DiscussionMessage] = []
    @Published var activeThread: DiscussionThread?
    @Published var account: CloudUser?
    @Published var teams: [CloudTeam] = []
    @Published var cloudProjects: [CloudProject] = []
    @Published var peers: [PresencePeer] = []
    @Published var leases: [EditLease] = []
    @Published var isSyncing = false
    @Published var syncStatus = "Local only"
    @Published private var generationPromptDrafts: [String:String] = [:]
    var generationPrompt: String {
        get { generationPromptDrafts[generationPromptKey(for:selectedCue?.id ?? currentCue?.id)] ?? "" }
        set { generationPromptDrafts[generationPromptKey(for:selectedCue?.id ?? currentCue?.id)] = newValue }
    }
    private func generationPromptKey(for cueID: String?) -> String {
        let sceneID = project.cues.first { $0.id == cueID }?.sceneId ?? selectedSceneID
        let scope: JSONValue = .array([.string(cloud.baseURL.absoluteString),(account?.id).map(JSONValue.string) ?? .null,.string(project.id),(projectURL?.path).map(JSONValue.string) ?? .null,.string(sceneID),cueID.map(JSONValue.string) ?? .null])
        return ScrivDigest.sha256((try? ScrivJSON.encoder.encode(scope)) ?? Data())
    }
    @Published var projectURL: URL? { didSet { synchronizeAudio() } }
    @Published var lastJoinLink: String?
    @Published var hasConflicts = false
    @Published var teamDetails: JSONValue?
    @Published var localProjects: [URL] = []
    @Published var discussionReplyToID: String?
    @Published var discussionAttachments: [JSONValue] = []
    @Published var discussionFocusedMessageID: String?
    @Published var discussionLoading = false
    @Published var isSendingDiscussion = false
    @Published var discussionMembers: [DiscussionMember] = []
    @Published var discussionMembersLoading = false
    @Published var discussionMembersError: String?
    @Published private var discussionMentionDrafts: [String:[DiscussionMember]] = [:]
    @Published private var mentionMessages: [DiscussionMessage] = []
    @Published private var readMentionIDs: Set<String> = []
    @Published private var discussionDrafts: [String:String] = [:]
    var discussionDraftKey: String { DiscussionState.draftKey(server:cloud.baseURL.absoluteString,account:account?.id,project:project.id,item:discussionItemID) }
    var discussionDraft: String { get { discussionDrafts[discussionDraftKey] ?? "" } set { discussionDrafts[discussionDraftKey] = newValue } }
    var discussionMentionedUserIDs: [String] { (discussionMentionDrafts[discussionDraftKey] ?? []).map(\.id) }
    var discussionMentions: [DiscussionMessage] { mentionMessages }
    var unreadDiscussionMentionCount: Int { mentionMessages.filter { !readMentionIDs.contains($0.id) }.count }
    var discussionThreads: [DiscussionThread] { cloud.threads.values.sorted { ($0.createdAt ?? 0,$0.id) > ($1.createdAt ?? 0,$1.id) } }
    @Published var peerTransferStatus = "Peer transfer stopped"
    @Published var audioStatus = "Local audio — import speech or sound to hear playback"
    private let localAudio = LocalAudioEngine()
    private var lastAudioVolumes: [String:Double] = [:]
    let peerMedia = PeerMediaBridge()
    let codex = CodexController()
    let cloud = CloudClient()
    private var repository: ProjectRepository?
    private var generationMonitor: Task<Void,Never>?
    private var generationMirrorTask: Task<Void,Never>?
    private var generationAttachmentIDs: Set<String> = []
    private var generationCompletionIDs: Set<String> = []
    private var generationAttachmentHeartbeats: [String:Task<Void,Never>] = [:]
    private var sharedJobRefreshGeneration = 0
    private var playbackTask: Task<Void,Never>?
    private var playbackClock = PlaybackPositionClock()
    private var saveTask: Task<Void,Never>?
    private var commitTask: Task<Void,Never>?
    private var dirtyItems: [String:Int] = [:]
    private var canonicalCheckpoint: CloudCheckpoint?
    private let cloudCommitBarrier = CloudCommitBarrier()
    private var pauseRemoteUpdates = false { didSet { cloudCommitBarrier.setPaused(pauseRemoteUpdates) } }
    private var isProjectSynchronizing = false
    private var undoStack: [ScrivProject] = []
    private var redoStack: [ScrivProject] = []
    private var editingIDs: Set<String> = []
    private var rootURL: URL
    private let verificationMode = ProcessInfo.processInfo.arguments.contains("--screenshots") || ProcessInfo.processInfo.arguments.contains("--peer-smoke")
    private var bootstrapTask: Task<Void, Never>?
    private var peerTask: Task<Void, Never>?
    private var peerProjectId: String?
    private struct LocalAssetStamp: Equatable { let modified: Date; let size: Int; let hash: String }
    private var checkedLocalAssets: [String:LocalAssetStamp] = [:]
    private var pendingLocalAssetChecks: [String:String] = [:]
    private var invalidLocalAssetPaths: Set<String> = []
    private var mediaRequests: [String:String] = [:]
    private var peerConfigurationGeneration = 0
    private var peerDiscoveries: [String:PeerAssetDiscovery] = [:]
    private var peerTransferStarted: Set<String> = []
    private var automaticMediaAttempts: Set<String> = []
    private var pendingMessageIDs: [String:String] = [:]
    private var navigationGeneration = 0
    private var discussionGeneration = 0
    private var memberRequestGeneration = 0
    private var mentionHistoryRequestGeneration = 0
    private var mentionScope = ""
    private var cancellables = Set<AnyCancellable>()
    var onProjectChanged: ((ScrivProject, URL?) -> Void)?
    var sceneEntries: [ScriptEntry] { project.entries(in: selectedSceneID) }
    var sceneCues: [ImageCue] { project.cues(in: selectedSceneID) }
    var sceneDurationMs: Int { project.durationMs(of: selectedSceneID) }
    var selectedEntry: ScriptEntry? { project.entries.first { $0.id == selectedEntryID } }
    var selectedCue: ImageCue? { project.cues.first { $0.id == selectedCueID } }
    var selectedCharacter: ScriptCharacter? { project.characters.first { $0.id == selectedCharacterID } }
    var currentCue: ImageCue? { project.activeCue(at: Int(playheadMs), sceneId: selectedSceneID) }
    var currentWordID: String? { TimingEngine.absoluteWords(project,sceneId:selectedSceneID).first { Int(playheadMs) >= $0.startMs && Int(playheadMs) < $0.endMs }?.id }
    var cloudBaseURL: String { get { cloud.baseURL.absoluteString } set { if let url = URL(string:newValue), CloudClient.validEndpoint(url) { cloud.baseURL = url; objectWillChange.send() } else { errorMessage = "Use HTTPS for the Scriv server, or localhost for development." } } }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    init() {
        let example = ScrivProject.example()
        project = example; selectedSceneID = example.scenes[0].id; selectedEntryID = example.entries.first?.id; selectedCueID = example.cues.first?.id
        if verificationMode {
            let output = ProcessInfo.processInfo.environment["SCRIV_VERIFICATION_ROOT"].map { URL(fileURLWithPath:$0,isDirectory:true) } ?? FileManager.default.temporaryDirectory.appendingPathComponent("ScrivVerification-" + UUID().uuidString,isDirectory:true)
            rootURL = output.appendingPathComponent("Projects",isDirectory:true)
        } else { rootURL = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Scriv/Projects") }
        do { repository = try ProjectRepository(root:rootURL) } catch { errorMessage = "Local project storage could not open: \(error.localizedDescription)" }
        projectURL = rootURL.appendingPathComponent(example.id).appendingPathExtension("scriv")
        localAudio.onError = { [weak self] message in self?.audioStatus = message }
        cloud.onState = { [weak self] in self?.readCloudState() }
        cloud.onItems = { [weak self] items in self?.applyRemote(items) }
        cloud.onError = { [weak self] error in self?.errorMessage = error.localizedDescription }
        cloud.onMessage = { [weak self] message in self?.receiveDiscussionMessage(message) }
        cloud.onDiscussionRefresh = { [weak self] in self?.refreshDiscussion(); self?.refreshMentionHistory(); self?.refreshSharedGenerationJobs() }
        cloud.onThread = { [weak self] thread in guard let self else { return }; if thread.id == self.activeThread?.id { self.activeThread = thread }; self.objectWillChange.send() }
        cloud.onEvent = { [weak self] event in guard let self, self.project.cloudProjectId == self.cloud.projectId else { return }; if !self.cloudHistory.contains(where: { $0.seq == event.seq }) { self.cloudHistory.insert(event,at:0) } }
        codex.onChange = { [weak self] in self?.objectWillChange.send() }
        codex.onJobChange = { [weak self] job in self?.queueGenerationMirror(job) }
        codex.onRefreshSharedJobs = { [weak self] in self?.refreshSharedGenerationJobs() }
        codex.onRecoverJob = { [weak self] job in self?.recoverGenerationJob(job) }
        codex.onRetryJob = { [weak self] job in self?.retryGenerationJob(job) }
        peerMedia.onSignal = { [weak self] signal in
            guard let self else { return }; let projectID = self.cloud.projectId, generation = self.peerConfigurationGeneration
            Task { do { guard projectID == self.cloud.projectId, generation == self.peerConfigurationGeneration else { return }; try await self.cloud.signal(signal) } catch { self.errorMessage = error.localizedDescription } }
        }
        cloud.onSignal = { [weak self] signal in
            guard let self else { return }
            let projectID = self.cloud.projectId, generation = self.peerConfigurationGeneration
            Task {
                await self.peerTask?.value
                guard self.cloud.projectId == projectID, self.peerConfigurationGeneration == generation else { return }
                do {
                    if PeerMediaBridge.isTransportSignal(signal) { try await self.peerMedia.handleSignal(signal) }
                    else if signal.type == "asset-request" { try await self.handleAssetDiscovery(signal) }
                } catch { self.peerTransferStatus = error.localizedDescription }
            }
        }
        peerMedia.onAsset = { [weak self] hash, data in self?.receivedPeerAsset(hash:hash,data:data) }
        peerMedia.onTransferError = { [weak self] peer, hash, error in self?.peerTransferFailed(peer:peer,hash:hash,error:error) }
        peerMedia.onError = { [weak self] error in self?.peerTransferStatus = error.localizedDescription }
        peerMedia.$status.sink { [weak self] value in self?.peerTransferStatus = value }.store(in:&cancellables)
        bootstrapTask = Task { [weak self] in await self?.bootstrap() }
        if !verificationMode {
            generationMonitor = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for:.seconds(30))
                    guard let self, !Task.isCancelled else { return }
                    self.refreshSharedGenerationJobs()
                    for job in self.codex.jobs {
                        if self.generationAttachmentIDs.contains(job.id) { self.heartbeatGenerationAttachment(job) }
                        else if job.status == .running || job.status == .queued { self.queueGenerationMirror(job) }
                    }
                }
            }
        }
    }
    private func repo() throws -> ProjectRepository { guard let repository else { throw ScrivError.unavailable("Local project storage is unavailable. Check folder permissions.") }; return repository }
    private func bootstrap() async {
        if verificationMode { return }
        if let path = UserDefaults.standard.string(forKey:"lastProjectURL"), FileManager.default.fileExists(atPath:path) {
            do { try await open(URL(fileURLWithPath:path)) } catch { errorMessage = "The last project could not open: \(error.localizedDescription)" }
        } else { saveProject() }
        if project.images.isEmpty && project.scenes.contains(where: { $0.id == "scene-farm" }) { do { try await installSampleImages() } catch { errorMessage = error.localizedDescription } }
        await cloud.restoreSession()
        if project.cloudProjectId != nil, account != nil { syncProject() }
        refreshLocalProjects()
    }
    private func readCloudState() {
        if account?.id != cloud.account?.id {
            discussionGeneration += 1; activeThread = nil; messages = []; cloudHistory = []; discussionReplyToID = nil; discussionAttachments = []; discussionLoading = false
        }
        account = cloud.account; updateMentionScope(); teams = cloud.teams; cloudProjects = cloud.projects; peers = cloud.peers; leases = cloud.leases; syncStatus = cloud.status
        if project.cloudProjectId != cloud.projectId || account == nil { codex.sharedJobs = [] }
        if peerProjectId != cloud.projectId { configurePeers() }
    }
    @discardableResult
    private func change(_ label: String, _ mutate: (inout ScrivProject) throws -> Void) -> Bool {
        do {
            let before = project
            var next = before
            try mutate(&next); try TimingEngine.validate(next)
            guard next != before else { return false }
            let old = Dictionary(uniqueKeysWithValues:try CloudCodec.items(from:before).map { ($0.id,$0.data) })
            let new = Dictionary(uniqueKeysWithValues:try CloudCodec.items(from:next).map { ($0.id,$0.data) })
            let ids = Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }
            for id in ids { if let editor = lockedByOther(id) { throw ScrivError.conflict("\(editor) is editing this item. Wait for their lease to finish before changing it.") } }
            next.revision = before.revision + 1; next.modifiedAt = ScrivClock.now
            undoStack.append(before); redoStack = []
            project = next
            let event = HistoryEntry(label:label,snapshot:next); history.insert(event,at:0)
            queueSave(next,label:label)
            if next.cloudProjectId != nil {
                for id in ids { dirtyItems[id] = next.revision }
                enqueueCommit(before:before,after:next,label:label,changed:ids)
            }
            reconcileSelection()
            refreshPeerAuthorization()
            onProjectChanged?(project,projectURL)
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    private func queueSave(_ snapshot: ScrivProject, label: String) {
        guard let package = projectURL else { errorMessage = "Choose a project location before saving."; return }
        if project.id == snapshot.id, !history.contains(where: { $0.revision == snapshot.revision }) { history.insert(HistoryEntry(label:label,snapshot:snapshot),at:0) }
        let previous = saveTask
        statusMessage = "Saving…"
        saveTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do { try await self.repo().save(snapshot,at:package,label:label); if self.project.id == snapshot.id && self.project.revision == snapshot.revision { self.statusMessage = "Saved on this Mac" }; if !self.verificationMode { UserDefaults.standard.set(package.path,forKey:"lastProjectURL") } }
            catch { self.errorMessage = "Could not save your project: \(error.localizedDescription)"; self.statusMessage = "Save failed" }
        }
    }
    private func enqueueCommit(before: ScrivProject, after: ScrivProject, label: String, changed: Set<String>) {
        let previous = commitTask, navigation = navigationGeneration
        commitTask = Task { [weak self] in
            await previous?.value
            guard let self, self.navigationGeneration == navigation, self.project.id == after.id else { return }
            await self.cloudCommitBarrier.waitUntilReady()
            guard self.navigationGeneration == navigation, self.project.id == after.id else { return }
            self.isSyncing = true
            do {
                try await self.cloud.commit(before:before,after:after,label:label)
                guard self.navigationGeneration == navigation, self.project.id == after.id else { return }
                for id in changed where self.dirtyItems[id] == after.revision { self.dirtyItems.removeValue(forKey:id) }
                self.hasConflicts = !self.dirtyItems.isEmpty
                self.recordCheckpoint()
                for id in changed where !self.editingIDs.contains(id) { await self.cloud.releaseLease(id) }
            } catch { guard self.navigationGeneration == navigation, self.project.id == after.id else { return }; self.errorMessage = error.localizedDescription; self.hasConflicts = true; self.syncStatus = "Draft saved locally — needs review" }
            if self.navigationGeneration == navigation, self.project.id == after.id { self.isSyncing = self.isProjectSynchronizing }
        }
    }
    private func applyRemote(_ items: [CloudItem]) {
        guard !pauseRemoteUpdates, project.cloudProjectId == cloud.projectId, cloud.projectId != nil else { return }
        do {
            let merged: [CloudItem]
            if let checkpoint = validCheckpoint() { merged = try CloudReconciliation.merge(base:checkpoint.items,local:CloudCodec.items(from:project),remote:items) }
            else { guard dirtyItems.isEmpty else { throw ScrivError.conflict("A local draft needs reconciliation before applying live updates.") }; merged = items }
            let next = try CloudCodec.applying(merged,to:project)
            if next != project { var revised = next; revised.revision = project.revision+1; revised.modifiedAt = ScrivClock.now; project = revised; queueSave(revised,label:"Live update"); reconcileSelection(); refreshPeerAuthorization(); onProjectChanged?(project,projectURL) }
            recordCheckpoint()
            fetchMissingImages()
        } catch { hasConflicts = true; errorMessage = "The incoming project could not be applied safely: \(error.localizedDescription)" }
    }
    private func validCheckpoint() -> CloudCheckpoint? {
        guard let checkpoint = canonicalCheckpoint, checkpoint.projectId == project.cloudProjectId,
              checkpoint.serverURL == cloud.baseURL.absoluteString, checkpoint.accountId == cloud.account?.id else { return nil }
        return checkpoint
    }
    private func recordCheckpoint() {
        guard let cloudID = cloud.projectId, project.cloudProjectId == cloudID, let accountID = cloud.account?.id, let package = projectURL else { return }
        let checkpoint = CloudCheckpoint(projectId:cloudID,serverURL:cloud.baseURL.absoluteString,accountId:accountID,epoch:cloud.epoch,headSeq:cloud.headSeq,timingVersion:cloud.timingVersion,items:Array(cloud.items.values))
        canonicalCheckpoint = checkpoint
        let previous = saveTask
        saveTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do { try await self.repo().saveCheckpoint(checkpoint,at:package) }
            catch { self.errorMessage = "Cloud checkpoint could not be saved: " + error.localizedDescription }
        }
    }
    var navigationContext: Int { navigationGeneration }
    func beginEdit(_ id: String) async -> Bool {
        let context = navigationGeneration
        do {
            _ = try await cloud.acquireLease(id)
            guard navigationGeneration == context else { return false }
            editingIDs.insert(id); cloud.presence(itemId:id); return true
        } catch is CancellationError { return false }
        catch { if navigationGeneration == context { errorMessage = error.localizedDescription }; return false }
    }
    func endEdit(_ id: String, context: Int? = nil) {
        guard context == nil || context == navigationGeneration else { return }
        editingIDs.remove(id); let pending = commitTask, navigation = navigationGeneration
        Task { [weak self] in await pending?.value; guard let self, self.navigationGeneration == navigation else { return }; await self.cloud.releaseLease(id) }
    }
    func lockedByOther(_ itemId: String) -> String? { leases.first { $0.itemId == itemId && $0.sessionId != cloud.sessionId && $0.expiresAt > Int(Date().timeIntervalSince1970*1000) }.map { $0.name ?? "Another editor" } }
    func commitText(_ id: String, text: String) { change("Edit script") { try TimingEngine.updateText(&$0,entryId:id,text:text) } }
    func setDuration(_ id: String, seconds: Double) { guard seconds.isFinite, seconds >= 0, seconds <= 3600 else { errorMessage = "Duration must be between zero and one hour."; return }; change("Change duration") { try TimingEngine.setOwnedDuration(&$0,entryId:id,durationMs:Int((seconds*1000).rounded())) } }
    func setCoverage(_ id: String, endMs: Int) { change("Extend direction") { try TimingEngine.setCoverage(&$0,entryId:id,endMs:endMs) } }
    func selectEntry(_ id: String) { if let entry = project.entries.first(where: { $0.id == id }) { selectedSceneID = entry.sceneId; seek(toMs:Double(project.startMs(of:id))); selectedEntryID = id; cloud.presence(itemId:id) } }
    func selectCharacter(_ id: String) { selectedCharacterID = id; tab = .characters; cloud.presence(itemId:id) }
    func setEntryCharacter(_ id: String, characterId: String?) { change("Change speaker") { p in if let i = p.entries.firstIndex(where: { $0.id == id }) { p.entries[i].characterId = characterId } } }
    func updatePresence(itemId: String?, selectionStart: Int, selectionEnd: Int) { cloud.presence(itemId:itemId,selection:.object(["start":.number(Double(selectionStart)),"end":.number(Double(selectionEnd))])) }
    func seek(toMs: Double) {
        guard toMs.isFinite else { return }
        let target = min(max(0,toMs),Double(sceneDurationMs))
        playbackClock.seek(toMs:target,nowMs:ProcessInfo.processInfo.systemUptime * 1000)
        updatePlayhead(toMs:target)
    }
    private func updatePlayhead(toMs: Double) {
        guard toMs.isFinite else { return }; playheadMs = min(max(0,toMs),Double(sceneDurationMs))
        selectedCueID = project.activeCue(at:Int(playheadMs),sceneId:selectedSceneID)?.id ?? (Int(playheadMs) == sceneDurationMs ? sceneCues.last?.id : nil)
        if followPlayback, let entry = project.activeEntry(at:Int(playheadMs),sceneId:selectedSceneID) { selectedEntryID = entry.id }
    }
    func togglePlayback() {
        if isPlaying { updatePlayhead(toMs:playbackClock.pause(nowMs:ProcessInfo.processInfo.systemUptime * 1000,durationMs:sceneDurationMs)); isPlaying = false; playbackTask?.cancel(); return }
        if playheadMs >= Double(sceneDurationMs) { playheadMs = 0 }
        guard sceneDurationMs > 0 else { return }
        isPlaying = true
        playbackClock.start(fromMs:playheadMs,nowMs:ProcessInfo.processInfo.systemUptime * 1000)
        playbackTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isPlaying else { return }
                self.updatePlayhead(toMs:self.playbackClock.position(nowMs:ProcessInfo.processInfo.systemUptime * 1000,durationMs:self.sceneDurationMs))
                if self.playheadMs >= Double(self.sceneDurationMs) { self.isPlaying = false; return }
                try? await Task.sleep(for:.milliseconds(16))
            }
        }
    }
    func addEntry(kind: EntryKind) {
        let entry = ScriptEntry(sceneId:selectedSceneID,order:0,kind:kind,text:kind == .direction ? "Direction" : "New line",characterId:kind == .dialogue ? project.characters.first?.id : nil,ownedDurationMs:kind == .direction ? 0 : 3000,coverageDurationMs:kind == .direction ? 3000 : 0)
        let after = sceneEntries.contains(where: { $0.id == selectedEntryID }) ? selectedEntryID : nil
        if change(kind == .direction ? "Add direction" : "Add dialogue", { try ProjectEditing.insertEntry(&$0,entry:entry,after:after) }) { selectedEntryID = entry.id }
    }
    func deleteEntry(_ id: String) { change("Delete line") { try ProjectEditing.deleteEntry(&$0,entryId:id) } }
    func moveEntry(_ id: String, offset: Int) { change("Move line") { try ProjectEditing.moveEntry(&$0,entryId:id,offset:offset) } }
    func selectScene(_ id: String) {
        guard project.scenes.contains(where: { $0.id == id }) else { return }
        finishEditing(); isPlaying = false; playbackTask?.cancel()
        selectedSceneID = id; selectedEntryID = sceneEntries.first?.id; selectedWordIDs = []
        seek(toMs:0)
    }
    private func reconcileSelection() {
        if !project.scenes.contains(where: { $0.id == selectedSceneID }) { selectedSceneID = project.orderedScenes.first?.id ?? ""; playheadMs = 0 }
        playheadMs = min(max(0,playheadMs),Double(sceneDurationMs))
        if !sceneEntries.contains(where: { $0.id == selectedEntryID }) { selectedEntryID = project.activeEntry(at:Int(playheadMs),sceneId:selectedSceneID)?.id ?? sceneEntries.first?.id }
        if !sceneCues.contains(where: { $0.id == selectedCueID }) { selectedCueID = project.activeCue(at:Int(playheadMs),sceneId:selectedSceneID)?.id ?? (Int(playheadMs) == sceneDurationMs ? sceneCues.last?.id : sceneCues.first?.id) }
        if !project.characters.contains(where: { $0.id == selectedCharacterID }) { selectedCharacterID = project.characters.first?.id }
        selectedWordIDs.formIntersection(Set(sceneEntries.flatMap { $0.words.map(\.id) }))
        playheadMs = min(max(0,playheadMs),Double(sceneDurationMs))
        if sceneDurationMs == 0 { isPlaying = false; playbackTask?.cancel() }
    }
    func deleteScene(_ id: String) { finishEditing(); change("Delete scene") { try ProjectEditing.deleteScene(&$0,sceneId:id) } }
    func addScene() {
        let scene = ScriptScene(title:"INT. NEW SCENE — DAY",order:(project.orderedScenes.last?.order ?? -1)+1)
        if change("Add scene", { $0.scenes.append(scene) }) { selectScene(scene.id) }
    }
    func updateSceneTitle(_ title: String) { change("Rename scene") { p in if let index = p.scenes.firstIndex(where: { $0.id == selectedSceneID }) { p.scenes[index].title = title } } }
    func setProjectTitle(_ title: String) { let clean = title.trimmingCharacters(in:.whitespacesAndNewlines); guard !clean.isEmpty else { return }; change("Rename project") { $0.title = clean }; if project.cloudProjectId != nil { perform { try await self.cloud.renameProject(clean) } } }
    func splitCue(_ id: String) { change("Split image") { try TimingEngine.splitCue(&$0,cueId:id,atMs:Int(playheadMs)) } }
    func moveBoundary(leftId: String, rightId: String, toMs: Int) { change("Move image cut") { try TimingEngine.moveBoundary(&$0,leftCueId:leftId,rightCueId:rightId,toMs:toMs) } }
    func moveWords(_ wordIds: Set<String>, fromCueId: String, toCueId: String) { if change("Move words to image", { try TimingEngine.moveWords(&$0,wordIds:wordIds,fromCueId:fromCueId,toCueId:toCueId) }) { selectedWordIDs = []; selectedCueID = toCueId } }
    func addCue(atMs: Int? = nil) {
        var created: String?
        if change("Add image cue", { created = try ProjectEditing.addCue(&$0,sceneId:selectedSceneID,atMs:atMs ?? Int(playheadMs)) }) { selectedCueID = created }
    }
    func deleteCue(_ id: String) { change("Delete image cue") { try ProjectEditing.deleteCue(&$0,cueId:id) } }
    func mergeCue(_ id: String, with nextId: String) { if change("Merge image cues", { try ProjectEditing.mergeCues(&$0,leftCueId:id,rightCueId:nextId) }) { selectedCueID = id } }
    func setCueImage(_ id: String, imageId: String?) { change("Select image version") { try ProjectEditing.setCueImage(&$0,cueId:id,imageId:imageId) } }
    func setCharacterPortrait(_ id: String, imageId: String?) { change("Change portrait") { try ProjectEditing.setPortrait(&$0,characterId:id,imageId:imageId) } }
    func updateCuePrompt(_ id: String, prompt: String) { change("Edit image direction") { p in if let index = p.cues.firstIndex(where: { $0.id == id }) { p.cues[index].prompt = prompt } } }
    func addCharacter() { let character = ScriptCharacter(name:"New character"); if change("Add character", { $0.characters.append(character) }) { selectedCharacterID = character.id } }
    func updateCharacter(_ character: ScriptCharacter) { change("Edit character") { p in if let i = p.characters.firstIndex(where: { $0.id == character.id }) { p.characters[i] = character } } }
    func deleteCharacter(_ id: String) { change("Delete character") { p in p.characters.removeAll { $0.id == id }; for i in p.entries.indices where p.entries[i].characterId == id { p.entries[i].characterId = nil }; for i in p.images.indices { p.images[i].characterIds.removeAll { $0 == id } } }; if selectedCharacterID == id { selectedCharacterID = project.characters.first?.id } }
    func setCharacterTags(imageId: String, characterIds: [String]) { change("Tag characters") { p in if let index = p.images.firstIndex(where: { $0.id == imageId }) { p.images[index].characterIds = Array(Set(characterIds)).sorted() } } }
    func assetURL(_ asset: ImageAsset) -> URL? {
        guard let url = rawAssetURL(asset), !invalidLocalAssetPaths.contains(url.path) else { return nil }; return url
    }
    private func rawAssetURL(_ asset: ImageAsset) -> URL? {
        guard let projectURL, asset.fileName == URL(fileURLWithPath:asset.fileName).lastPathComponent, !asset.fileName.contains("..") else { return nil }
        let package = projectURL.resolvingSymlinksInPath().standardizedFileURL
        let expectedDirectory = package.appendingPathComponent("assets"), directory = expectedDirectory.resolvingSymlinksInPath(), url = directory.appendingPathComponent(asset.fileName).resolvingSymlinksInPath()
        guard directory == expectedDirectory, url.deletingLastPathComponent() == directory, let values = try? url.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey]), values.isRegularFile == true, values.fileSize == asset.byteCount else { return nil }; return url
    }
    private func synchronizeAudio() {
        localAudio.synchronize(project:project,sceneId:selectedSceneID,playheadMs:Int(playheadMs),isPlaying:isPlaying,package:projectURL)
    }
    func audioURL(_ asset: AudioAsset) -> URL? {
        guard let package = projectURL, let url = try? AudioFileStore.url(asset:asset,package:package), FileManager.default.fileExists(atPath:url.path) else { return nil }
        return url
    }
    func importAudio(entryId: String? = nil) {
        guard let package = projectURL, project.scenes.contains(where: { $0.id == selectedSceneID }) else { errorMessage = "Create and save a scene before importing audio."; return }
        guard sceneDurationMs > 0 else { errorMessage = "Add a timed line before attaching audio to this scene."; return }
        if let entryId, !sceneEntries.contains(where: { $0.id == entryId }) { errorMessage = "Select a line in this scene before importing its audio."; return }
        let intendedStart = entryId.map { project.startMs(of:$0) } ?? Int(playheadMs)
        guard intendedStart < sceneDurationMs else { errorMessage = "Move the playhead before the scene end, or extend the scene, before importing audio."; return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        let navigation = navigationGeneration, scene = selectedSceneID, position = Int(playheadMs)
        let target = entryId.flatMap { id in project.entries.first { $0.id == id && $0.sceneId == scene }?.id }
        audioStatus = "Importing and measuring audio…"
        perform {
            defer { if self.navigationGeneration == navigation, self.audioStatus == "Importing and measuring audio…" { self.audioStatus = "Audio import did not complete — existing project audio is unchanged" } }
            let asset: AudioAsset
            do { asset = try await LocalAudioImporter.importFile(at:source,into:package) }
            catch { if self.navigationGeneration == navigation { self.audioStatus = "Audio import failed: " + error.localizedDescription }; throw error }
            guard self.navigationGeneration == navigation, self.projectURL == package, self.project.scenes.contains(where: { $0.id == scene }) else { return }
            if let target, !self.project.entries.contains(where: { $0.id == target && $0.sceneId == scene }) { throw ScrivError.conflict("The selected line was removed while importing audio. Import again into the current scene.") }
            let start = target == nil ? position : 0
            let absoluteStart = target.map { self.project.startMs(of:$0) } ?? start
            let available = self.project.durationMs(of:scene) - absoluteStart
            guard available > 0 else { throw ScrivError.conflict("The scene became shorter while importing. Extend it or choose an earlier position and import again.") }
            let clip = AudioClip(sceneId:scene,entryId:target,assetId:asset.id,startMs:start,durationMs:min(asset.durationMs,available))
            if self.change("Import local audio", { p in p.audioAssets.append(asset); p.audioClips.append(clip) }) { self.audioStatus = "Audio saved in this project package — not uploaded to cloud" }
        }
    }
    private var audioVolumeScope: String { project.id + "|" + (projectURL?.path ?? "") }
    func setAudioVolume(_ value: Double) {
        guard value.isFinite else { return }
        let volume = min(1,max(0,value))
        if volume > 0 { lastAudioVolumes[audioVolumeScope] = volume }
        else if project.audioVolume > 0 { lastAudioVolumes[audioVolumeScope] = project.audioVolume }
        change("Change audio volume") { $0.audioVolume = volume }
    }
    func toggleAudioMute() { setAudioVolume(project.audioVolume > 0 ? 0 : lastAudioVolumes[audioVolumeScope] ?? 1) }
    func updateAudioClip(_ clip: AudioClip) { change("Edit local audio clip") { p in guard let index = p.audioClips.firstIndex(where: { $0.id == clip.id }) else { throw ScrivError.invalid("This audio clip no longer exists.") }; p.audioClips[index] = clip } }
    func deleteAudioClip(_ id: String) { change("Remove local audio clip") { $0.audioClips.removeAll { $0.id == id } } }
    func importImage(cueId: String? = nil) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png,.jpeg,UTType(filenameExtension:"webp") ?? .image]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let target = cueId ?? selectedCueID ?? currentCue?.id, context = navigationGeneration
        perform { guard self.navigationGeneration == context else { return }; try await self.attachImage(url:url,cueId:target,prompt:"Imported image",expectedCue:nil) }
    }
    @discardableResult
    private func attachImage(url: URL, cueId: String?, prompt: String, expectedCue: ImageCue?, expectedRevision: Int? = nil) async throws -> String? {
        guard let package = projectURL else { throw ScrivError.unavailable("Save this project before importing images.") }
        let sourceProjectID = project.id, navigation = navigationGeneration
        let attributes = try url.resourceValues(forKeys:[.fileSizeKey]); guard (attributes.fileSize ?? 0) <= 25*1024*1024 else { throw ScrivError.invalid("Choose an image smaller than 25 MiB.") }
        let data = try Data(contentsOf:url)
        guard NSImage(data:data) != nil else { throw ScrivError.invalid("The image file could not be decoded.") }
        let asset = try await repo().importAsset(data:data,at:package,prompt:prompt)
        guard project.id == sourceProjectID, navigationGeneration == navigation, projectURL == package else { return nil }
        var stale = false
        if let expectedCue { stale = project.cues.first(where: { $0.id == expectedCue.id }) != expectedCue }
        if let expectedRevision, project.revision != expectedRevision { stale = true }
        if let cueId, lockedByOther(cueId) != nil { stale = true }
        let accepted = change(stale ? "Keep generated candidate" : "Attach image") { p in
            var version = asset
            let predecessor: String?
            if let expectedCue { predecessor = expectedCue.imageId }
            else { predecessor = p.cues.first(where: { $0.id == cueId })?.imageId }
            if let previous = p.asset(predecessor) { version.version = previous.version+1; version.previousVersionId = previous.id; version.characterIds = previous.characterIds }
            if let cueId, let index = p.cues.firstIndex(where: { $0.id == cueId }), !stale { p.cues[index].imageId = version.id }
            p.images.append(version)
        }
        guard accepted else { throw ScrivError.conflict("The image file is retained locally, but its attachment could not be accepted. Retry after the editing lease ends.") }
        if stale { statusMessage = "Generated image kept in project images; the scene changed during generation." }
        if let cloudId = project.cloudProjectId, cloudProjects.first(where: { $0.id == cloudId })?.teamId != nil {
            await commitTask?.value
            guard project.id == sourceProjectID, navigationGeneration == navigation, projectURL == package, cloud.projectId == cloudId else { return asset.id }
            do { try await cloud.upload(project.asset(asset.id) ?? asset,data:data) } catch { errorMessage = "Image is saved locally; cloud upload failed: \(error.localizedDescription)" }
        }
        return asset.id
    }
    func generateImage(cueId: String? = nil) {
        let target = project.cues.first { $0.id == (cueId ?? selectedCueID) } ?? currentCue
        guard let target else { errorMessage = "Add a timed image cue before generating."; return }
        let draft = generationPromptDrafts[generationPromptKey(for:target.id)] ?? ""
        let prompt = draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? target.prompt : draft
        guard let package = projectURL else { errorMessage = "Save this project before generating."; return }
        let context = GenerationJobContext(projectID:project.id,projectTitle:project.title,packagePath:package.path,targetCue:target,sourceRevision:project.revision,cloudProjectID:project.cloudProjectId,cloudServer:project.cloudProjectId == nil ? nil : cloud.baseURL.absoluteString,accountID:account?.id,deviceID:cloud.deviceId,sourceHeadSeq:cloud.headSeq,sourceItemVersion:cloud.items[target.id]?.version)
        let relevantIDs = Set(project.asset(target.imageId)?.characterIds ?? [])
        let orderedCharacters = project.characters.sorted { relevantIDs.contains($0.id) && !relevantIDs.contains($1.id) }
        var referenceURLs: [URL] = [], referenceHashes: Set<String> = []
        for character in orderedCharacters {
            if let asset = project.asset(character.portraitImageId), let url = assetURL(asset), referenceHashes.insert(asset.sha256).inserted { referenceURLs.append(url) }
            if referenceURLs.count == 5 { break }
        }
        perform { try await self.runGeneration(prompt:prompt,references:referenceURLs,context:context) }
    }
    private func generationContextMatches(_ context: GenerationJobContext) -> Bool {
        project.id == context.projectID && projectURL?.standardizedFileURL.path == URL(fileURLWithPath:context.packagePath).standardizedFileURL.path &&
        (context.cloudProjectID == nil || (project.cloudProjectId == context.cloudProjectID && cloud.baseURL.absoluteString == context.cloudServer && account?.id == context.accountID))
    }
    private func runGeneration(prompt: String, references: [URL], context: GenerationJobContext, retryOf: String? = nil) async throws {
        guard generationContextMatches(context) else { throw ScrivError.conflict("Open the original project package before starting this generation.") }
        let navigation = navigationGeneration, jobID = UUID().uuidString.lowercased()
        var context = context; context.deviceID = cloud.deviceId
        let shared = await prepareSharedGeneration(id:jobID,context:context)
        guard navigation == navigationGeneration, generationContextMatches(context) else {
            if let shared, let cloudID = context.cloudProjectID { _ = try? await cloud.updateGenerationJob(id:jobID,expectedVersion:shared.version,status:.cancelled,progressText:"Cancelled before local generation started",projectID:cloudID) }
            throw CancellationError()
        }
        let result: URL
        do { result = try await codex.generate(prompt:prompt,references:references,context:context,jobID:jobID,retryOf:retryOf) }
        catch {
            if let job = codex.jobs.first(where: { $0.id == jobID }) { queueGenerationMirror(job) }
            else if let shared, let cloudID = context.cloudProjectID { _ = try? await cloud.updateGenerationJob(id:jobID,expectedVersion:shared.version,status:.failed,progressText:"Local generation did not start",errorCode:"local_start_failed",projectID:cloudID) }
            throw error
        }
        guard navigation == navigationGeneration, generationContextMatches(context) else {
            statusMessage = "Image ready in Generation history. Open its original project to recover it."
            if let job = codex.jobs.first(where: { $0.id == jobID }) { queueGenerationMirror(job,waiting:true) }
            return
        }
        await generationMirrorTask?.value
        guard await renewGenerationAttachmentClaim(id:jobID,context:context), navigation == navigationGeneration, generationContextMatches(context) else {
            statusMessage = "Image saved in Generation history. Its shared ownership needs explicit recovery before attaching."; return
        }
        generationAttachmentIDs.insert(jobID)
        defer { generationAttachmentIDs.remove(jobID) }
        if let imageID = try await attachImage(url:result,cueId:context.targetCue.id,prompt:prompt,expectedCue:context.targetCue,expectedRevision:context.sourceRevision) { codex.markJobAttached(id:jobID,imageID:imageID) }
    }
    private func heartbeatGenerationAttachment(_ job: LocalGenerationJob) {
        guard generationAttachmentIDs.contains(job.id), !generationCompletionIDs.contains(job.id), generationAttachmentHeartbeats[job.id] == nil, let context = job.context else { return }
        generationAttachmentHeartbeats[job.id] = Task { [weak self] in
            guard let self else { return }
            defer { self.generationAttachmentHeartbeats.removeValue(forKey:job.id) }
            guard self.generationAttachmentIDs.contains(job.id) else { return }
            // Never wait behind script commits or a slow R2 upload to keep the lease alive.
            _ = await self.renewGenerationAttachmentClaim(id:job.id,context:context)
        }
    }
    /// This renews an existing live claim only. Expired or transferred work always
    /// stays in the journal until an explicit recovery action; no model is rerun.
    private func renewGenerationAttachmentClaim(id: String, context: GenerationJobContext) async -> Bool {
        guard context.cloudProjectID != nil else { return true }
        guard generationCloudScopeMatches(context), let projectID = context.cloudProjectID else { return false }
        do {
            let remote = try await cloud.generationJob(id:id,projectID:projectID)
            guard generationCloudScopeMatches(context), remote.status == .running, remote.ownerDeviceId == cloud.deviceId,
                  remote.leaseExpiresAt > Int(Date().timeIntervalSince1970*1000) else { return false }
            let renewed = try await cloud.updateGenerationJob(id:id,expectedVersion:remote.version,status:.running,progressText:"Saving the generated image to its original project",projectID:projectID)
            guard generationCloudScopeMatches(context), renewed.ownerDeviceId == cloud.deviceId, renewed.status == .running else { return false }
            recordSharedGeneration(renewed); return true
        } catch let error as CloudRequestError where error.status == 404 { return true /* A local-only job has no shared execution claim. */ }
        catch { if generationCloudScopeMatches(context) { codex.sharedJobsError = "Image retained locally; ownership could not be confirmed: " + error.localizedDescription }; return false }
    }
    private func recoverGenerationJob(_ job: LocalGenerationJob) {
        guard let context = job.context, generationContextMatches(context) else { errorMessage = "Open this job's original project package before attaching its image."; return }
        guard !generationAttachmentIDs.contains(job.id) else { return }
        generationAttachmentIDs.insert(job.id)
        let navigation = navigationGeneration
        let existingOutput = job.outputImageID.flatMap { id in project.images.contains(where: { $0.id == id }) ? id : nil }
        perform {
            defer { self.generationAttachmentIDs.remove(job.id) }
            // Already-imported output must not create another immutable version merely
            // because an offline save or shared progress acknowledgement was lost.
            let result = existingOutput == nil ? try self.codex.artifactURL(for:job.id) : nil
            guard try await self.claimGenerationRecovery(job) else { return }
            await self.generationMirrorTask?.value
            guard await self.renewGenerationAttachmentClaim(id:job.id,context:context) else { throw ScrivError.conflict("Shared generation ownership changed. The local image is retained; refresh before recovering it.") }
            guard navigation == self.navigationGeneration, self.generationContextMatches(context) else { return }
            if existingOutput != nil {
                self.queueGenerationMirror(job)
                await self.generationMirrorTask?.value
                self.statusMessage = "Image is already attached. Shared completion is being reconciled; sync any local draft first."
            } else if let result, let imageID = try await self.attachImage(url:result,cueId:context.targetCue.id,prompt:job.prompt,expectedCue:context.targetCue,expectedRevision:context.sourceRevision) {
                self.codex.markJobAttached(id:job.id,imageID:imageID)
            }
        }
    }
    private func claimGenerationRecovery(_ job: LocalGenerationJob) async throws -> Bool {
        guard let context = job.context, generationCloudScopeMatches(context), let projectID = context.cloudProjectID else { return true }
        let shared: CloudGenerationJob
        do { shared = try await cloud.generationJob(id:job.id,projectID:projectID) }
        catch let error as CloudRequestError where error.status == 404 {
            // An explicitly recovered offline job can publish metadata, never another model turn.
            shared = try await cloud.createGenerationJob(id:job.id,targetItemId:context.targetCue.id,sourceRevision:context.sourceRevision,projectID:projectID)
        }
        guard generationCloudScopeMatches(context) else { throw CancellationError() }
        if shared.status == .completed {
            recordSharedGeneration(shared); statusMessage = "This shared generation is complete. Sync the project to load its image."; return false
        }
        if shared.status != .running || shared.ownerDeviceId != cloud.deviceId || shared.leaseExpiresAt <= Int(Date().timeIntervalSince1970*1000) {
            let claimed = try await cloud.claimGenerationJob(id:job.id,expectedVersion:shared.version,recover:true,projectID:projectID)
            guard generationCloudScopeMatches(context) else { throw CancellationError() }
            recordSharedGeneration(claimed)
        }
        return true
    }
    private func retryGenerationJob(_ job: LocalGenerationJob) {
        guard let context = job.context, generationContextMatches(context) else { errorMessage = "Open this job's original project package before explicitly retrying."; return }
        perform { try await self.runGeneration(prompt:job.prompt,references:self.codex.referenceURLs(for:job.id),context:context,retryOf:job.id) }
    }
    private func generationCloudScopeMatches(_ context: GenerationJobContext) -> Bool {
        context.cloudProjectID != nil && context.cloudServer == cloud.baseURL.absoluteString && context.accountID != nil && context.accountID == account?.id
    }
    private func recordSharedGeneration(_ job: CloudGenerationJob) {
        guard project.cloudProjectId == job.projectId else { return }
        codex.sharedJobs.removeAll { $0.id == job.id }; codex.sharedJobs.append(job)
        codex.sharedJobs.sort { ($0.createdAt,$0.id) > ($1.createdAt,$1.id) }
    }
    private func prepareSharedGeneration(id: String, context: GenerationJobContext) async -> CloudGenerationJob? {
        guard generationCloudScopeMatches(context), let projectID = context.cloudProjectID else { return nil }
        do {
            let created = try await cloud.createGenerationJob(id:id,targetItemId:context.targetCue.id,sourceRevision:context.sourceRevision,projectID:projectID)
            guard generationCloudScopeMatches(context) else { return nil }
            let claimed = try await cloud.claimGenerationJob(id:id,expectedVersion:created.version,projectID:projectID)
            recordSharedGeneration(claimed); codex.sharedJobsError = nil; return claimed
        } catch {
            if generationCloudScopeMatches(context) { codex.sharedJobsError = "Generation remains local; shared status could not start: " + error.localizedDescription }
            return nil
        }
    }
    private func queueGenerationMirror(_ job: LocalGenerationJob, waiting: Bool = false) {
        guard let context = job.context, generationCloudScopeMatches(context) else { return }
        let previous = generationMirrorTask
        generationMirrorTask = Task { [weak self] in
            await previous?.value
            guard let self, let latest = self.codex.jobs.first(where: { $0.id == job.id }) else { return }
            await self.mirrorGeneration(latest,waiting:waiting)
        }
    }
    private func mirrorGeneration(_ job: LocalGenerationJob, waiting: Bool) async {
        guard let context = job.context, generationCloudScopeMatches(context), let projectID = context.cloudProjectID else { return }
        defer { generationCompletionIDs.remove(job.id) }
        do {
            // Canonical acceptance, not a local file write, makes a shared output complete.
            if job.outputImageID != nil {
                await commitTask?.value
                // Import is finished; drain its last heartbeat before the final CAS update.
                generationCompletionIDs.insert(job.id)
                await generationAttachmentHeartbeats[job.id]?.value
            }
            guard generationCloudScopeMatches(context) else { return }
            let remote = try await cloud.generationJob(id:job.id,projectID:projectID)
            guard generationCloudScopeMatches(context) else { return }
            if remote.status == .completed { recordSharedGeneration(remote); return }
            guard remote.ownerDeviceId == cloud.deviceId, remote.status == .running,
                  remote.leaseExpiresAt > Int(Date().timeIntervalSince1970*1000) else { recordSharedGeneration(remote); return }
            let outputAccepted = job.outputImageID.flatMap { id -> String? in
                guard cloud.projectId == projectID, let item = cloud.items[id], item.kind == "image", item.deleted != true else { return nil }; return id
            }
            let state: LocalGenerationJob.Status
            let progress: String
            if job.status == .completed, let _ = outputAccepted { state = .completed; progress = "Image saved to the shared project" }
            else if waiting || job.status == .waiting || (job.outputImageID != nil && outputAccepted == nil) { state = .waiting; progress = "Image or progress is saved on its original Mac; open that project to continue" }
            else if job.status == .completed { state = .running; progress = "Image ready on its original Mac; saving to the project" }
            else if job.status == .queued || job.status == .running { state = .running; progress = "Generating on the owning Mac" }
            else { state = job.status; progress = state == .cancelled ? "Cancelled on the owning Mac" : "Generation failed on the owning Mac" }
            let result = try await cloud.updateGenerationJob(id:job.id,expectedVersion:remote.version,status:state,progressText:progress,outputImageId:state == .completed ? outputAccepted : nil,errorCode:state == .failed ? "local_generation_failed" : nil,projectID:projectID)
            guard generationCloudScopeMatches(context) else { return }
            recordSharedGeneration(result); codex.sharedJobsError = nil
        } catch is CancellationError { }
        catch let error as CloudRequestError where error.status == 404 { /* Offline/local jobs have no shared record. */ }
        catch { if generationCloudScopeMatches(context) { codex.sharedJobsError = "Local generation is retained; shared progress needs refresh: " + error.localizedDescription } }
    }
    private func refreshSharedGenerationJobs() {
        guard let projectID = project.cloudProjectId, projectID == cloud.projectId, account != nil else { codex.sharedJobs = []; return }
        sharedJobRefreshGeneration += 1; let request = sharedJobRefreshGeneration, navigation = navigationGeneration, server = cloud.baseURL, user = account?.id
        Task { [weak self] in
            guard let self else { return }
            do {
                let jobs = try await self.cloud.generationJobs(projectID:projectID)
                guard request == self.sharedJobRefreshGeneration, navigation == self.navigationGeneration, server == self.cloud.baseURL, user == self.account?.id else { return }
                self.codex.sharedJobs = jobs; self.codex.sharedJobsError = nil
            } catch is CancellationError { }
            catch { if navigation == self.navigationGeneration, server == self.cloud.baseURL, user == self.account?.id { self.codex.sharedJobsError = error.localizedDescription } }
        }
    }
    func downloadImage(_ asset: ImageAsset, silent: Bool = false) {
        guard mediaRequests[asset.sha256] == nil, peerDiscoveries[asset.sha256] == nil else { return }
        let contextID = project.id, navigation = navigationGeneration, requestToken = UUID().uuidString
        mediaRequests[asset.sha256] = requestToken
        perform(reportErrors:!silent) {
            defer { if self.mediaRequests[asset.sha256] == requestToken { self.mediaRequests.removeValue(forKey:asset.sha256) } }
            guard self.project.id == contextID, self.navigationGeneration == navigation, self.mediaRequests[asset.sha256] == requestToken, let package = self.projectURL else { return }
            let projectID = self.project.id
            do {
                let data = try await self.cloud.download(asset)
                guard projectID == self.project.id, self.navigationGeneration == navigation, self.mediaRequests[asset.sha256] == requestToken, self.projectURL == package else { return }
                try await self.repo().storeReplica(data,for:asset,at:package)
                guard self.navigationGeneration == navigation, self.mediaRequests[asset.sha256] == requestToken, self.projectURL == package else { return }
                if let repaired = self.rawAssetURL(asset) { self.invalidLocalAssetPaths.remove(repaired.path); self.checkedLocalAssets.removeValue(forKey:repaired.path); self.pendingLocalAssetChecks.removeValue(forKey:repaired.path) }
                self.refreshPeerAuthorization(); self.objectWillChange.send(); self.fetchMissingImages()
            } catch {
                // Free projects and offline replicas use authorized peers. A missing replica never becomes a fake image.
                guard projectID == self.project.id, self.navigationGeneration == navigation, self.mediaRequests[asset.sha256] == requestToken, self.projectURL == package else { return }
                let devices = try await self.cloud.peerDevices()
                guard self.navigationGeneration == navigation, self.mediaRequests[asset.sha256] == requestToken, self.projectURL == package, self.project.cloudProjectId == self.cloud.projectId else { return }
                let candidates = devices.compactMap { $0["deviceId"]?.string ?? $0["id"]?.string }.filter { $0 != self.cloud.deviceId }
                guard !candidates.isEmpty else { throw ScrivError.unavailable("No hosted image or other authorized Mac is available. Open this project on a Mac that has the image, then retry.") }
                await self.peerTask?.value
                guard self.navigationGeneration == navigation, self.mediaRequests[asset.sha256] == requestToken, self.projectURL == package, self.project.cloudProjectId == self.cloud.projectId else { return }
                let requestID = UUID().uuidString
                self.peerDiscoveries[asset.sha256] = PeerAssetDiscovery(requestId:requestID,allowedPeers:Set(candidates.prefix(40))); self.peerTransferStarted.remove(asset.sha256)
                self.peerTransferStatus = "Looking for a Mac that has this image…"
                Task { [weak self] in
                    try? await Task.sleep(for:.seconds(65))
                    guard let self, self.navigationGeneration == navigation, self.project.id == projectID, self.peerDiscoveries[asset.sha256]?.requestId == requestID else { return }
                    self.peerDiscoveries.removeValue(forKey:asset.sha256); self.peerTransferStarted.remove(asset.sha256)
                    self.peerTransferStatus = "No peer delivered the image. Keep the source Mac open and retry."
                    self.fetchMissingImages()
                }
                var sent = 0
                for peer in candidates.prefix(40) {
                    guard self.navigationGeneration == navigation, self.mediaRequests[asset.sha256] == requestToken, self.project.id == projectID, self.peerDiscoveries[asset.sha256]?.requestId == requestID else { return }
                    do { try await self.cloud.signal(PeerSignal(toDeviceId:peer,type:"asset-request",payload:.object(["action":.string("query"),"hash":.string(asset.sha256),"requestId":.string(requestID)]))); sent += 1 }
                    catch is CancellationError { throw CancellationError() }
                    catch { self.peerTransferStatus = error.localizedDescription }
                }
                if sent == 0 { self.peerDiscoveries.removeValue(forKey:asset.sha256); throw ScrivError.unavailable("Peer discovery could not reach another Mac. Reconnect and retry.") }
            }
        }
    }
    private func fetchMissingImages() {
        guard project.cloudProjectId == cloud.projectId, cloud.projectId != nil, account != nil else { return }
        let availableSlots = max(0,4-mediaRequests.count-peerDiscoveries.count)
        for asset in project.images.filter({ assetURL($0) == nil && !automaticMediaAttempts.contains($0.sha256) }).prefix(availableSlots) {
            automaticMediaAttempts.insert(asset.sha256); downloadImage(asset,silent:true)
        }
    }
    private func finishEditing() { NotificationCenter.default.post(name:.scrivFinishEditing,object:nil); NSApp.keyWindow?.makeFirstResponder(nil) }
    func newProject() { finishEditing(); install(.blank()) }
    func openProject() { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = false; panel.message = "Choose a .scriv project package"; guard panel.runModal() == .OK, let url = panel.url else { return }; perform { try await self.open(url) } }
    private func open(_ url: URL) async throws {
        finishEditing()
        navigationGeneration += 1; invalidLocalAssetPaths = []; checkedLocalAssets = [:]; pendingLocalAssetChecks = [:]; let navigation = navigationGeneration
        await flushPendingSaves()
        let loaded = try await repo().load(at:url), checkpoint = try await repo().checkpoint(at:url)
        let savedHistory = try await repo().history(at:url,through:loaded.revision)
        guard navigationGeneration == navigation else { throw CancellationError() }
        cloud.disconnect(); canonicalCheckpoint = checkpoint; dirtyItems = [:]; hasConflicts = false; isProjectSynchronizing = false; isSyncing = false; pauseRemoteUpdates = false
        project = loaded; projectURL = url; selectedSceneID = loaded.scenes.first?.id ?? ""; selectedEntryID = loaded.entries(in:selectedSceneID).first?.id
        selectedCueID = loaded.cues(in:selectedSceneID).first?.id; selectedCharacterID = loaded.characters.first?.id; selectedWordIDs = []; editingIDs = []
        history = savedHistory; undoStack = []; redoStack = []; isPlaying = false; playheadMs = 0
        activeThread = nil; messages = []; discussionItemID = nil; cloudHistory = []; showDiscussion = false; discussionGeneration += 1; discussionLoading = false
        if !verificationMode { UserDefaults.standard.set(url.path,forKey:"lastProjectURL") }; refreshPeerAuthorization(); onProjectChanged?(project,projectURL)
        if loaded.cloudProjectId != nil, account != nil { syncProject() }
    }
    private func install(_ value: ScrivProject) {
        navigationGeneration += 1; invalidLocalAssetPaths = []; checkedLocalAssets = [:]; pendingLocalAssetChecks = [:]
        cloud.disconnect(); canonicalCheckpoint = nil; dirtyItems = [:]; hasConflicts = false; isProjectSynchronizing = false; isSyncing = false; pauseRemoteUpdates = false
        project = value; projectURL = rootURL.appendingPathComponent(value.id).appendingPathExtension("scriv"); selectedSceneID = value.scenes.first?.id ?? ""
        selectedEntryID = value.entries(in:selectedSceneID).first?.id; selectedCueID = value.cues(in:selectedSceneID).first?.id; selectedCharacterID = value.characters.first?.id
        history = []; undoStack = []; redoStack = []; isPlaying = false; playheadMs = 0; selectedWordIDs = []; editingIDs = []; activeThread = nil; messages = []; discussionItemID = nil; cloudHistory = []; showDiscussion = false; discussionGeneration += 1; discussionLoading = false
        saveProject(); onProjectChanged?(project,projectURL)
    }
    func saveProject() { queueSave(project,label:"Save project") }
    func flushPendingSaves() async { await saveTask?.value }
    func importScript() {
        finishEditing()
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.plainText,.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let data = try Data(contentsOf:url); guard data.count <= 16*1024*1024 else { throw ScrivError.invalid("Script imports are limited to 16 MiB.") }; var imported: ScrivProject; if url.pathExtension.lowercased() == "json" { imported = try ScrivJSON.decoder.decode(ScrivProject.self,from:data); try TimingEngine.validate(imported); imported.id = UUID().uuidString; imported.cloudProjectId = nil; imported.revision = 0; imported.createdAt = ScrivClock.now; imported.modifiedAt = imported.createdAt } else { guard let text = String(data:data,encoding:.utf8) else { throw ScrivError.invalid("Save the script as UTF-8 text or Fountain.") }; imported = Fountain.parse(text,title:url.deletingPathExtension().lastPathComponent) }; try TimingEngine.validate(imported); install(imported) } catch { errorMessage = error.localizedDescription }
    }
    func exportScript() { finishEditing(); let panel = NSSavePanel(); panel.nameFieldStringValue = project.title+".fountain"; guard panel.runModal() == .OK, let url = panel.url else { return }; do { try Fountain.export(project).write(to:url,atomically:true,encoding:.utf8) } catch { errorMessage = error.localizedDescription } }
    func exportProject() { finishEditing(); let panel = NSSavePanel(); panel.nameFieldStringValue = project.title+".scriv"; panel.canCreateDirectories = true; guard panel.runModal() == .OK, let url = panel.url, let source = projectURL else { return }; perform { await self.flushPendingSaves(); try await self.repo().copyPackage(from:source,to:url); self.statusMessage = "Project exported with local images, audio and history" } }
    func undo() {
        finishEditing()
        guard let previous = undoStack.last else { return }
        let current = project, oldUndo = undoStack, oldRedo = redoStack
        if restoreContent(previous,label:"Undo") { undoStack = Array(oldUndo.dropLast()); redoStack = oldRedo + [current] }
    }
    func redo() {
        finishEditing()
        guard let next = redoStack.last else { return }
        let current = project, oldUndo = undoStack, oldRedo = redoStack
        if restoreContent(next,label:"Redo") { undoStack = oldUndo + [current]; redoStack = Array(oldRedo.dropLast()) }
    }
    @discardableResult
    private func restoreContent(_ snapshot: ScrivProject, label: String) -> Bool {
        change(label) { p in
            let cloudId = p.cloudProjectId, id = p.id, rev = p.revision, createdAt = p.createdAt
            p = snapshot; p.id = id; p.cloudProjectId = cloudId; p.revision = rev; p.createdAt = createdAt
        }
    }
    func restoreHistory(_ entry: HistoryEntry) { finishEditing(); restoreContent(entry.snapshot,label:"Restore revision \(entry.revision)") }
    func previewCloudHistory(_ event: CloudEvent) async throws -> ScrivProject {
        let navigation = navigationGeneration
        var base = project; base.audioAssets = []; base.audioClips = []
        let snapshot = try await cloud.historicalSnapshot(seq:event.seq)
        guard navigation == navigationGeneration else { throw CancellationError() }
        return try CloudCodec.applying(snapshot.allItems,to:base)
    }
    func restoreCloudHistory(_ event: CloudEvent) {
        finishEditing(); let contextID = project.id, navigation = navigationGeneration
        perform {
            await self.flushPendingSaves(); await self.commitTask?.value
            guard self.project.id == contextID, self.navigationGeneration == navigation else { return }
            let revision = self.project.revision
            self.pauseRemoteUpdates = true; defer { if self.navigationGeneration == navigation { self.pauseRemoteUpdates = false } }
            try await self.cloud.restore(seq:event.seq)
            guard self.project.id == contextID, self.navigationGeneration == navigation else { return }
            guard self.project.revision == revision else { self.hasConflicts = true; self.syncStatus = "Cloud restored — newer local edits kept for review"; throw ScrivError.conflict("The cloud restore completed, but this Mac was edited while waiting. Your newer local draft is retained; reconcile before replacing it.") }
            self.dirtyItems = [:]; self.hasConflicts = false; self.canonicalCheckpoint = nil; self.pauseRemoteUpdates = false
            self.applyRemote(Array(self.cloud.items.values)); self.cloudHistory = try await self.cloud.history()
        }
    }
    func signIn() { perform { try await self.cloud.signIn(); self.readCloudState() } }
    func signOut() { perform { try await self.cloud.signOut(); self.readCloudState() } }
    func createTeam(name: String) { perform { _ = try await self.cloud.createTeam(name:name); self.readCloudState() } }
    func joinTeam(token: String) {
        do { let clean = try TeamInvitation.token(from:token,serverURL:cloud.baseURL); perform { try await self.cloud.joinTeam(token:clean); self.readCloudState() } }
        catch { errorMessage = error.localizedDescription }
    }
    func createJoinLink(teamId: String) { perform { let url = try await self.cloud.joinLink(teamId:teamId); self.lastJoinLink = url.absoluteString; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString,forType:.string); self.statusMessage = "Team invitation copied" } }
    func checkout(teamId: String) { perform { NSWorkspace.shared.open(try await self.cloud.billing(teamId:teamId,portal:false)) } }
    func billingPortal(teamId: String) { perform { NSWorkspace.shared.open(try await self.cloud.billing(teamId:teamId,portal:true)) } }
    func syncProject(teamId: String? = nil) {
        finishEditing()
        guard account != nil else { signIn(); return }
        guard !isSyncing else { return }
        let contextID = project.id, navigation = navigationGeneration
        isProjectSynchronizing = true; isSyncing = true
        perform {
            await self.commitTask?.value
            guard self.navigationGeneration == navigation, self.project.id == contextID else { return }
            self.isSyncing = true; self.pauseRemoteUpdates = true
            defer { if self.navigationGeneration == navigation, self.project.id == contextID { self.isProjectSynchronizing = false; self.isSyncing = false; self.pauseRemoteUpdates = false } }
            let draft = self.project
            var synchronizedRevision = draft.revision
            if let existing = self.project.cloudProjectId {
                if let checkpoint = self.canonicalCheckpoint, checkpoint.serverURL != self.cloud.baseURL.absoluteString || checkpoint.accountId != self.account?.id {
                    throw ScrivError.permission("This project's cloud copy belongs to a different server or account. Sign in with its original account, or export a separate local copy.")
                }
                let metadata = self.cloudProjects.first { $0.id == existing }
                _ = try await self.cloud.attach(projectId:existing,realtime:self.isPremiumProject(metadata))
                try await self.cloud.retryPendingCommands()
                guard self.navigationGeneration == navigation, self.project.id == contextID, self.project.revision == draft.revision else { throw ScrivError.conflict("New local edits arrived during reconnect. They are saved; sync again to include them.") }
                if self.cloud.canImport {
                    try await self.cloud.seed(draft)
                    guard self.navigationGeneration == navigation, self.project.revision == draft.revision else { throw ScrivError.conflict("New edits are saved locally and queued while the initial script finishes syncing.") }
                } else {
                    let remoteItems = Array(self.cloud.items.values), localItems = try CloudCodec.items(from:draft)
                    let merged: [CloudItem]
                    if let checkpoint = self.validCheckpoint() { merged = try CloudReconciliation.merge(base:checkpoint.items,local:localItems,remote:remoteItems) }
                    else {
                        // Older packages without a baseline can attach when identical;
                        // a differing draft is never silently overwritten or uploaded.
                        let localData = Dictionary(uniqueKeysWithValues:localItems.map { ($0.id,$0.data) })
                        let remoteData = Dictionary(uniqueKeysWithValues:remoteItems.filter { $0.deleted != true }.map { ($0.id,$0.data) })
                        guard localData == remoteData else { self.hasConflicts = true; throw ScrivError.conflict("This older local copy has no cloud checkpoint and differs from the server. Export your draft before opening the cloud version.") }
                        merged = remoteItems
                    }
                    let remote = try CloudCodec.applying(remoteItems,to:draft)
                    let reconciled = try CloudCodec.applying(merged,to:draft)
                    try await self.cloud.commit(before:remote,after:reconciled,label:"Sync offline edits")
                    guard self.navigationGeneration == navigation, self.project.id == contextID, self.project.revision == draft.revision else { throw ScrivError.conflict("New edits remain saved locally. Sync once more to send them.") }
                    if reconciled != self.project {
                        var next = reconciled; next.revision = self.project.revision+1; next.modifiedAt = ScrivClock.now
                        self.project = next; self.queueSave(next,label:"Reconcile cloud changes"); self.onProjectChanged?(next,self.projectURL)
                    }
                    synchronizedRevision = self.project.revision
                }
            } else {
                let created = try await self.cloud.createProject(draft,teamId:teamId)
                guard self.navigationGeneration == navigation, self.project.id == contextID else { return }
                let sourceUnchanged = self.project.revision == draft.revision
                self.project.cloudProjectId = created.id; self.project.revision += 1; self.project.modifiedAt = ScrivClock.now
                let linkedRevision = self.project.revision
                synchronizedRevision = linkedRevision
                self.history.insert(HistoryEntry(label:"Enable cloud sync",snapshot:self.project),at:0)
                self.queueSave(self.project,label:"Enable cloud sync")
                await self.flushPendingSaves()
                _ = try await self.cloud.attach(projectId:created.id,realtime:false)
                try await self.cloud.seed(draft)
                self.recordCheckpoint()
                guard sourceUnchanged, self.project.revision == linkedRevision else { throw ScrivError.conflict("New edits remain local while the first copy uploads. Sync again to include them.") }
                if self.isPremiumProject(created) { _ = try await self.cloud.attach(projectId:created.id,realtime:true) }
            }
            guard self.navigationGeneration == navigation, self.project.id == contextID else { return }
            self.dirtyItems = CloudCommitBarrier.remainingDirtyItems(self.dirtyItems,through:synchronizedRevision)
            self.hasConflicts = !self.dirtyItems.isEmpty
            // The canonical script phase is over. Do not hold local edits behind
            // potentially slow image uploads or silently drop their queued commands.
            self.pauseRemoteUpdates = false
            self.applyRemote(Array(self.cloud.items.values))
            self.refreshPeerAuthorization()
            if self.isPremiumProject(self.cloudProjects.first { $0.id == self.project.cloudProjectId }), let package = self.projectURL {
                for asset in self.project.images where self.assetURL(asset) != nil {
                    let data = try await self.repo().assetData(asset,at:package)
                    guard self.navigationGeneration == navigation, self.project.id == contextID else { return }
                    try await self.cloud.upload(asset,data:data)
                }
            }
            self.cloudHistory = try await self.cloud.history(); self.readCloudState()
            self.fetchMissingImages()
        }
    }
    private func isPremiumProject(_ metadata: CloudProject?) -> Bool { guard let teamID = metadata?.teamId else { return false }; return teams.first { $0.id == teamID }?.isPaid == true }
    func shareProjectWithTeam(_ teamId: String) {
        finishEditing()
        guard account != nil else { signIn(); return }
        if project.cloudProjectId == nil { syncProject(teamId:teamId); return }
        let contextID = project.id
        // Preserve the original solo project, all its history, and its remote identity.
        perform {
            await self.flushPendingSaves()
            await self.commitTask?.value
            guard self.project.id == contextID else { return }
            var copy = self.project
            copy.id = UUID().uuidString; copy.cloudProjectId = nil; copy.revision = 0
            copy.title += " — Team copy"; copy.createdAt = ScrivClock.now; copy.modifiedAt = copy.createdAt
            let destination = self.rootURL.appendingPathComponent(copy.id).appendingPathExtension("scriv")
            if let original = self.projectURL {
                try await self.repo().copyPackage(from:original,to:destination)
                // A new content lineage gets a new history directory; the original package is untouched.
                let copiedHistory = destination.appendingPathComponent("history")
                if FileManager.default.fileExists(atPath:copiedHistory.path) { try FileManager.default.removeItem(at:copiedHistory) }
                let copiedCheckpoint = destination.appendingPathComponent("cloud-sync.json")
                if FileManager.default.fileExists(atPath:copiedCheckpoint.path) { try FileManager.default.removeItem(at:copiedCheckpoint) }
                // This new package has a new identity and revision lineage. Publishing
                // its first snapshot must not reuse the original project's current head.
                let copiedCurrent = destination.appendingPathComponent("project.json")
                if FileManager.default.fileExists(atPath:copiedCurrent.path) { try FileManager.default.removeItem(at:copiedCurrent) }
            }
            guard self.project.id == contextID else { return }
            self.install(copy)
            await self.flushPendingSaves()
            self.syncProject(teamId:teamId)
        }
    }
    func openCloudProject(_ remote: CloudProject) {
        finishEditing(); navigationGeneration += 1; invalidLocalAssetPaths = []; checkedLocalAssets = [:]; pendingLocalAssetChecks = [:]; let navigation = navigationGeneration
        perform {
            await self.flushPendingSaves(); await self.commitTask?.value
            guard self.navigationGeneration == navigation else { return }
            self.pauseRemoteUpdates = true; self.isSyncing = true
            defer { if self.navigationGeneration == navigation { self.pauseRemoteUpdates = false; self.isSyncing = false } }
            var base = ScrivProject(id:UUID().uuidString,title:remote.title,cloudProjectId:remote.id)
            var package = self.rootURL.appendingPathComponent(base.id).appendingPathExtension("scriv")
            // Reuse a verified local replica, keeping all prior revisions and image bytes.
            let candidates = ([self.projectURL].compactMap { $0 } + (try await self.repo().projects()))
            for candidate in candidates {
                guard let existing = try? await self.repo().load(at:candidate), existing.cloudProjectId == remote.id,
                      let checkpoint = try? await self.repo().checkpoint(at:candidate), checkpoint.serverURL == self.cloud.baseURL.absoluteString, checkpoint.accountId == self.account?.id else { continue }
                base = existing; package = candidate; break
            }
            guard self.navigationGeneration == navigation else { return }
            let snapshot = try await self.cloud.attach(projectId:remote.id,realtime:self.isPremiumProject(remote))
            guard self.navigationGeneration == navigation else { return }
            var loaded = try CloudCodec.applying(snapshot.allItems,to:base)
            loaded.title = remote.title; loaded.revision = base.revision+1; loaded.modifiedAt = ScrivClock.now
            let previousHistory = try await self.repo().history(at:package,through:base.revision)
            guard self.navigationGeneration == navigation else { return }
            try self.cloud.keepPendingAsLocalDrafts()
            self.dirtyItems = [:]; self.hasConflicts = false; self.canonicalCheckpoint = nil; self.project = loaded; self.projectURL = package
            self.selectedSceneID = loaded.scenes.first?.id ?? ""; self.selectedEntryID = loaded.entries(in:self.selectedSceneID).first?.id; self.selectedCueID = loaded.cues(in:self.selectedSceneID).first?.id; self.selectedCharacterID = loaded.characters.first?.id
            self.playheadMs = 0; self.isPlaying = false; self.selectedWordIDs = []; self.editingIDs = []; self.undoStack = []; self.redoStack = []; self.activeThread = nil; self.messages = []; self.discussionItemID = nil; self.showDiscussion = false; self.discussionGeneration += 1; self.discussionLoading = false
            self.history = previousHistory; self.queueSave(loaded,label:"Open cloud project"); self.recordCheckpoint(); self.refreshPeerAuthorization()
            self.cloudHistory = try await self.cloud.history()
            guard self.navigationGeneration == navigation else { return }
            self.readCloudState(); self.onProjectChanged?(loaded,package); self.fetchMissingImages()
        }
    }
    private func updateMentionScope() {
        let scope = DiscussionState.draftKey(server:cloud.baseURL.absoluteString,account:account?.id,project:project.id,item:nil)
        guard mentionScope != scope else { return }
        mentionScope = scope; mentionMessages = []; discussionMembers = []; discussionMembersError = nil; memberRequestGeneration += 1; discussionMembersLoading = false
        readMentionIDs = verificationMode ? [] : Set(UserDefaults.standard.stringArray(forKey:"readMentions." + scope) ?? [])
    }
    func discussionMemberName(_ id: String) -> String {
        discussionMembers.first { $0.id == id }?.name ?? discussionMentionDrafts[discussionDraftKey]?.first { $0.id == id }?.name ?? (id == account?.id ? "You" : "Former member")
    }
    func addDiscussionMention(_ member: DiscussionMember) {
        guard discussionMembers.contains(where: { $0.id == member.id }), !discussionMentionedUserIDs.contains(member.id) else { return }
        do { _ = try DiscussionState.validatedMentionIDs(discussionMentionedUserIDs + [member.id],members:discussionMembers) }
        catch { errorMessage = error.localizedDescription; return }
        discussionMentionDrafts[discussionDraftKey,default:[]].append(member)
    }
    func removeDiscussionMention(_ id: String) { discussionMentionDrafts[discussionDraftKey]?.removeAll { $0.id == id } }
    func refreshDiscussionMembers() async throws {
        updateMentionScope()
        guard project.cloudProjectId == cloud.projectId, cloud.projectId != nil, account != nil else { throw ScrivError.unavailable("Reconnect this project to choose members.") }
        memberRequestGeneration += 1; let request = memberRequestGeneration, navigation = navigationGeneration, scope = mentionScope
        discussionMembersLoading = true; discussionMembersError = nil
        defer { if memberRequestGeneration == request { discussionMembersLoading = false } }
        do {
            let members = try await cloud.projectMembers()
            guard request == memberRequestGeneration, navigation == navigationGeneration, scope == mentionScope else { throw CancellationError() }
            discussionMembers = members
        } catch {
            if request == memberRequestGeneration, navigation == navigationGeneration, scope == mentionScope, !(error is CancellationError) { discussionMembersError = error.localizedDescription }
            throw error
        }
    }
    private func receiveDiscussionMessage(_ message: DiscussionMessage) {
        guard project.cloudProjectId == cloud.projectId, cloud.projectId != nil else { return }
        updateMentionScope()
        mentionMessages = Array(DiscussionState.mentions(mentionMessages + [message],userID:account?.id).prefix(1000))
        if message.threadId == activeThread?.id {
            messages = DiscussionState.merged(messages,with:[message],threadId:message.threadId)
            if showDiscussion { markDiscussionMentionsRead(threadID:message.threadId) }
        }
    }
    private func ingestMentionHistory() {
        updateMentionScope()
        let restored = cloudHistory.compactMap { event -> DiscussionMessage? in
            guard event.kind == "discussion.message-created", let value = event.data?["message"] else { return nil }
            return try? value.decoded(DiscussionMessage.self)
        }
        mentionMessages = Array(DiscussionState.mentions(mentionMessages + restored,userID:account?.id).prefix(1000))
        if showDiscussion, let threadID = activeThread?.id { markDiscussionMentionsRead(threadID:threadID) }
    }
    private func refreshMentionHistory() {
        guard project.cloudProjectId == cloud.projectId, cloud.projectId != nil, account != nil else { return }
        perform { try await self.refreshDiscussionActivity() }
    }
    func refreshDiscussionActivity() async throws {
        guard project.cloudProjectId == cloud.projectId, cloud.projectId != nil, account != nil else { return }
        mentionHistoryRequestGeneration += 1; let request = mentionHistoryRequestGeneration, navigation = navigationGeneration
        let events = try await cloud.history()
        try await cloud.refreshThreads()
        guard request == mentionHistoryRequestGeneration, navigation == navigationGeneration else { throw CancellationError() }
        // Events received during HTTP pagination are retained, not overwritten.
        let unique = Dictionary((events + cloudHistory).map { ($0.seq,$0) },uniquingKeysWith: { _,last in last })
        cloudHistory = unique.values.sorted { $0.seq > $1.seq }; objectWillChange.send()
        try await refreshDiscussionMembers()
    }
    func isDiscussionMentionUnread(_ message: DiscussionMessage) -> Bool { !readMentionIDs.contains(message.id) }
    private func markDiscussionMentionsRead(threadID: String) {
        readMentionIDs.formUnion(mentionMessages.filter { $0.threadId == threadID }.map(\.id))
        if !verificationMode { UserDefaults.standard.set(Array(readMentionIDs).sorted(),forKey:"readMentions." + mentionScope) }
    }
    func openDiscussionMention(_ message: DiscussionMessage) {
        guard let thread = cloud.threads[message.threadId] else { errorMessage = "This discussion is not loaded. Reconnect the project to recover it."; return }
        openDiscussionThread(thread); discussionFocusedMessageID = message.id
    }
    func openDiscussionThread(_ thread: DiscussionThread) {
        discussionFocusedMessageID = nil
        discussionGeneration += 1; let generation = discussionGeneration, navigation = navigationGeneration
        discussionItemID = thread.itemId; activeThread = thread; messages = []; discussionReplyToID = nil; discussionAttachments = []; showDiscussion = true; discussionLoading = true
        perform {
            defer { if self.discussionGeneration == generation { self.discussionLoading = false } }
            let loaded = try await self.cloud.messages(threadId:thread.id)
            guard self.discussionGeneration == generation, self.navigationGeneration == navigation else { return }
            self.messages = DiscussionState.merged(loaded,with:self.messages,threadId:thread.id)
            for message in loaded { self.receiveDiscussionMessage(message) }
            self.markDiscussionMentionsRead(threadID:thread.id)
        }
    }
    func loadDiscussion(itemId: String?) {
        discussionFocusedMessageID = nil
        updateMentionScope()
        discussionGeneration += 1; let generation = discussionGeneration
        discussionItemID = itemId; messages = []; activeThread = nil; discussionReplyToID = nil; discussionAttachments = []; showDiscussion = true
        discussionLoading = false
        guard project.cloudProjectId != nil, account != nil, project.cloudProjectId == cloud.projectId else { return }
        let contextProjectID = project.id
        let entryWordIDs = Set(project.entries.first(where: { $0.id == itemId })?.words.map(\.id) ?? [])
        let wordIDs = selectedWordIDs.intersection(entryWordIDs)
        let anchor: JSONValue? = project.asset(itemId) != nil ? .object(["imageVersionId":.string(itemId!)]) : (wordIDs.isEmpty ? nil : .object(["wordIds":.array(wordIDs.sorted().map(JSONValue.string))]))
        discussionLoading = true
        perform {
            defer { if self.discussionGeneration == generation { self.discussionLoading = false } }
            let thread = try await self.cloud.thread(itemId:itemId,anchor:anchor)
            guard self.discussionGeneration == generation, self.project.id == contextProjectID else { return }
            self.activeThread = thread
            let loaded = try await self.cloud.messages(threadId:thread.id)
            guard self.discussionGeneration == generation, self.activeThread?.id == thread.id, self.project.id == contextProjectID else { return }
            self.messages = DiscussionState.merged(loaded,with:self.messages,threadId:thread.id)
            for message in loaded { self.receiveDiscussionMessage(message) }
        }
    }
    private func refreshDiscussion() {
        let action = DiscussionState.refreshAction(isVisible:showDiscussion,isAttached:project.cloudProjectId == cloud.projectId && cloud.projectId != nil,hasThread:activeThread != nil,isLoading:discussionLoading)
        switch action {
        case .none: return
        case .loadThread: loadDiscussion(itemId:discussionItemID); return
        case .reloadMessages: break
        }
        guard let thread = activeThread else { return }
        let context = discussionGeneration, projectID = project.id
        perform {
            let loaded = try await self.cloud.messages(threadId:thread.id)
            guard self.discussionGeneration == context, self.project.id == projectID, self.activeThread?.id == thread.id else { return }
            self.messages = DiscussionState.merged(loaded,with:self.messages,threadId:thread.id)
            for message in loaded { self.receiveDiscussionMessage(message) }
        }
    }
    @discardableResult
    func sendMessage(_ text: String) async throws -> DiscussionMessage {
        let body = text.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !body.isEmpty, body.utf16.count <= 8000 else { throw ScrivError.invalid("Messages must contain between 1 and 8,000 characters.") }
        guard !isSendingDiscussion, project.cloudProjectId == cloud.projectId, account != nil else { throw ScrivError.unavailable("Wait for the current message or reconnect this project before sending.") }
        let contextID = project.id, itemID = discussionItemID, existingThread = activeThread, replyID = discussionReplyToID, attachments = discussionAttachments
        let navigation = navigationGeneration, discussion = discussionGeneration, draftKey = discussionDraftKey
        let mentionedIDs = discussionMentionedUserIDs.sorted()
        guard mentionedIDs.count <= 20 else { throw ScrivError.invalid("Choose up to 20 people.") }
        let fingerprint = ScrivDigest.sha256(try ScrivJSON.encoder.encode(JSONValue.array([.string(draftKey),.string(body),replyID.map(JSONValue.string) ?? .null,.array(attachments),.array(mentionedIDs.map(JSONValue.string))])))
        let messageID = pendingMessageIDs[fingerprint] ?? UUID().uuidString; pendingMessageIDs[fingerprint] = messageID
        isSendingDiscussion = true; defer { isSendingDiscussion = false }
        let thread: DiscussionThread
        if let existingThread { thread = existingThread } else { thread = try await cloud.thread(itemId:itemID) }
        guard project.id == contextID, navigationGeneration == navigation else { throw CancellationError() }
        if discussionGeneration == discussion { activeThread = thread }
        let message = try await cloud.postMessage(threadId:thread.id,text:body,replyToId:replyID,attachments:attachments,mentionedUserIds:mentionedIDs,messageId:messageID)
        pendingMessageIDs.removeValue(forKey:fingerprint)
        // Clear only this acknowledged draft. A newer draft or another item's text stays.
        if discussionDrafts[draftKey]?.trimmingCharacters(in:.whitespacesAndNewlines) == body, (discussionMentionDrafts[draftKey] ?? []).map(\.id).sorted() == mentionedIDs { discussionDrafts[draftKey] = ""; discussionMentionDrafts[draftKey] = [] }
        if project.id == contextID, discussionGeneration == discussion, activeThread?.id == message.threadId {
            receiveDiscussionMessage(message)
            if discussionReplyToID == replyID, discussionAttachments == attachments { discussionReplyToID = nil; discussionAttachments = [] }
        }
        return message
    }
    func resolveThread() { guard let thread = activeThread else { return }; let contextID = project.id; perform { let updated = try await self.cloud.resolve(threadId:thread.id,resolved:!thread.resolved); if self.project.id == contextID, self.activeThread?.id == thread.id { self.activeThread = updated } } }
    func handleOpenURL(_ url: URL) {
        if url.isFileURL && url.pathExtension == "scriv" { perform { try await self.open(url) }; return }
        if url.scheme == "scriv", url.host == "join" { joinTeam(token:url.absoluteString) }
        if url.scheme == "scriv", url.host == "billing", url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
           teams.contains(where: { "/" + $0.id == url.path }) { refreshAccount() }
        // ASWebAuthenticationSession owns auth callbacks and validates the per-request state and PKCE verifier.
    }
    func retryCloudSync() { syncProject() }
    func refreshAccount() { perform { try await self.cloud.refreshAccount(); self.readCloudState() } }
    func refreshLocalProjects() { perform { self.localProjects = try await self.repo().projects().sorted { $0.lastPathComponent < $1.lastPathComponent } } }
    func openLocalProject(_ url: URL) { perform { try await self.open(url) } }
    func loadTeamDetails(teamId: String) { perform { self.teamDetails = try await self.cloud.teamDetails(teamId) } }
    func revokeJoinLink(teamId: String, linkId: String) { perform { try await self.cloud.revokeJoinLink(teamId:teamId,linkId:linkId); self.teamDetails = try await self.cloud.teamDetails(teamId) } }
    func setMemberRole(teamId: String, userId: String, role: String) { perform { try await self.cloud.setMemberRole(teamId:teamId,userId:userId,role:role); self.teamDetails = try await self.cloud.teamDetails(teamId) } }
    func removeMember(teamId: String, userId: String) { perform { try await self.cloud.removeMember(teamId:teamId,userId:userId); self.teamDetails = try await self.cloud.teamDetails(teamId) } }
    func addDiscussionAttachment(itemId: String, imageVersionId: String? = nil) {
        var value: [String:JSONValue] = ["itemId":.string(itemId)]
        if let imageVersionId { value["imageVersionId"] = .string(imageVersionId) }
        if discussionAttachments.count < 8, !discussionAttachments.contains(.object(value)) { discussionAttachments.append(.object(value)) }
    }
    /// Deterministic local sample used by the native visual-verification runner.
    func prepareSampleForScreenshot() async {
        await bootstrapTask?.value
        await flushPendingSaves()
        install(.example())
        do { try await installSampleImages(); await flushPendingSaves() } catch { errorMessage = error.localizedDescription }
        selectedEntryID = "line-08"; selectedCueID = "cue-08c"; playheadMs = 29_400
    }
    private func installSampleImages() async throws {
        guard let package = projectURL, project.images.isEmpty else { return }
        let projectID = project.id
        var assets: [String:ImageAsset] = [:]
        for name in ["farm-wide","franklin","miyazaki"] {
            guard let url = Bundle.scrivResources.url(forResource:name,withExtension:"png",subdirectory:"SampleImages") ?? Bundle.scrivResources.url(forResource:name,withExtension:"png") else { throw ScrivError.unavailable("The sample scene images are missing from this app bundle.") }
            let tags = name == "farm-wide" ? ["character-randy","character-franklin","character-miyazaki"] : ["character-" + name]
            let asset = try await repo().importAsset(data:Data(contentsOf:url),at:package,prompt:"Built-in generated sample frame",characterIds:tags)
            guard project.id == projectID else { return }; assets[name] = asset
        }
        change("Install sample scene images") { project in
            project.images = Array(assets.values).sorted { $0.fileName < $1.fileName }
            for index in project.cues.indices {
                let label = project.cues[index].label
                let name = ["08B","09A","10A","12A"].contains(label) ? "franklin" : label == "10B" ? "miyazaki" : "farm-wide"
                project.cues[index].imageId = assets[name]?.id
            }
            for index in project.characters.indices {
                let id = project.characters[index].id
                project.characters[index].portraitImageId = assets[id == "character-franklin" ? "franklin" : id == "character-miyazaki" ? "miyazaki" : "farm-wide"]?.id
            }
        }
    }
    private func configurePeers() {
        peerConfigurationGeneration += 1; let generation = peerConfigurationGeneration
        peerTask?.cancel(); peerMedia.disconnect(); peerDiscoveries = [:]; peerTransferStarted = []; mediaRequests = [:]; automaticMediaAttempts = []; peerProjectId = cloud.projectId
        guard let projectID = cloud.projectId, let deviceID = cloud.deviceId else { return }
        peerTask = Task { [weak self] in
            guard let self else { return }
            do {
                let configuration = try await self.cloud.peerConfiguration()
                guard self.cloud.projectId == projectID, self.peerConfigurationGeneration == generation, !Task.isCancelled else { return }
                try await self.peerMedia.start(deviceId:deviceID,iceServers:configuration)
                guard self.cloud.projectId == projectID, self.peerConfigurationGeneration == generation, !Task.isCancelled else { return }
                self.refreshPeerAuthorization()
            } catch { if self.peerConfigurationGeneration == generation, !Task.isCancelled { self.peerTransferStatus = "Peer transfer unavailable: " + error.localizedDescription } }
        }
    }
    private func refreshPeerAuthorization() {
        verifyLocalMedia()
        guard project.cloudProjectId == cloud.projectId, cloud.projectId != nil else { peerMedia.authorize(knownHashes:[],localAssets:[:]); return }
        var available: [String:URL] = [:]
        for asset in project.images { if let url = assetURL(asset) { available[asset.sha256] = url } }
        peerMedia.authorize(knownHashes:Set(project.images.map(\.sha256)),localAssets:available)
    }
    private func verifyLocalMedia() {
        guard let package = projectURL else { return }
        let navigation = navigationGeneration
        for asset in project.images {
            guard let url = rawAssetURL(asset), let values = try? url.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey]), let size = values.fileSize else { continue }
            let stamp = LocalAssetStamp(modified:values.contentModificationDate ?? .distantPast,size:size,hash:asset.sha256), key = url.path
            guard checkedLocalAssets[key] != stamp, pendingLocalAssetChecks[key] == nil else { continue }
            let token = UUID().uuidString; pendingLocalAssetChecks[key] = token
            Task { [weak self] in
                guard let self else { return }
                defer { if self.pendingLocalAssetChecks[key] == token { self.pendingLocalAssetChecks.removeValue(forKey:key) } }
                let valid: Bool
                do { _ = try await self.repo().assetData(asset,at:package); valid = true } catch { valid = false }
                guard self.navigationGeneration == navigation, self.projectURL == package, self.pendingLocalAssetChecks[key] == token else { return }
                guard let current = try? url.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey]), current.fileSize == stamp.size, (current.contentModificationDate ?? .distantPast) == stamp.modified else {
                    self.pendingLocalAssetChecks.removeValue(forKey:key)
                    self.verifyLocalMedia(); return
                }
                self.checkedLocalAssets[key] = stamp
                if valid { self.invalidLocalAssetPaths.remove(key) }
                else { self.invalidLocalAssetPaths.insert(key); self.peerTransferStatus = "A local image failed verification; requesting a verified copy." }
                self.objectWillChange.send()
                if !valid { self.refreshPeerAuthorization(); self.fetchMissingImages() }
            }
        }
    }
    private func handleAssetDiscovery(_ signal: PeerSignal) async throws {
        guard project.cloudProjectId == cloud.projectId, cloud.projectId != nil else { return }
        guard let sender = signal.fromDeviceId, let hash = signal.payload["hash"]?.string,
              let requestID = signal.payload["requestId"]?.string, let asset = project.images.first(where: { $0.sha256 == hash }) else { return }
        if signal.payload["action"]?.string == "query" {
            guard assetURL(asset) != nil else { return }
            try await cloud.signal(PeerSignal(toDeviceId:sender,type:"asset-request",payload:.object(["action":.string("available"),"hash":.string(hash),"requestId":.string(requestID)])))
        } else if signal.payload["action"]?.string == "available", var discovery = peerDiscoveries[hash], discovery.offer(peer:sender,requestId:requestID) {
            peerDiscoveries[hash] = discovery
            await startPeerTransfer(hash:hash,requestID:requestID)
        }
    }
    private func startPeerTransfer(hash: String, requestID: String) async {
        guard var discovery = peerDiscoveries[hash], discovery.requestId == requestID, let peer = discovery.nextSource() else { return }
        peerDiscoveries[hash] = discovery; peerTransferStarted.insert(hash)
        let generation = peerConfigurationGeneration
        do { try await peerMedia.requestAsset(hash:hash,fromDeviceId:peer) }
        catch { if peerConfigurationGeneration == generation, peerDiscoveries[hash]?.requestId == requestID { peerTransferFailed(peer:peer,hash:hash,error:error) } }
    }
    private func peerTransferFailed(peer: String, hash: String, error: Error) {
        guard var discovery = peerDiscoveries[hash], discovery.failed(peer:peer) else { return }
        peerDiscoveries[hash] = discovery; peerTransferStarted.remove(hash)
        peerTransferStatus = "Trying another available Mac…"
        let requestID = discovery.requestId
        Task { [weak self] in await self?.startPeerTransfer(hash:hash,requestID:requestID) }
    }
    private func receivedPeerAsset(hash: String, data: Data) {
        peerDiscoveries.removeValue(forKey:hash); peerTransferStarted.remove(hash)
        guard project.cloudProjectId == cloud.projectId, cloud.projectId != nil, let asset = project.images.first(where: { $0.sha256 == hash }), let package = projectURL else { return }
        let projectID = project.id, navigation = navigationGeneration
        perform {
            try await self.repo().storeReplica(data,for:asset,at:package)
            guard self.project.id == projectID, self.navigationGeneration == navigation, self.projectURL == package else { return }
            if let repaired = self.rawAssetURL(asset) { self.invalidLocalAssetPaths.remove(repaired.path); self.checkedLocalAssets.removeValue(forKey:repaired.path); self.pendingLocalAssetChecks.removeValue(forKey:repaired.path) }
            self.refreshPeerAuthorization(); self.objectWillChange.send(); self.statusMessage = "Peer image received and verified"; self.fetchMissingImages()
        }
    }
    private func perform(reportErrors: Bool = true, _ work: @escaping @MainActor () async throws -> Void) { Task { do { try await work() } catch is CancellationError { } catch { if reportErrors { errorMessage = error.localizedDescription } else { peerTransferStatus = error.localizedDescription } } } }
}
