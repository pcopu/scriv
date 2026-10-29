import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers
import ScrivCore

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published var project: ScrivProject
    @Published var selectedSceneID: String
    @Published var selectedEntryID: String?
    @Published var selectedCharacterID: String?
    @Published var selectedCueID: String?
    @Published var selectedWordIDs: Set<String> = []
    @Published var tab: WorkspaceTab = .script
    @Published var playheadMs: Double = 0
    @Published var isPlaying = false
    @Published var followPlayback = true
    @Published var statusMessage = "Saved on this Mac"
    @Published var errorMessage: String?
    @Published var history: [HistoryEntry] = []
    @Published var cloudHistory: [CloudEvent] = []
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
    @Published var generationPrompt = ""
    @Published var projectURL: URL?
    @Published var lastJoinLink: String?
    @Published var hasConflicts = false
    @Published var teamDetails: JSONValue?
    @Published var localProjects: [URL] = []
    @Published var discussionReplyToID: String?
    @Published var discussionAttachments: [JSONValue] = []
    @Published var peerTransferStatus = "Peer transfer stopped"
    let peerMedia = PeerMediaBridge()
    let codex = CodexController()
    let cloud = CloudClient()
    private var repository: ProjectRepository?
    private var playbackTask: Task<Void,Never>?
    private var saveTask: Task<Void,Never>?
    private var commitTask: Task<Void,Never>?
    private var dirtyItems: [String:Int] = [:]
    private var canonicalCheckpoint: CloudCheckpoint?
    private var pauseRemoteUpdates = false
    private var undoStack: [ScrivProject] = []
    private var redoStack: [ScrivProject] = []
    private var editingIDs: Set<String> = []
    private var rootURL: URL
    private var bootstrapTask: Task<Void, Never>?
    private var peerTask: Task<Void, Never>?
    private var peerProjectId: String?
    private var mediaRequests: Set<String> = []
    private var peerDiscoveries: [String:String] = [:]
    private var peerTransferStarted: Set<String> = []
    private var automaticMediaAttempts: Set<String> = []
    private var pendingMessageIDs: [String:String] = [:]
    private var navigationGeneration = 0
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
        rootURL = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Scriv/Projects")
        do { repository = try ProjectRepository(root:rootURL) } catch { errorMessage = "Local project storage could not open: \(error.localizedDescription)" }
        projectURL = rootURL.appendingPathComponent(example.id).appendingPathExtension("scriv")
        cloud.onState = { [weak self] in self?.readCloudState() }
        cloud.onItems = { [weak self] items in self?.applyRemote(items) }
        cloud.onError = { [weak self] error in self?.errorMessage = error.localizedDescription }
        cloud.onMessage = { [weak self] message in guard let self, message.threadId == self.activeThread?.id else { return }; if !self.messages.contains(where: { $0.id == message.id }) { self.messages.append(message) } }
        cloud.onThread = { [weak self] thread in guard let self, thread.id == self.activeThread?.id else { return }; self.activeThread = thread }
        cloud.onEvent = { [weak self] event in guard let self else { return }; if !self.cloudHistory.contains(where: { $0.seq == event.seq }) { self.cloudHistory.insert(event,at:0) } }
        codex.onChange = { [weak self] in self?.objectWillChange.send() }
        peerMedia.onSignal = { [weak self] signal in
            guard let self else { return }; let projectID = self.cloud.projectId
            Task { do { guard projectID == self.cloud.projectId else { return }; try await self.cloud.signal(signal) } catch { self.errorMessage = error.localizedDescription } }
        }
        cloud.onSignal = { [weak self] signal in
            guard let self else { return }
            let projectID = self.cloud.projectId
            Task {
                await self.peerTask?.value
                guard self.cloud.projectId == projectID else { return }
                do {
                    if signal.type == "asset-request" { try await self.handleAssetDiscovery(signal) }
                    else { try await self.peerMedia.handleSignal(signal) }
                } catch { self.peerTransferStatus = error.localizedDescription }
            }
        }
        peerMedia.onAsset = { [weak self] hash, data in self?.receivedPeerAsset(hash:hash,data:data) }
        peerMedia.onError = { [weak self] error in self?.peerTransferStatus = error.localizedDescription }
        peerMedia.$status.sink { [weak self] value in self?.peerTransferStatus = value }.store(in:&cancellables)
        bootstrapTask = Task { [weak self] in await self?.bootstrap() }
    }
    private func repo() throws -> ProjectRepository { guard let repository else { throw ScrivError.unavailable("Local project storage is unavailable. Check folder permissions.") }; return repository }
    private func bootstrap() async {
        if ProcessInfo.processInfo.arguments.contains("--screenshots") || ProcessInfo.processInfo.arguments.contains("--peer-smoke") { return }
        if let path = UserDefaults.standard.string(forKey:"lastProjectURL"), FileManager.default.fileExists(atPath:path) {
            do { try await open(URL(fileURLWithPath:path)) } catch { errorMessage = "The last project could not open: \(error.localizedDescription)" }
        } else { saveProject() }
        if project.images.isEmpty && project.scenes.contains(where: { $0.id == "scene-farm" }) { do { try await installSampleImages() } catch { errorMessage = error.localizedDescription } }
        await cloud.restoreSession()
        if project.cloudProjectId != nil, account != nil { syncProject() }
        refreshLocalProjects()
    }
    private func readCloudState() {
        account = cloud.account; teams = cloud.teams; cloudProjects = cloud.projects; peers = cloud.peers; leases = cloud.leases; syncStatus = cloud.status
        if peerProjectId != cloud.projectId { configurePeers() }
    }
    private func change(_ label: String, _ mutate: (inout ScrivProject) throws -> Void) {
        do {
            let before = project
            var next = before
            try mutate(&next); try TimingEngine.validate(next)
            guard next != before else { return }
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
            refreshPeerAuthorization()
            playheadMs = min(playheadMs,Double(sceneDurationMs)); onProjectChanged?(project,projectURL)
        } catch { errorMessage = error.localizedDescription }
    }
    private func queueSave(_ snapshot: ScrivProject, label: String) {
        guard let package = projectURL else { errorMessage = "Choose a project location before saving."; return }
        let previous = saveTask
        statusMessage = "Saving…"
        saveTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do { try await self.repo().save(snapshot,at:package,label:label); if self.project.id == snapshot.id && self.project.revision == snapshot.revision { self.statusMessage = "Saved on this Mac" }; UserDefaults.standard.set(package.path,forKey:"lastProjectURL") }
            catch { self.errorMessage = "Could not save your project: \(error.localizedDescription)"; self.statusMessage = "Save failed" }
        }
    }
    private func enqueueCommit(before: ScrivProject, after: ScrivProject, label: String, changed: Set<String>) {
        let previous = commitTask
        commitTask = Task { [weak self] in
            await previous?.value
            guard let self, self.project.id == after.id, !self.pauseRemoteUpdates else { return }
            self.isSyncing = true
            do {
                try await self.cloud.commit(before:before,after:after,label:label)
                guard self.project.id == after.id else { return }
                for id in changed where self.dirtyItems[id] == after.revision { self.dirtyItems.removeValue(forKey:id) }
                self.hasConflicts = !self.dirtyItems.isEmpty
                self.recordCheckpoint()
                for id in changed where !self.editingIDs.contains(id) { await self.cloud.releaseLease(id) }
            } catch { guard self.project.id == after.id else { return }; self.errorMessage = error.localizedDescription; self.hasConflicts = true; self.syncStatus = "Draft saved locally — needs review" }
            if self.project.id == after.id { self.isSyncing = false }
        }
    }
    private func applyRemote(_ items: [CloudItem]) {
        guard !pauseRemoteUpdates, project.cloudProjectId == cloud.projectId, cloud.projectId != nil else { return }
        do {
            let merged: [CloudItem]
            if let checkpoint = validCheckpoint() { merged = try CloudReconciliation.merge(base:checkpoint.items,local:CloudCodec.items(from:project),remote:items) }
            else { guard dirtyItems.isEmpty else { throw ScrivError.conflict("A local draft needs reconciliation before applying live updates.") }; merged = items }
            let next = try CloudCodec.applying(merged,to:project)
            if next != project { var revised = next; revised.revision = project.revision+1; revised.modifiedAt = ScrivClock.now; project = revised; queueSave(revised,label:"Live update"); refreshPeerAuthorization(); onProjectChanged?(project,projectURL) }
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
    func beginEdit(_ id: String) async -> Bool {
        do { _ = try await cloud.acquireLease(id); editingIDs.insert(id); cloud.presence(itemId:id); return true }
        catch { errorMessage = error.localizedDescription; return false }
    }
    func endEdit(_ id: String) { editingIDs.remove(id); let pending = commitTask; Task { [weak self] in await pending?.value; await self?.cloud.releaseLease(id) } }
    func lockedByOther(_ itemId: String) -> String? { leases.first { $0.itemId == itemId && $0.sessionId != cloud.sessionId && $0.expiresAt > Int(Date().timeIntervalSince1970*1000) }.map { $0.name ?? "Another editor" } }
    func commitText(_ id: String, text: String) { change("Edit script") { try TimingEngine.updateText(&$0,entryId:id,text:text) } }
    func setDuration(_ id: String, seconds: Double) { guard seconds.isFinite, seconds >= 0, seconds <= 3600 else { errorMessage = "Duration must be between zero and one hour."; return }; change("Change duration") { try TimingEngine.setOwnedDuration(&$0,entryId:id,durationMs:Int((seconds*1000).rounded())) } }
    func setCoverage(_ id: String, endMs: Int) { change("Extend direction") { try TimingEngine.setCoverage(&$0,entryId:id,endMs:endMs) } }
    func selectEntry(_ id: String) { selectedEntryID = id; if let entry = project.entries.first(where: { $0.id == id }) { selectedSceneID = entry.sceneId; seek(toMs:Double(project.startMs(of:id))); cloud.presence(itemId:id) } }
    func selectCharacter(_ id: String) { selectedCharacterID = id; tab = .characters; cloud.presence(itemId:id) }
    func setEntryCharacter(_ id: String, characterId: String?) { change("Change speaker") { p in if let i = p.entries.firstIndex(where: { $0.id == id }) { p.entries[i].characterId = characterId } } }
    func updatePresence(itemId: String?, selectionStart: Int, selectionEnd: Int) { cloud.presence(itemId:itemId,selection:.object(["start":.number(Double(selectionStart)),"end":.number(Double(selectionEnd))])) }
    func seek(toMs: Double) {
        guard toMs.isFinite else { return }; playheadMs = min(max(0,toMs),Double(sceneDurationMs))
        selectedCueID = project.activeCue(at:Int(playheadMs),sceneId:selectedSceneID)?.id ?? (Int(playheadMs) == sceneDurationMs ? sceneCues.last?.id : nil)
        if followPlayback, let entry = project.activeEntry(at:Int(playheadMs),sceneId:selectedSceneID) { selectedEntryID = entry.id }
    }
    func togglePlayback() {
        if isPlaying { isPlaying = false; playbackTask?.cancel(); return }
        if playheadMs >= Double(sceneDurationMs) { playheadMs = 0 }
        guard sceneDurationMs > 0 else { return }
        isPlaying = true
        let start = ContinuousClock.now, offset = playheadMs
        playbackTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isPlaying else { return }
                let elapsed = start.duration(to:.now).components
                self.seek(toMs:offset+Double(elapsed.seconds)*1000+Double(elapsed.attoseconds)/1e15)
                if self.playheadMs >= Double(self.sceneDurationMs) { self.isPlaying = false; return }
                try? await Task.sleep(for:.milliseconds(16))
            }
        }
    }
    func addEntry(kind: EntryKind) {
        let id = UUID().uuidString, sceneId = selectedSceneID, sequence = sceneEntries
        let selectedIndex = sequence.firstIndex { $0.id == selectedEntryID }
        let order = selectedIndex.map { i in i+1 < sequence.count ? (sequence[i].order+sequence[i+1].order)/2 : sequence[i].order+1 } ?? ((sequence.last?.order ?? -1)+1)
        change(kind == .direction ? "Add direction" : "Add dialogue") { p in
            let entry = ScriptEntry(id:id,sceneId:sceneId,order:order,kind:kind,text:kind == .direction ? "Direction" : "New line",characterId:kind == .dialogue ? p.characters.first?.id : nil,ownedDurationMs:kind == .direction ? 0 : 3000,coverageDurationMs:kind == .direction ? 3000 : 0)
            let insertionStart = p.entries(in:sceneId).filter { $0.order < order }.reduce(0) { $0+$1.ownedDurationMs }
            for index in p.cues.indices where p.cues[index].sceneId == sceneId { if p.cues[index].startMs >= insertionStart { p.cues[index].startMs += entry.ownedDurationMs }; if p.cues[index].endMs >= insertionStart { p.cues[index].endMs += entry.ownedDurationMs } }
            p.entries.append(entry)
            if p.cues(in:sceneId).isEmpty && entry.ownedDurationMs > 0 { p.cues.append(ImageCue(sceneId:sceneId,label:"01A",startMs:0,endMs:entry.ownedDurationMs)) }
        }
        selectedEntryID = id
    }
    func deleteEntry(_ id: String) {
        change("Delete line") { p in
            guard let entry = p.entries.first(where: { $0.id == id }) else { return }
            let start = p.startMs(of:id), end = start+entry.ownedDurationMs
            func map(_ time: Int) -> Int { time <= start ? time : time < end ? start : time-entry.ownedDurationMs }
            for i in p.cues.indices where p.cues[i].sceneId == entry.sceneId { p.cues[i].startMs = map(p.cues[i].startMs); p.cues[i].endMs = map(p.cues[i].endMs) }
            p.cues.removeAll { $0.endMs <= $0.startMs }; p.entries.removeAll { $0.id == id }
        }
        if selectedEntryID == id { selectedEntryID = sceneEntries.first?.id }
    }
    func moveEntry(_ id: String, offset: Int) {
        let sequence = sceneEntries
        guard let index = sequence.firstIndex(where: { $0.id == id }), sequence.indices.contains(index+offset) else { return }
        change("Move line") { p in
            let other = sequence[index+offset]
            guard let a = p.entries.firstIndex(where: { $0.id == id }), let b = p.entries.firstIndex(where: { $0.id == other.id }) else { return }
            let value = p.entries[a].order; p.entries[a].order = p.entries[b].order; p.entries[b].order = value
            // Image timing stays on the scene clock. Source words and direction anchors follow their new positions.
        }
    }
    func addScene() { let scene = ScriptScene(title:"INT. NEW SCENE — DAY",order:Double(project.scenes.count)); change("Add scene") { $0.scenes.append(scene) }; selectedSceneID = scene.id; selectedEntryID = nil; selectedCueID = nil; seek(toMs:0) }
    func updateSceneTitle(_ title: String) { change("Rename scene") { p in if let index = p.scenes.firstIndex(where: { $0.id == selectedSceneID }) { p.scenes[index].title = title } } }
    func setProjectTitle(_ title: String) { let clean = title.trimmingCharacters(in:.whitespacesAndNewlines); guard !clean.isEmpty else { return }; change("Rename project") { $0.title = clean }; if project.cloudProjectId != nil { perform { try await self.cloud.renameProject(clean) } } }
    func splitCue(_ id: String) { change("Split image") { try TimingEngine.splitCue(&$0,cueId:id,atMs:Int(playheadMs)) } }
    func moveBoundary(leftId: String, rightId: String, toMs: Int) { change("Move image cut") { try TimingEngine.moveBoundary(&$0,leftCueId:leftId,rightCueId:rightId,toMs:toMs) } }
    func moveWords(_ wordIds: Set<String>, fromCueId: String, toCueId: String) { change("Move words to image") { try TimingEngine.moveWords(&$0,wordIds:wordIds,fromCueId:fromCueId,toCueId:toCueId) }; selectedWordIDs = [] }
    func updateCuePrompt(_ id: String, prompt: String) { change("Edit image direction") { p in if let index = p.cues.firstIndex(where: { $0.id == id }) { p.cues[index].prompt = prompt } } }
    func addCharacter() { let character = ScriptCharacter(name:"New character"); change("Add character") { $0.characters.append(character) }; selectedCharacterID = character.id }
    func updateCharacter(_ character: ScriptCharacter) { change("Edit character") { p in if let i = p.characters.firstIndex(where: { $0.id == character.id }) { p.characters[i] = character } } }
    func deleteCharacter(_ id: String) { change("Delete character") { p in p.characters.removeAll { $0.id == id }; for i in p.entries.indices where p.entries[i].characterId == id { p.entries[i].characterId = nil }; for i in p.images.indices { p.images[i].characterIds.removeAll { $0 == id } } }; if selectedCharacterID == id { selectedCharacterID = project.characters.first?.id } }
    func setCharacterTags(imageId: String, characterIds: [String]) { change("Tag characters") { p in if let index = p.images.firstIndex(where: { $0.id == imageId }) { p.images[index].characterIds = Array(Set(characterIds)).sorted() } } }
    func assetURL(_ asset: ImageAsset) -> URL? {
        guard let projectURL, asset.fileName == URL(fileURLWithPath:asset.fileName).lastPathComponent, !asset.fileName.contains("..") else { return nil }
        let directory = projectURL.appendingPathComponent("assets").resolvingSymlinksInPath(), url = directory.appendingPathComponent(asset.fileName).resolvingSymlinksInPath()
        guard url.deletingLastPathComponent() == directory, FileManager.default.fileExists(atPath:url.path) else { return nil }; return url
    }
    func importImage(cueId: String? = nil) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png,.jpeg,UTType(filenameExtension:"webp") ?? .image]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let target = cueId ?? selectedCueID ?? currentCue?.id
        perform { try await self.attachImage(url: url,cueId:target,prompt:"Imported image",expectedCue:nil) }
    }
    private func attachImage(url: URL, cueId: String?, prompt: String, expectedCue: ImageCue?, expectedRevision: Int? = nil) async throws {
        guard let package = projectURL else { throw ScrivError.unavailable("Save this project before importing images.") }
        let sourceProjectID = project.id
        let attributes = try url.resourceValues(forKeys:[.fileSizeKey]); guard (attributes.fileSize ?? 0) <= 25*1024*1024 else { throw ScrivError.invalid("Choose an image smaller than 25 MiB.") }
        let data = try Data(contentsOf:url)
        guard NSImage(data:data) != nil else { throw ScrivError.invalid("The image file could not be decoded.") }
        let asset = try await repo().importAsset(data:data,at:package,prompt:prompt)
        guard project.id == sourceProjectID else { return }
        var stale = false
        if let expectedCue { stale = project.cues.first(where: { $0.id == expectedCue.id }) != expectedCue }
        if let expectedRevision, project.revision != expectedRevision { stale = true }
        change(stale ? "Keep generated candidate" : "Attach image") { p in
            var version = asset
            if let cueId, let index = p.cues.firstIndex(where: { $0.id == cueId }), !stale {
                if let previous = p.asset(p.cues[index].imageId) { version.version = previous.version+1; version.previousVersionId = previous.id; version.characterIds = previous.characterIds }
                p.cues[index].imageId = version.id
            }
            p.images.append(version)
        }
        if stale { statusMessage = "Generated image kept in project images; the scene changed during generation." }
        if let cloudId = project.cloudProjectId, cloudProjects.first(where: { $0.id == cloudId })?.teamId != nil {
            await commitTask?.value
            guard project.id == sourceProjectID, cloud.projectId == cloudId else { return }
            do { try await cloud.upload(asset,data:data) } catch { errorMessage = "Image is saved locally; cloud upload failed: \(error.localizedDescription)" }
        }
    }
    func generateImage(cueId: String? = nil) {
        let target = project.cues.first { $0.id == (cueId ?? selectedCueID) } ?? currentCue
        guard let target else { errorMessage = "Add a timed image cue before generating."; return }
        let prompt = generationPrompt.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? target.prompt : generationPrompt
        let projectId = project.id, revision = project.revision
        let referenceURLs = project.characters.compactMap { character in project.asset(character.portraitImageId).flatMap(assetURL) }
        perform {
            let result = try await self.codex.generate(prompt:prompt,references:referenceURLs)
            guard self.project.id == projectId else { self.statusMessage = "Image generated; retained in local generation files because another project is open."; return }
            try await self.attachImage(url:result,cueId:target.id,prompt:prompt,expectedCue:target,expectedRevision:revision)
        }
    }
    func downloadImage(_ asset: ImageAsset, silent: Bool = false) {
        guard !mediaRequests.contains(asset.sha256), peerDiscoveries[asset.sha256] == nil else { return }
        let contextID = project.id
        mediaRequests.insert(asset.sha256)
        perform(reportErrors:!silent) {
            defer { self.mediaRequests.remove(asset.sha256) }
            guard self.project.id == contextID, let package = self.projectURL else { return }
            let projectID = self.project.id
            do {
                let data = try await self.cloud.download(asset)
                guard projectID == self.project.id else { return }
                try await self.repo().storeReplica(data,for:asset,at:package)
                self.refreshPeerAuthorization(); self.objectWillChange.send(); self.fetchMissingImages()
            } catch {
                // Free projects and offline replicas use authorized peers. A missing replica never becomes a fake image.
                guard projectID == self.project.id else { return }
                let devices = try await self.cloud.peerDevices()
                let candidates = devices.compactMap { $0["deviceId"]?.string ?? $0["id"]?.string }.filter { $0 != self.cloud.deviceId }
                guard !candidates.isEmpty else { throw ScrivError.unavailable("No hosted image or other authorized Mac is available. Open this project on a Mac that has the image, then retry.") }
                await self.peerTask?.value
                let requestID = UUID().uuidString
                self.peerDiscoveries[asset.sha256] = requestID; self.peerTransferStarted.remove(asset.sha256)
                self.peerTransferStatus = "Looking for a Mac that has this image…"
                for peer in candidates.prefix(40) {
                    try await self.cloud.signal(PeerSignal(toDeviceId:peer,type:"asset-request",payload:.object(["action":.string("query"),"hash":.string(asset.sha256),"requestId":.string(requestID)])))
                }
                Task { [weak self] in
                    try? await Task.sleep(for:.seconds(65))
                    guard let self, self.project.id == projectID, self.peerDiscoveries[asset.sha256] == requestID else { return }
                    self.peerDiscoveries.removeValue(forKey:asset.sha256); self.peerTransferStarted.remove(asset.sha256)
                    self.peerTransferStatus = "No peer delivered the image. Keep the source Mac open and retry."
                }
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
        navigationGeneration += 1; let navigation = navigationGeneration
        await flushPendingSaves()
        let loaded = try await repo().load(at:url), checkpoint = try await repo().checkpoint(at:url)
        guard navigationGeneration == navigation else { throw CancellationError() }
        cloud.disconnect(); canonicalCheckpoint = checkpoint; dirtyItems = [:]; hasConflicts = false; isSyncing = false; pauseRemoteUpdates = false
        project = loaded; projectURL = url; selectedSceneID = loaded.scenes.first?.id ?? ""; selectedEntryID = loaded.entries(in:selectedSceneID).first?.id
        selectedCueID = loaded.cues(in:selectedSceneID).first?.id; selectedCharacterID = loaded.characters.first?.id; selectedWordIDs = []; editingIDs = []
        let savedHistory = try await repo().history(at:url,through:loaded.revision)
        guard navigationGeneration == navigation else { throw CancellationError() }
        history = savedHistory; undoStack = []; redoStack = []; isPlaying = false; playheadMs = 0
        activeThread = nil; messages = []; discussionItemID = nil; cloudHistory = []
        UserDefaults.standard.set(url.path,forKey:"lastProjectURL"); refreshPeerAuthorization(); onProjectChanged?(project,projectURL)
        if loaded.cloudProjectId != nil, account != nil { syncProject() }
    }
    private func install(_ value: ScrivProject) {
        navigationGeneration += 1
        cloud.disconnect(); canonicalCheckpoint = nil; dirtyItems = [:]; hasConflicts = false; isSyncing = false; pauseRemoteUpdates = false
        project = value; projectURL = rootURL.appendingPathComponent(value.id).appendingPathExtension("scriv"); selectedSceneID = value.scenes.first?.id ?? ""
        selectedEntryID = value.entries(in:selectedSceneID).first?.id; selectedCueID = value.cues(in:selectedSceneID).first?.id; selectedCharacterID = value.characters.first?.id
        history = []; undoStack = []; redoStack = []; isPlaying = false; playheadMs = 0; selectedWordIDs = []; editingIDs = []; activeThread = nil; messages = []; cloudHistory = []
        saveProject(); onProjectChanged?(project,projectURL)
    }
    func saveProject() { queueSave(project,label:"Save project") }
    func flushPendingSaves() async { await saveTask?.value }
    func importScript() {
        finishEditing()
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.plainText,.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let data = try Data(contentsOf:url); guard data.count <= 16*1024*1024 else { throw ScrivError.invalid("Script imports are limited to 16 MiB.") }; var imported: ScrivProject; if url.pathExtension.lowercased() == "json" { imported = try ScrivJSON.decoder.decode(ScrivProject.self,from:data); try TimingEngine.validate(imported); imported.id = UUID().uuidString; imported.cloudProjectId = nil } else { guard let text = String(data:data,encoding:.utf8) else { throw ScrivError.invalid("Save the script as UTF-8 text or Fountain.") }; imported = Fountain.parse(text,title:url.deletingPathExtension().lastPathComponent) }; install(imported) } catch { errorMessage = error.localizedDescription }
    }
    func exportScript() { let panel = NSSavePanel(); panel.nameFieldStringValue = project.title+".fountain"; guard panel.runModal() == .OK, let url = panel.url else { return }; do { try Fountain.export(project).write(to:url,atomically:true,encoding:.utf8) } catch { errorMessage = error.localizedDescription } }
    func exportProject() { let panel = NSSavePanel(); panel.nameFieldStringValue = project.title+".scriv"; panel.canCreateDirectories = true; guard panel.runModal() == .OK, let url = panel.url, let source = projectURL else { return }; perform { await self.flushPendingSaves(); try await self.repo().copyPackage(from:source,to:url); self.statusMessage = "Project exported with local images and history" } }
    func undo() { guard let previous = undoStack.popLast() else { return }; let current = project; redoStack.append(current); restoreContent(previous,label:"Undo",registerUndo:false) }
    func redo() { guard let next = redoStack.popLast() else { return }; undoStack.append(project); restoreContent(next,label:"Redo",registerUndo:false) }
    private func restoreContent(_ snapshot: ScrivProject, label: String, registerUndo: Bool = true) { let oldUndo = undoStack, oldRedo = redoStack; change(label) { p in let cloudId = p.cloudProjectId, id = p.id, rev = p.revision; p = snapshot; p.id = id; p.cloudProjectId = cloudId; p.revision = rev }; if !registerUndo { undoStack = oldUndo; redoStack = oldRedo } }
    func restoreHistory(_ entry: HistoryEntry) { finishEditing(); restoreContent(entry.snapshot,label:"Restore revision \(entry.revision)") }
    func restoreCloudHistory(_ event: CloudEvent) {
        finishEditing(); let contextID = project.id
        perform {
            await self.flushPendingSaves(); await self.commitTask?.value
            guard self.project.id == contextID else { return }
            self.pauseRemoteUpdates = true; defer { if self.project.id == contextID { self.pauseRemoteUpdates = false } }
            try await self.cloud.restore(seq:event.seq)
            guard self.project.id == contextID else { return }
            self.dirtyItems = [:]; self.hasConflicts = false; self.canonicalCheckpoint = nil; self.pauseRemoteUpdates = false
            self.applyRemote(Array(self.cloud.items.values)); self.cloudHistory = try await self.cloud.history()
        }
    }
    func signIn() { perform { try await self.cloud.signIn(); self.readCloudState() } }
    func signOut() { perform { try await self.cloud.signOut(); self.readCloudState() } }
    func createTeam(name: String) { perform { _ = try await self.cloud.createTeam(name:name); self.readCloudState() } }
    func joinTeam(token: String) { let raw = token.trimmingCharacters(in:.whitespacesAndNewlines); let parsed = URL(string:raw); let clean = parsed?.scheme != nil ? parsed!.lastPathComponent : raw; guard !clean.isEmpty && !clean.contains("/") else { errorMessage = "Paste a valid team invitation link or token."; return }; perform { try await self.cloud.joinTeam(token:clean); self.readCloudState() } }
    func createJoinLink(teamId: String) { perform { let url = try await self.cloud.joinLink(teamId:teamId); self.lastJoinLink = url.absoluteString; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString,forType:.string); self.statusMessage = "Team invitation copied" } }
    func checkout(teamId: String) { perform { NSWorkspace.shared.open(try await self.cloud.billing(teamId:teamId,portal:false)) } }
    func billingPortal(teamId: String) { perform { NSWorkspace.shared.open(try await self.cloud.billing(teamId:teamId,portal:true)) } }
    func syncProject(teamId: String? = nil) {
        finishEditing()
        guard account != nil else { signIn(); return }
        guard !isSyncing else { return }
        let contextID = project.id
        isSyncing = true
        perform {
            await self.commitTask?.value
            guard self.project.id == contextID else { return }
            self.isSyncing = true; self.pauseRemoteUpdates = true
            defer { if self.project.id == contextID { self.isSyncing = false; self.pauseRemoteUpdates = false } }
            let draft = self.project
            if let existing = self.project.cloudProjectId {
                if let checkpoint = self.canonicalCheckpoint, checkpoint.serverURL != self.cloud.baseURL.absoluteString || checkpoint.accountId != self.account?.id {
                    throw ScrivError.permission("This project's cloud copy belongs to a different server or account. Sign in with its original account, or export a separate local copy.")
                }
                let metadata = self.cloudProjects.first { $0.id == existing }
                _ = try await self.cloud.attach(projectId:existing,realtime:self.isPremiumProject(metadata))
                try await self.cloud.retryPendingCommands()
                guard self.project.id == contextID, self.project.revision == draft.revision else { throw ScrivError.conflict("New local edits arrived during reconnect. They are saved; sync again to include them.") }
                if self.cloud.headSeq == 0 && self.cloud.items.isEmpty {
                    try await self.cloud.seed(draft)
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
                    self.recordCheckpoint()
                    guard self.project.id == contextID, self.project.revision == draft.revision else { throw ScrivError.conflict("New edits remain saved locally. Sync once more to send them.") }
                    if reconciled != self.project {
                        var next = reconciled; next.revision = self.project.revision+1; next.modifiedAt = ScrivClock.now
                        self.project = next; self.queueSave(next,label:"Reconcile cloud changes"); self.onProjectChanged?(next,self.projectURL)
                    }
                }
            } else {
                let created = try await self.cloud.createProject(draft,teamId:teamId)
                guard self.project.id == contextID else { return }
                self.project.cloudProjectId = created.id; self.queueSave(self.project,label:"Enable cloud sync")
                await self.flushPendingSaves()
                _ = try await self.cloud.attach(projectId:created.id,realtime:false)
                try await self.cloud.seed(draft)
                self.recordCheckpoint()
                guard self.project.revision == draft.revision else { throw ScrivError.conflict("New edits remain local while the first copy uploads. Sync again to include them.") }
                if self.isPremiumProject(created) { _ = try await self.cloud.attach(projectId:created.id,realtime:true) }
            }
            guard self.project.id == contextID else { return }
            self.dirtyItems = [:]; self.hasConflicts = false; self.recordCheckpoint(); self.refreshPeerAuthorization()
            if self.isPremiumProject(self.cloudProjects.first { $0.id == self.project.cloudProjectId }), let package = self.projectURL {
                for asset in self.project.images where self.assetURL(asset) != nil {
                    let data = try await self.repo().assetData(asset,at:package)
                    guard self.project.id == contextID else { return }
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
            }
            guard self.project.id == contextID else { return }
            self.install(copy)
            await self.flushPendingSaves()
            self.syncProject(teamId:teamId)
        }
    }
    func openCloudProject(_ remote: CloudProject) {
        finishEditing(); navigationGeneration += 1; let navigation = navigationGeneration
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
            var loaded = try CloudCodec.applying(snapshot.items,to:base)
            loaded.title = remote.title; loaded.revision = base.revision+1; loaded.modifiedAt = ScrivClock.now
            let previousHistory = try await self.repo().history(at:package,through:base.revision)
            guard self.navigationGeneration == navigation else { return }
            try self.cloud.keepPendingAsLocalDrafts()
            self.dirtyItems = [:]; self.hasConflicts = false; self.canonicalCheckpoint = nil; self.project = loaded; self.projectURL = package
            self.selectedSceneID = loaded.scenes.first?.id ?? ""; self.selectedEntryID = loaded.entries(in:self.selectedSceneID).first?.id; self.selectedCueID = loaded.cues(in:self.selectedSceneID).first?.id; self.selectedCharacterID = loaded.characters.first?.id
            self.playheadMs = 0; self.isPlaying = false; self.selectedWordIDs = []; self.editingIDs = []; self.undoStack = []; self.redoStack = []; self.activeThread = nil; self.messages = []
            self.history = previousHistory; self.queueSave(loaded,label:"Open cloud project"); self.recordCheckpoint(); self.refreshPeerAuthorization()
            self.cloudHistory = try await self.cloud.history()
            guard self.navigationGeneration == navigation else { return }
            self.readCloudState(); self.onProjectChanged?(loaded,package); self.fetchMissingImages()
        }
    }
    func loadDiscussion(itemId: String?) {
        discussionItemID = itemId; messages = []; activeThread = nil; discussionReplyToID = nil; discussionAttachments = []; showDiscussion = true
        guard project.cloudProjectId != nil, account != nil else { return }
        let contextProjectID = project.id
        let anchor: JSONValue? = selectedWordIDs.isEmpty ? nil : .object(["wordIds":.array(selectedWordIDs.sorted().map(JSONValue.string))])
        perform {
            let thread = try await self.cloud.thread(itemId:itemId,anchor:anchor)
            guard self.discussionItemID == itemId, self.project.id == contextProjectID else { return }
            self.activeThread = thread
            let loaded = try await self.cloud.messages(threadId:thread.id)
            guard self.activeThread?.id == thread.id, self.discussionItemID == itemId, self.project.id == contextProjectID else { return }
            var byID = Dictionary(uniqueKeysWithValues:loaded.map { ($0.id,$0) }); for message in self.messages { byID[message.id] = message }
            self.messages = byID.values.sorted { ($0.createdAt ?? $0.at ?? 0,$0.id) < ($1.createdAt ?? $1.at ?? 0,$1.id) }
        }
    }
    func sendMessage(_ text: String) {
        let body = text.trimmingCharacters(in:.whitespacesAndNewlines); guard !body.isEmpty else { return }
        let contextID = project.id, itemID = discussionItemID, existingThread = activeThread, replyID = discussionReplyToID, attachments = discussionAttachments
        let fingerprint = ScrivDigest.sha256((try? ScrivJSON.encoder.encode(JSONValue.array([.string(contextID),itemID.map(JSONValue.string) ?? .null,.string(body),replyID.map(JSONValue.string) ?? .null,.array(attachments)]))) ?? Data())
        let messageID = pendingMessageIDs[fingerprint] ?? UUID().uuidString; pendingMessageIDs[fingerprint] = messageID
        perform {
            guard self.project.id == contextID else { return }
            let thread: DiscussionThread
            if let existingThread { thread = existingThread } else { thread = try await self.cloud.thread(itemId:itemID) }
            guard self.project.id == contextID else { return }
            if self.discussionItemID == itemID { self.activeThread = thread }
            let message = try await self.cloud.postMessage(threadId:thread.id,text:body,replyToId:replyID,attachments:attachments,messageId:messageID)
            self.pendingMessageIDs.removeValue(forKey:fingerprint)
            guard self.project.id == contextID, self.activeThread?.id == message.threadId else { return }
            if !self.messages.contains(where: { $0.id == message.id }) { self.messages.append(message) }
            if self.discussionReplyToID == replyID, self.discussionAttachments == attachments { self.discussionReplyToID = nil; self.discussionAttachments = [] }
        }
    }
    func resolveThread() { guard let thread = activeThread else { return }; let contextID = project.id; perform { let updated = try await self.cloud.resolve(threadId:thread.id,resolved:!thread.resolved); if self.project.id == contextID, self.activeThread?.id == thread.id { self.activeThread = updated } } }
    func handleOpenURL(_ url: URL) {
        if url.isFileURL && url.pathExtension == "scriv" { perform { try await self.open(url) }; return }
        if url.scheme == "scriv", url.host == "join" { joinTeam(token:url.lastPathComponent) }
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
        if !discussionAttachments.contains(.object(value)) { discussionAttachments.append(.object(value)) }
    }
    /// Deterministic local sample used by the native visual-verification runner.
    func prepareSampleForScreenshot() async {
        await bootstrapTask?.value
        await flushPendingSaves()
        install(.example())
        do { try await installSampleImages(); await flushPendingSaves() } catch { errorMessage = error.localizedDescription }
        selectedEntryID = "line-08"; selectedCueID = "cue-08b"; playheadMs = 5000
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
        peerTask?.cancel(); peerMedia.disconnect(); peerDiscoveries = [:]; peerTransferStarted = []; automaticMediaAttempts = []; peerProjectId = cloud.projectId
        guard let projectID = cloud.projectId, let deviceID = cloud.deviceId else { return }
        peerTask = Task { [weak self] in
            guard let self else { return }
            do {
                let configuration = try await self.cloud.peerConfiguration()
                guard self.cloud.projectId == projectID, !Task.isCancelled else { return }
                try await self.peerMedia.start(deviceId:deviceID,iceServers:configuration)
                guard self.cloud.projectId == projectID, !Task.isCancelled else { self.peerMedia.disconnect(); return }
                self.refreshPeerAuthorization()
            } catch { self.peerTransferStatus = "Peer transfer unavailable: " + error.localizedDescription }
        }
    }
    private func refreshPeerAuthorization() {
        var available: [String:URL] = [:]
        for asset in project.images { if let url = assetURL(asset) { available[asset.sha256] = url } }
        peerMedia.authorize(knownHashes:Set(project.images.map(\.sha256)),localAssets:available)
    }
    private func handleAssetDiscovery(_ signal: PeerSignal) async throws {
        guard let sender = signal.fromDeviceId, let hash = signal.payload["hash"]?.string,
              let requestID = signal.payload["requestId"]?.string, let asset = project.images.first(where: { $0.sha256 == hash }) else { return }
        if signal.payload["action"]?.string == "query" {
            guard assetURL(asset) != nil else { return }
            try await cloud.signal(PeerSignal(toDeviceId:sender,type:"asset-request",payload:.object(["action":.string("available"),"hash":.string(hash),"requestId":.string(requestID)])))
        } else if signal.payload["action"]?.string == "available", peerDiscoveries[hash] == requestID, !peerTransferStarted.contains(hash) {
            peerTransferStarted.insert(hash)
            try await peerMedia.requestAsset(hash:hash,fromDeviceId:sender)
        }
    }
    private func receivedPeerAsset(hash: String, data: Data) {
        peerDiscoveries.removeValue(forKey:hash); peerTransferStarted.remove(hash)
        guard let asset = project.images.first(where: { $0.sha256 == hash }), let package = projectURL else { return }
        let projectID = project.id
        perform {
            try await self.repo().storeReplica(data,for:asset,at:package)
            guard self.project.id == projectID else { return }
            self.refreshPeerAuthorization(); self.objectWillChange.send(); self.statusMessage = "Peer image received and verified"; self.fetchMissingImages()
        }
    }
    private func perform(reportErrors: Bool = true, _ work: @escaping @MainActor () async throws -> Void) { Task { do { try await work() } catch is CancellationError { } catch { if reportErrors { errorMessage = error.localizedDescription } else { peerTransferStatus = error.localizedDescription } } } }
}
