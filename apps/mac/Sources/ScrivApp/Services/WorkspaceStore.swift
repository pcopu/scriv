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
    let codex = CodexController()
    let cloud = CloudClient()
    private var repository: ProjectRepository?
    private var playbackTask: Task<Void,Never>?
    private var saveTask: Task<Void,Never>?
    private var commitTask: Task<Void,Never>?
    private var dirtyItems: [String:Int] = [:]
    private var undoStack: [ScrivProject] = []
    private var redoStack: [ScrivProject] = []
    private var editingIDs: Set<String> = []
    private var rootURL: URL
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
        cloud.onEvent = { [weak self] event in guard let self else { return }; if !self.cloudHistory.contains(where: { $0.seq == event.seq }) { self.cloudHistory.insert(event,at:0) } }
        codex.onChange = { [weak self] in self?.objectWillChange.send() }
        Task { [weak self] in await self?.bootstrap() }
    }
    private func repo() throws -> ProjectRepository { guard let repository else { throw ScrivError.unavailable("Local project storage is unavailable. Check folder permissions.") }; return repository }
    private func bootstrap() async {
        if let path = UserDefaults.standard.string(forKey:"lastProjectURL"), FileManager.default.fileExists(atPath:path) {
            do { try await open(URL(fileURLWithPath:path)) } catch { errorMessage = "The last project could not open: \(error.localizedDescription)" }
        } else { saveProject() }
        await cloud.restoreSession()
    }
    private func readCloudState() { account = cloud.account; teams = cloud.teams; cloudProjects = cloud.projects; peers = cloud.peers; leases = cloud.leases; syncStatus = cloud.status }
    private func change(_ label: String, _ mutate: (inout ScrivProject) throws -> Void) {
        do {
            let before = project
            var next = before
            try mutate(&next); try TimingEngine.validate(next)
            guard next != before else { return }
            next.revision = before.revision + 1; next.modifiedAt = Date()
            undoStack.append(before); redoStack = []
            project = next
            let event = HistoryEntry(label:label,snapshot:next); history.insert(event,at:0)
            queueSave(next,label:label)
            if next.cloudProjectId != nil {
                let old = Dictionary(uniqueKeysWithValues:try CloudCodec.items(from:before).map { ($0.id,$0.data) })
                let new = Dictionary(uniqueKeysWithValues:try CloudCodec.items(from:next).map { ($0.id,$0.data) })
                let ids = Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }
                for id in ids { dirtyItems[id] = next.revision }
                enqueueCommit(before:before,after:next,label:label,changed:ids)
            }
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
            guard let self, self.project.id == after.id else { return }
            self.isSyncing = true
            do {
                try await self.cloud.commit(before:before,after:after,label:label)
                for id in changed where self.dirtyItems[id] == after.revision { self.dirtyItems.removeValue(forKey:id) }
                self.hasConflicts = !self.dirtyItems.isEmpty
                for id in changed where !self.editingIDs.contains(id) { await self.cloud.releaseLease(id) }
            } catch { self.errorMessage = error.localizedDescription; self.hasConflicts = true; self.syncStatus = "Draft saved locally — needs review" }
            self.isSyncing = false
        }
    }
    private func applyRemote(_ items: [CloudItem]) {
        do {
            var map = Dictionary(uniqueKeysWithValues:items.map { ($0.id,$0) })
            let local = Dictionary(uniqueKeysWithValues:try CloudCodec.items(from:project).map { ($0.id,$0) })
            for id in dirtyItems.keys { if let item = local[id] { map[id] = item } else { map.removeValue(forKey:id) } }
            let next = try CloudCodec.applying(Array(map.values),to:project)
            if next != project { var revised = next; revised.revision = project.revision+1; revised.modifiedAt = Date(); project = revised; queueSave(revised,label:"Live update"); onProjectChanged?(project,projectURL) }
        } catch { errorMessage = "The incoming project could not be applied safely: \(error.localizedDescription)" }
    }
    func beginEdit(_ id: String) async -> Bool {
        do { _ = try await cloud.acquireLease(id); editingIDs.insert(id); cloud.presence(itemId:id); return true }
        catch { errorMessage = error.localizedDescription; return false }
    }
    func endEdit(_ id: String) { editingIDs.remove(id); let pending = commitTask; Task { [weak self] in await pending?.value; await self?.cloud.releaseLease(id) } }
    func lockedByOther(_ itemId: String) -> String? { leases.first { $0.itemId == itemId && $0.sessionId != cloud.sessionId && $0.expiresAt > Int(Date().timeIntervalSince1970*1000) }.map { $0.name ?? "Another editor" } }
    func commitText(_ id: String, text: String) { change("Edit script") { try TimingEngine.updateText(&$0,entryId:id,text:text) } }
    func setDuration(_ id: String, seconds: Double) { guard seconds.isFinite else { return }; change("Change duration") { try TimingEngine.setOwnedDuration(&$0,entryId:id,durationMs:Int((seconds*1000).rounded())) } }
    func setCoverage(_ id: String, endMs: Int) { change("Extend direction") { try TimingEngine.setCoverage(&$0,entryId:id,endMs:endMs) } }
    func selectEntry(_ id: String) { selectedEntryID = id; if let entry = project.entries.first(where: { $0.id == id }) { selectedSceneID = entry.sceneId; seek(toMs:Double(project.startMs(of:id))); cloud.presence(itemId:id) } }
    func selectCharacter(_ id: String) { selectedCharacterID = id; tab = .characters; cloud.presence(itemId:id) }
    func setEntryCharacter(_ id: String, characterId: String?) { change("Change speaker") { p in if let i = p.entries.firstIndex(where: { $0.id == id }) { p.entries[i].characterId = characterId } } }
    func updatePresence(itemId: String?, selectionStart: Int, selectionEnd: Int) { cloud.presence(itemId:itemId,selection:.object(["start":.number(Double(selectionStart)),"end":.number(Double(selectionEnd))])) }
    func seek(toMs: Double) { guard toMs.isFinite else { return }; playheadMs = min(max(0,toMs),Double(sceneDurationMs)); if followPlayback, let entry = project.activeEntry(at:Int(playheadMs),sceneId:selectedSceneID) { selectedEntryID = entry.id } }
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
    func assetURL(_ asset: ImageAsset) -> URL? { guard let projectURL, asset.fileName == URL(fileURLWithPath:asset.fileName).lastPathComponent, !asset.fileName.contains("..") else { return nil }; let url = projectURL.appendingPathComponent("assets").appendingPathComponent(asset.fileName); return FileManager.default.fileExists(atPath:url.path) ? url : nil }
    func importImage(cueId: String? = nil) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png,.jpeg,UTType(filenameExtension:"webp") ?? .image]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let target = cueId ?? selectedCueID ?? currentCue?.id
        perform { try await self.attachImage(url: url,cueId:target,prompt:"Imported image",expectedCue:nil) }
    }
    private func attachImage(url: URL, cueId: String?, prompt: String, expectedCue: ImageCue?) async throws {
        guard let package = projectURL else { throw ScrivError.unavailable("Save this project before importing images.") }
        let data = try Data(contentsOf:url)
        let asset = try await repo().importAsset(data:data,at:package,prompt:prompt)
        var stale = false
        if let expectedCue { stale = project.cues.first(where: { $0.id == expectedCue.id }) != expectedCue }
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
            do { try await cloud.upload(asset,data:data) } catch { errorMessage = "Image is saved locally; cloud upload failed: \(error.localizedDescription)" }
        }
    }
    func generateImage(cueId: String? = nil) {
        let target = project.cues.first { $0.id == (cueId ?? selectedCueID) } ?? currentCue
        guard let target else { errorMessage = "Add a timed image cue before generating."; return }
        let prompt = generationPrompt.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? target.prompt : generationPrompt
        let projectId = project.id
        let referenceURLs = project.characters.compactMap { character in project.asset(character.portraitImageId).flatMap(assetURL) }
        perform {
            let result = try await self.codex.generate(prompt:prompt,references:referenceURLs)
            guard self.project.id == projectId else { self.statusMessage = "Image generated; retained in local generation files because another project is open."; return }
            try await self.attachImage(url:result,cueId:target.id,prompt:prompt,expectedCue:target)
        }
    }
    func downloadImage(_ asset: ImageAsset) { perform { guard let package = self.projectURL else { return }; let data = try await self.cloud.download(asset); _ = try await self.repo().importAsset(data:data,at:package,prompt:asset.prompt,characterIds:asset.characterIds); self.objectWillChange.send() } }
    func newProject() { install(.blank()) }
    func openProject() { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = false; panel.message = "Choose a .scriv project package"; guard panel.runModal() == .OK, let url = panel.url else { return }; perform { try await self.open(url) } }
    private func open(_ url: URL) async throws { let loaded = try await repo().load(at:url); cloud.disconnect(); dirtyItems = [:]; hasConflicts = false; project = loaded; projectURL = url; selectedSceneID = loaded.scenes.first?.id ?? ""; selectedEntryID = loaded.entries(in:selectedSceneID).first?.id; selectedCueID = loaded.cues(in:selectedSceneID).first?.id; selectedCharacterID = loaded.characters.first?.id; history = try await repo().history(at:url,through:loaded.revision); undoStack = []; redoStack = []; isPlaying = false; playheadMs = 0; UserDefaults.standard.set(url.path,forKey:"lastProjectURL"); onProjectChanged?(project,projectURL) }
    private func install(_ value: ScrivProject) { cloud.disconnect(); dirtyItems = [:]; hasConflicts = false; project = value; projectURL = rootURL.appendingPathComponent(value.id).appendingPathExtension("scriv"); selectedSceneID = value.scenes.first?.id ?? ""; selectedEntryID = value.entries(in:selectedSceneID).first?.id; selectedCueID = value.cues(in:selectedSceneID).first?.id; selectedCharacterID = value.characters.first?.id; history = []; undoStack = []; redoStack = []; isPlaying = false; playheadMs = 0; saveProject(); onProjectChanged?(project,projectURL) }
    func saveProject() { queueSave(project,label:"Save project") }
    func flushPendingSaves() async { await saveTask?.value }
    func importScript() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.plainText,.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let data = try Data(contentsOf:url); guard data.count <= 16*1024*1024 else { throw ScrivError.invalid("Script imports are limited to 16 MiB.") }; var imported: ScrivProject; if url.pathExtension.lowercased() == "json" { imported = try ScrivJSON.decoder.decode(ScrivProject.self,from:data); try TimingEngine.validate(imported); imported.id = UUID().uuidString; imported.cloudProjectId = nil } else { guard let text = String(data:data,encoding:.utf8) else { throw ScrivError.invalid("Save the script as UTF-8 text or Fountain.") }; imported = Fountain.parse(text,title:url.deletingPathExtension().lastPathComponent) }; install(imported) } catch { errorMessage = error.localizedDescription }
    }
    func exportScript() { let panel = NSSavePanel(); panel.nameFieldStringValue = project.title+".fountain"; guard panel.runModal() == .OK, let url = panel.url else { return }; do { try Fountain.export(project).write(to:url,atomically:true,encoding:.utf8) } catch { errorMessage = error.localizedDescription } }
    func exportProject() { let panel = NSSavePanel(); panel.nameFieldStringValue = project.title+".scriv"; panel.canCreateDirectories = true; guard panel.runModal() == .OK, let url = panel.url, let source = projectURL else { return }; perform { await self.flushPendingSaves(); try await self.repo().copyPackage(from:source,to:url); self.statusMessage = "Project exported with local images and history" } }
    func undo() { guard let previous = undoStack.popLast() else { return }; let current = project; redoStack.append(current); restoreContent(previous,label:"Undo",registerUndo:false) }
    func redo() { guard let next = redoStack.popLast() else { return }; undoStack.append(project); restoreContent(next,label:"Redo",registerUndo:false) }
    private func restoreContent(_ snapshot: ScrivProject, label: String, registerUndo: Bool = true) { let oldUndo = undoStack, oldRedo = redoStack; change(label) { p in let cloudId = p.cloudProjectId, id = p.id, rev = p.revision; p = snapshot; p.id = id; p.cloudProjectId = cloudId; p.revision = rev }; if !registerUndo { undoStack = oldUndo; redoStack = oldRedo } }
    func restoreHistory(_ entry: HistoryEntry) { restoreContent(entry.snapshot,label:"Restore revision \(entry.revision)") }
    func restoreCloudHistory(_ event: CloudEvent) { perform { try await self.cloud.restore(seq:event.seq); self.cloudHistory = try await self.cloud.history() } }
    func signIn() { perform { try await self.cloud.signIn(); self.readCloudState() } }
    func signOut() { perform { try await self.cloud.signOut(); self.readCloudState() } }
    func createTeam(name: String) { perform { _ = try await self.cloud.createTeam(name:name); self.readCloudState() } }
    func joinTeam(token: String) { let raw = token.trimmingCharacters(in:.whitespacesAndNewlines); let parsed = URL(string:raw); let clean = parsed?.scheme != nil ? parsed!.lastPathComponent : raw; guard !clean.isEmpty && !clean.contains("/") else { errorMessage = "Paste a valid team invitation link or token."; return }; perform { try await self.cloud.joinTeam(token:clean); self.readCloudState() } }
    func createJoinLink(teamId: String) { perform { let url = try await self.cloud.joinLink(teamId:teamId); self.lastJoinLink = url.absoluteString; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString,forType:.string); self.statusMessage = "Team invitation copied" } }
    func checkout(teamId: String) { perform { NSWorkspace.shared.open(try await self.cloud.billing(teamId:teamId,portal:false)) } }
    func billingPortal(teamId: String) { perform { NSWorkspace.shared.open(try await self.cloud.billing(teamId:teamId,portal:true)) } }
    func syncProject(teamId: String? = nil) {
        guard account != nil else { signIn(); return }
        perform {
            self.isSyncing = true; defer { self.isSyncing = false }
            if let existing = self.project.cloudProjectId {
                let metadata = self.cloudProjects.first { $0.id == existing }
                _ = try await self.cloud.attach(projectId:existing,realtime:metadata?.teamId != nil)
                // Never replace an offline draft automatically. Exact outbox replay either succeeds or exposes a conflict.
                try await self.cloud.retryPendingCommands()
                let remote = try CloudCodec.applying(Array(self.cloud.items.values),to:self.project)
                if remote.entries != self.project.entries || remote.cues != self.project.cues || remote.characters != self.project.characters || remote.images != self.project.images || remote.scenes != self.project.scenes {
                    self.hasConflicts = true; throw ScrivError.conflict("This Mac has an offline draft that differs from the cloud. Export a copy before opening the cloud version, or keep working locally.")
                }
            } else {
                let created = try await self.cloud.createProject(self.project,teamId:teamId)
                _ = try await self.cloud.attach(projectId:created.id,realtime:false)
                try await self.cloud.seed(self.project)
                self.project.cloudProjectId = created.id; self.queueSave(self.project,label:"Enable cloud sync")
                if teamId != nil { _ = try await self.cloud.attach(projectId:created.id,realtime:true) }
            }
            self.cloudHistory = try await self.cloud.history(); self.readCloudState()
        }
    }
    func openCloudProject(_ remote: CloudProject) {
        perform {
            await self.flushPendingSaves()
            let snapshot = try await self.cloud.attach(projectId:remote.id,realtime:remote.teamId != nil)
            let base = ScrivProject(id:remote.id,title:remote.title,cloudProjectId:remote.id)
            let loaded = try CloudCodec.applying(snapshot.items,to:base)
            self.dirtyItems = [:]; self.hasConflicts = false; self.project = loaded; self.projectURL = self.rootURL.appendingPathComponent(loaded.id).appendingPathExtension("scriv"); self.selectedSceneID = loaded.scenes.first?.id ?? ""; self.selectedEntryID = loaded.entries(in:self.selectedSceneID).first?.id; self.selectedCueID = loaded.cues(in:self.selectedSceneID).first?.id; self.playheadMs = 0; self.history = []; self.queueSave(loaded,label:"Open cloud project"); self.cloudHistory = try await self.cloud.history(); self.readCloudState(); self.onProjectChanged?(loaded,self.projectURL)
        }
    }
    func loadDiscussion(itemId: String?) {
        discussionItemID = itemId; messages = []; activeThread = nil; showDiscussion = true
        perform { let thread = try await self.cloud.thread(itemId:itemId); guard self.discussionItemID == itemId else { return }; self.activeThread = thread; self.messages = try await self.cloud.messages(threadId:thread.id) }
    }
    func sendMessage(_ text: String) {
        let body = text.trimmingCharacters(in:.whitespacesAndNewlines); guard !body.isEmpty else { return }
        perform { let thread: DiscussionThread; if let existing = self.activeThread { thread = existing } else { thread = try await self.cloud.thread(itemId:self.discussionItemID); self.activeThread = thread }; let message = try await self.cloud.postMessage(threadId:thread.id,text:body); if !self.messages.contains(where: { $0.id == message.id }) { self.messages.append(message) } }
    }
    func resolveThread() { guard let thread = activeThread else { return }; perform { self.activeThread = try await self.cloud.resolve(threadId:thread.id,resolved:!thread.resolved) } }
    func handleOpenURL(_ url: URL) {
        if url.isFileURL && url.pathExtension == "scriv" { perform { try await self.open(url) }; return }
        if url.scheme == "scriv", url.host == "join" { joinTeam(token:url.lastPathComponent) }
        // ASWebAuthenticationSession owns auth callbacks and validates the per-request state and PKCE verifier.
    }
    func retryCloudSync() { perform { try await self.cloud.retryPendingCommands(); self.readCloudState() } }
    func refreshAccount() { perform { try await self.cloud.refreshAccount(); self.readCloudState() } }
    private func perform(_ work: @escaping @MainActor () async throws -> Void) { Task { do { try await work() } catch { errorMessage = error.localizedDescription } } }
}
