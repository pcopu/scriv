import SwiftUI
import AppKit
import ScrivCore

struct ScriptEditorView: View {
    @EnvironmentObject private var store: WorkspaceStore
    var compact = false
    @State private var entryFrames: [String: CGRect] = [:]
    @State private var editingID: String?
    @State private var showHistory = false
    @State private var search = ""
    @State private var showSearch = false
    @State private var searchIndex = 0
    @State private var searchSelectionID: String?
    @State private var sceneTitle = ""
    @State private var renamingScene = false
    @State private var deletingScene = false
    private let coordinateSpace = "script-layout"

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 18).padding(.top, 17).padding(.bottom, 12)
            if showSearch {
                HStack(spacing: 6) {
                    TextField("Find in script", text: $search).textFieldStyle(.roundedBorder)
                        .onSubmit { advanceSearch(by: NSEvent.modifierFlags.contains(.shift) ? -1 : 1) }
                    Text(search.isEmpty ? "" : searchMatches.isEmpty ? "0 results" : "\(min(searchIndex + 1, searchMatches.count)) / \(searchMatches.count)")
                        .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit().fixedSize()
                    IconButton(symbol: "chevron.up", label: "Previous matching entry") { advanceSearch(by: -1) }.disabled(searchMatches.isEmpty)
                    IconButton(symbol: "chevron.down", label: "Next matching entry") { advanceSearch(by: 1) }.disabled(searchMatches.isEmpty)
                    IconButton(symbol: "xmark", label: "Close script search") { search = ""; showSearch = false }
                }.padding(.horizontal, 18).padding(.bottom, 8)
            }
            Divider().opacity(0.25)
            ScrollViewReader { proxy in
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: compact ? 5 : ScrivTheme.scriptRowSpacing) {
                            ForEach(store.sceneEntries) { entry in
                                ScriptRow(entry: entry, compact: compact, editingID: $editingID, search: search)
                                    .id(entry.id).measureFrame(entry.id, in: coordinateSpace)
                            }
                            addEntryBar.padding(.leading, compact ? 90 : ScrivTheme.scriptGutter).padding(.top, 8)
                        }.padding(.vertical, 20).padding(.horizontal, compact ? 10 : 14)
                        if !compact { DirectionRailOverlay(entries: store.sceneEntries, frames: entryFrames) }
                    }.coordinateSpace(name: coordinateSpace)
                        .onPreferenceChange(ViewFramePreference.self) { entryFrames = $0 }
                }
                .task(id: store.selectedSceneID) {
                    await Task.yield()
                    guard !compact, let id = store.selectedEntryID else { return }
                    proxy.scrollTo(id, anchor: .center)
                }
                .onChange(of: store.selectedEntryID) { _, id in
                    guard store.followPlayback, store.isPlaying, let id else { return }
                    withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                }
                .onChange(of: search) { _, _ in
                    searchIndex = 0; searchSelectionID = searchMatches.first?.id
                    if let id = searchSelectionID { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                }
                .onChange(of: searchSelectionID) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                }
            }
            footer
        }.background(ScrivTheme.panel).clipShape(RoundedRectangle(cornerRadius: 17))
            .sheet(isPresented: $showHistory) { HistorySheet().environmentObject(store) }
            .confirmationDialog("Delete this scene?", isPresented: $deletingScene, titleVisibility: .visible) {
                Button("Delete scene", role: .destructive) { store.deleteScene(store.selectedSceneID) }
            } message: { Text("The scene's script and image placements will be removed. Image assets and character profiles are kept.") }
            .alert("Rename scene", isPresented: $renamingScene) {
                TextField("Scene name", text: $sceneTitle)
                Button("Cancel", role: .cancel) {}
                Button("Rename") { store.updateSceneTitle(sceneTitle) }
            }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "doc.text").font(.system(size: 19, weight: .regular)).foregroundStyle(ScrivTheme.accent)
                .frame(width: 34, height: 36).background(ScrivTheme.inset, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 9) {
                    Text("Script").font(.system(size: compact ? 18 : 23, weight: .semibold))
                    if !store.peers.isEmpty {
                        PresenceAvatars().environmentObject(store)
                    }
                }
                Menu {
                    ForEach(store.project.scenes.sorted { $0.order < $1.order }) { scene in
                        Button(scene.title) { store.selectScene(scene.id) }
                    }
                    Divider()
                    Button("New scene", systemImage: "plus") { store.addScene() }
                    Button("Rename scene…") {
                        sceneTitle = store.project.scenes.first { $0.id == store.selectedSceneID }?.title ?? ""
                        renamingScene = true
                    }
                    Button("Delete scene…", role: .destructive) { deletingScene = true }
                } label: {
                    HStack(spacing: 5) {
                        Text(store.project.scenes.first { $0.id == store.selectedSceneID }?.title ?? "No scene")
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    }.font(.system(size: 12)).foregroundStyle(.secondary)
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            Spacer(minLength: 0)
            IconButton(symbol: "magnifyingglass", label: "Find in script", prominent: showSearch) { withAnimation { showSearch.toggle(); if !showSearch { search = "" } } }
            if !compact {
                Button { showHistory = true } label: { Label("History", systemImage: "clock.arrow.circlepath").font(.system(size: 12)) }
                    .buttonStyle(.bordered).controlSize(.regular)
            }
        }
    }
    private var searchMatches: [ScriptEntry] {
        guard !search.isEmpty else { return [] }
        return store.sceneEntries.filter { entry in
            if entry.text.localizedCaseInsensitiveContains(search) { return true }
            guard let character = store.project.character(entry.characterId) else { return false }
            return ([character.name] + character.aliases).contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }
    private func advanceSearch(by offset: Int) {
        guard !searchMatches.isEmpty else { return }
        searchIndex = (searchIndex + offset + searchMatches.count) % searchMatches.count
        searchSelectionID = searchMatches[searchIndex].id
    }
    private var addEntryBar: some View {
        HStack(spacing: 12) {
            Button { store.addEntry(kind: .dialogue) } label: { Label("Dialogue", systemImage: "plus") }
            Button { store.addEntry(kind: .direction) } label: { Label("Direction", systemImage: "arrow.turn.down.right") }
        }.font(.system(size: 11, weight: .medium)).buttonStyle(.borderless).foregroundStyle(ScrivTheme.accent)
    }
    private var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: saveSymbol)
                .foregroundStyle(saveColor).font(.system(size: 11)).help(store.statusMessage + (store.hasConflicts ? " · Cloud changes need review" : ""))
            Text("\(store.project.authoredEntryCount(in: store.selectedSceneID)) entries · \(ScrivFormat.duration(store.sceneDurationMs))").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if compact {
                Button { store.togglePlayback() } label: {
                    Label(store.isPlaying ? "Pause script" : "Play script", systemImage: store.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .medium))
                }.buttonStyle(.borderedProminent).controlSize(.regular).disabled(store.sceneDurationMs <= 0)
                    .help("Play the scene's editorial timing (Option–Space)")
            } else {
                Toggle("Follow playback", isOn: $store.followPlayback).toggleStyle(.switch).controlSize(.mini).font(.system(size: 11))
            }
        }.padding(.horizontal, 18).padding(.vertical, 12)
    }
    private var saveSymbol: String {
        if store.statusMessage == "Save failed" || store.hasConflicts { return "exclamationmark.circle.fill" }
        return store.isSyncing || store.statusMessage == "Saving…" ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill"
    }
    private var saveColor: Color {
        if store.statusMessage == "Save failed" { return .red }
        if store.hasConflicts { return .orange }
        return store.isSyncing || store.statusMessage == "Saving…" ? ScrivTheme.secondary : .green
    }
}

private struct ScriptRow: View {
    @EnvironmentObject private var store: WorkspaceStore
    let entry: ScriptEntry
    let compact: Bool
    @Binding var editingID: String?
    let search: String
    @State private var draft = ""
    @State private var acquiring = false
    @State private var editDebounce: Task<Void, Never>?
    @State private var editAcquisition: Task<Void, Never>?
    @State private var acquisitionID: UUID?
    @State private var editingSessionActive = false
    @State private var editContext: Int?
    @FocusState private var isFocused: Bool
    private var isEditing: Bool { editingID == entry.id }
    private var start: Int { store.project.startMs(of: entry.id) }
    private var direction: Bool { entry.kind == .direction }
    private var selected: Bool { store.selectedEntryID == entry.id }
    private var active: Bool { store.isPlaying && Int(store.playheadMs) >= start && Int(store.playheadMs) < start + entry.ownedDurationMs }
    private var rowColor: Color { direction ? ScrivTheme.color(entry.color) : ScrivTheme.ink }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 5) {
                DurationPill(milliseconds: entry.ownedDurationMs, editable: store.lockedByOther(entry.id) == nil, minimumMilliseconds: direction ? 0 : max(1, entry.words.count)) { store.setDuration(entry.id, seconds: Double($0) / 1000) }
                Text(ScrivFormat.time(start)).font(.system(size: compact ? 11 : 13, design: .rounded)).foregroundStyle(.secondary)
            }.frame(width: compact ? 65 : 80).padding(.top, 2)
            Color.clear.frame(width: compact ? 12 : ScrivTheme.scriptGutter - 80)
            VStack(alignment: .leading, spacing: compact ? 3 : 7) {
                if !direction { speakerLabel }
                else if compact { Text("Direction").font(.system(size: 11)).italic().foregroundStyle(.secondary) }
                if isEditing {
                    LiveScriptTextEditor(text: $draft, pointSize: compact ? ScrivTheme.compactBodySize : ScrivTheme.scriptBodySize, italic: direction,
                        onSelection: { range in store.updatePresence(itemId: entry.id, selectionStart: range.location, selectionEnd: range.location + range.length) },
                        onFinish: finishEdit)
                        .onChange(of: draft) { _, value in
                            editDebounce?.cancel()
                            editDebounce = Task {
                                try? await Task.sleep(for: .milliseconds(250))
                                guard !Task.isCancelled, isEditing, editContext == store.navigationContext else { return }
                                store.commitText(entry.id, text: value)
                            }
                        }
                        .accessibilityLabel(direction ? "Direction text" : "Dialogue text")
                } else if !entry.text.isEmpty {
                    LinkedScriptText(text: entry.text, characters: store.project.characters, size: compact ? ScrivTheme.compactBodySize : ScrivTheme.scriptBodySize, direction: direction, color: rowColor,
                        activeWordIndex: entry.words.firstIndex(where: { $0.id == store.currentWordID }),
                        remoteSelections: store.peers.filter { $0.itemId == entry.id }) { store.selectCharacter($0) }
                } else {
                    Text(direction ? "Describe the action…" : "Write dialogue…").font(.system(size: compact ? ScrivTheme.compactBodySize : ScrivTheme.scriptBodySize)).foregroundStyle(.tertiary)
                }
                if selected && direction && !compact {
                    Text("Applies through \(ScrivFormat.time(start + entry.coverageDurationMs))")
                        .font(.system(size: 10)).foregroundStyle(rowColor.opacity(0.8))
                }
                if let lock = store.lockedByOther(entry.id) {
                    Label("\(lock) is editing", systemImage: "lock.fill").font(.system(size: 10, weight: .medium)).foregroundStyle(ScrivTheme.accent)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, compact ? 2 : 3)
            if acquiring { ProgressView().controlSize(.mini).padding(4) }
        }
        .padding(.vertical, compact ? 3 : 10).padding(.trailing, 10)
        .background((selected || active) ? ScrivTheme.accent.opacity(active ? 0.08 : 0.055) : matched ? Color.yellow.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { beginEdit() }
        .onTapGesture { store.selectEntry(entry.id) }
        .contextMenu {
            Button("Edit text", systemImage: "pencil") { beginEdit() }.disabled(store.lockedByOther(entry.id) != nil)
            Button("Discuss this \(direction ? "direction" : "line")", systemImage: "bubble.left") { store.loadDiscussion(itemId: entry.id); store.showDiscussion = true }
            Button("Play from here", systemImage: "play") { store.seek(toMs: Double(start)); if !store.isPlaying { store.togglePlayback() } }
            if !direction { Button("Import audio for this dialogue…", systemImage: "waveform.badge.plus") { store.importAudio(entryId: entry.id) } }
            Divider()
            Button("Move up", systemImage: "arrow.up") { store.moveEntry(entry.id, offset: -1) }.disabled(store.lockedByOther(entry.id) != nil)
            Button("Move down", systemImage: "arrow.down") { store.moveEntry(entry.id, offset: 1) }.disabled(store.lockedByOther(entry.id) != nil)
            Button("Delete entry", systemImage: "trash", role: .destructive) { store.deleteEntry(entry.id) }.disabled(store.lockedByOther(entry.id) != nil)
        }
        .onDisappear { cancelAcquisition(); finishEdit() }
        .onReceive(NotificationCenter.default.publisher(for: .scrivFinishEditing)) { _ in finishEdit() }
        .onChange(of: store.selectedEntryID) { _, id in
            if id != entry.id { cancelAcquisition(); if isEditing { finishEdit() } }
        }
        .onChange(of: editingID) { old, new in
            if old == entry.id && new != entry.id {
                completeEditingSession()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityHint("Double-click to edit. Context menu contains timing, discussion and reorder actions.")
    }
    private var matched: Bool {
        guard !search.isEmpty else { return false }
        if entry.text.localizedCaseInsensitiveContains(search) { return true }
        guard let character = store.project.character(entry.characterId) else { return false }
        return ([character.name] + character.aliases).contains { $0.localizedCaseInsensitiveContains(search) }
    }
    private var speakerLabel: some View {
        HStack(spacing: 5) {
            if let character = store.project.character(entry.characterId) {
                Button { store.selectCharacter(character.id) } label: {
                    Text(character.name.uppercased()).font(.system(size: compact ? 12 : 16, weight: .semibold))
                        .foregroundStyle(ScrivTheme.color(character.color)).padding(.horizontal, 5).padding(.vertical, 2)
                        .background(ScrivTheme.color(character.color).opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
                }.buttonStyle(.plain)
            } else { Text("DIALOGUE").font(.system(size: compact ? 10 : 11, weight: .semibold)).foregroundStyle(.secondary) }
            if isContinuation { Text("(CONT’D)").font(.system(size: compact ? 12 : 16)).foregroundStyle(ScrivTheme.secondary) }
            if selected {
                Menu {
                    Button("No speaker") { store.setEntryCharacter(entry.id, characterId: nil) }
                    ForEach(store.project.characters) { character in
                        Button(character.name) { store.setEntryCharacter(entry.id, characterId: character.id) }
                    }
                } label: { Image(systemName: "chevron.down").font(.system(size: 8)) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(store.lockedByOther(entry.id) != nil)
                Spacer()
                Button { beginEdit() } label: { Image(systemName: "pencil").font(.system(size: 10)) }.buttonStyle(.plain).foregroundStyle(.secondary).help("Edit line").disabled(store.lockedByOther(entry.id) != nil)
            }
        }
    }
    private var isContinuation: Bool {
        guard let speaker = entry.characterId, let index = store.sceneEntries.firstIndex(where: { $0.id == entry.id }), index > 0 else { return false }
        let preceding = store.sceneEntries[..<index].last { $0.ownedDurationMs > 0 }
        return preceding?.kind == .dialogue && preceding?.characterId == speaker
    }
    private func beginEdit() {
        guard !acquiring, !isEditing, store.lockedByOther(entry.id) == nil else { return }
        store.selectEntry(entry.id)
        acquiring = true
        let requestID = UUID(), projectID = store.project.id, context = store.navigationContext; acquisitionID = requestID
        editAcquisition = Task { @MainActor in
            let allowed = await store.beginEdit(entry.id)
            guard acquisitionID == requestID, !Task.isCancelled, store.project.id == projectID, store.navigationContext == context else {
                if allowed { store.endEdit(entry.id, context: context) }
                return
            }
            acquiring = false; acquisitionID = nil
            guard allowed else { return }
            guard let current = store.project.entries.first(where: { $0.id == entry.id }) else { store.endEdit(entry.id, context: context); return }
            draft = current.text; editContext = context; editingSessionActive = true; editingID = entry.id; isFocused = true
        }
    }
    private func cancelAcquisition() {
        acquisitionID = nil; editAcquisition?.cancel(); editAcquisition = nil; acquiring = false
    }
    private func completeEditingSession() {
        guard editingSessionActive else { return }
        editingSessionActive = false; editDebounce?.cancel()
        if editContext == store.navigationContext { store.commitText(entry.id, text: draft) }
        if let editContext { store.endEdit(entry.id, context: editContext) }
        editContext = nil
    }
    private func finishEdit() {
        guard isEditing || editingSessionActive else { return }
        completeEditingSession(); if editingID == entry.id { editingID = nil }; isFocused = false
    }
}

private struct DirectionRailOverlay: View {
    @EnvironmentObject private var store: WorkspaceStore
    let entries: [ScriptEntry]
    let frames: [String: CGRect]
    @State private var draggingEnd: [String: CGFloat] = [:]
    private let x: CGFloat = 112
    private let baseline: CGFloat = 26
    private var directions: [ScriptEntry] { entries.filter { $0.kind == .direction } }
    private var geometryRows: [ScriptRailRow] {
        entries.compactMap { entry in
            guard let frame = frames[entry.id] else { return nil }
            return ScriptRailRow(startMs: store.project.startMs(of: entry.id), durationMs: entry.ownedDurationMs,
                anchorY: Double(frame.minY + baseline), bottomY: Double(frame.maxY + ScrivTheme.scriptRowSpacing))
        }
    }
    private func endY(_ entry: ScriptEntry) -> CGFloat {
        let top = (frames[entry.id]?.minY ?? 0) + baseline
        return max(top + 12, draggingEnd[entry.id] ?? y(for: store.project.startMs(of: entry.id) + entry.coverageDurationMs))
    }
    private func overlapping(_ entry: ScriptEntry) -> [ScriptEntry] {
        let endpoint = endY(entry)
        let positions = Dictionary(uniqueKeysWithValues: directions.map { ($0.id, Double(endY($0))) })
        let coincident = Set(PresentationGeometry.coincidentHandles(selectedID: entry.id, positions: positions))
        return directions.filter { other in
            guard let frame = frames[other.id] else { return false }
            return coincident.contains(other.id) || (endpoint >= frame.minY + baseline - 14 && endpoint <= endY(other) + 14)
        }
    }
    var body: some View {
        GeometryReader { _ in
            ZStack(alignment: .topLeading) {
                ForEach(Array(directions.enumerated()), id: \.element.id) { index, entry in
                    if let frame = frames[entry.id] {
                        let color = ScrivTheme.color(entry.color)
                        let selected = store.selectedEntryID == entry.id
                        let top = frame.minY + baseline
                        let end = endY(entry)
                        // All coverage strokes occupy the same centerline. Phase,
                        // not lateral displacement, keeps overlapping colors visible.
                        Path { path in
                            path.move(to: CGPoint(x: x, y: end))
                            path.addLine(to: CGPoint(x: x, y: top + 9))
                        }.stroke(color.opacity(selected ? 1 : 0.85), style: StrokeStyle(lineWidth: selected ? 4 : 3,
                            lineCap: .butt, dash: [7, CGFloat(max(1, directions.count - 1)) * 7], dashPhase: CGFloat(index * 7)))
                            .allowsHitTesting(false)
                        Path { path in
                            path.move(to: CGPoint(x: x, y: top + 9))
                            path.addQuadCurve(to: CGPoint(x: x + 18, y: top), control: CGPoint(x: x, y: top))
                            path.addLine(to: CGPoint(x: ScrivTheme.scriptGutter + 5, y: top))
                        }.stroke(color, style: StrokeStyle(lineWidth: selected ? 3 : 2.5, lineCap: .round)).allowsHitTesting(false)
                        Path { path in
                            let tip = ScrivTheme.scriptGutter + 10
                            path.move(to: CGPoint(x: tip, y: top)); path.addLine(to: CGPoint(x: tip - 9, y: top - 5))
                            path.addLine(to: CGPoint(x: tip - 9, y: top + 5)); path.closeSubpath()
                        }.fill(color).allowsHitTesting(false)
                        Button { store.selectEntry(entry.id) } label: {
                            Circle().fill(color).frame(width: 12, height: 12).overlay(Circle().stroke(.white, lineWidth: 1.5)).padding(4)
                        }.buttonStyle(.plain).position(x: x, y: top).help("Select direction: " + entry.text)
                            .accessibilityLabel("Select direction: " + entry.text)
                        Button { store.selectEntry(entry.id) } label: {
                            Circle().fill(color).frame(width: selected ? 13 : 10, height: selected ? 13 : 10)
                                .overlay(Circle().stroke(.white, lineWidth: 1.5)).padding(8).contentShape(Circle())
                        }
                        .buttonStyle(.plain).position(x: x, y: end).zIndex(selected ? 2 : 1)
                        .disabled(store.lockedByOther(entry.id) != nil)
                        .gesture(DragGesture(minimumDistance: selected ? 0 : 8).onChanged { value in
                            if store.selectedEntryID != entry.id { store.selectEntry(entry.id) }
                            let ownedEnd = y(for: store.project.startMs(of: entry.id) + entry.ownedDurationMs)
                            draggingEnd[entry.id] = max(max(top + 12, ownedEnd), y(for: store.project.startMs(of: entry.id) + entry.coverageDurationMs) + value.translation.height)
                        }.onEnded { value in
                            guard abs(value.translation.height) >= 1 else { draggingEnd.removeValue(forKey: entry.id); return }
                            let minEnd = store.project.startMs(of: entry.id) + entry.ownedDurationMs
                            let result = max(minEnd, PresentationGeometry.railTime(at: Double(draggingEnd[entry.id] ?? end), rows: geometryRows))
                            draggingEnd.removeValue(forKey: entry.id)
                            store.setCoverage(entry.id, endMs: result)
                        })
                        .contextMenu { directionChoices(overlapping(entry)) }
                        .help("Drag to change coverage only. Control-click to choose an overlapping direction. " + entry.text)
                        .accessibilityLabel("Coverage end for " + entry.text)
                        .accessibilityValue(ScrivFormat.time(store.project.startMs(of: entry.id) + entry.coverageDurationMs))
                        .accessibilityAdjustableAction { adjustment in
                            let delta = adjustment == .increment ? 100 : -100
                            let start = store.project.startMs(of: entry.id)
                            store.setCoverage(entry.id, endMs: max(start + entry.ownedDurationMs, start + entry.coverageDurationMs + delta))
                        }
                        if selected && overlapping(entry).count > 1 {
                            Menu { directionChoices(overlapping(entry)) } label: {
                                HStack(spacing: 2) {
                                    Text("\(overlapping(entry).count)").font(.system(size: 10, weight: .semibold))
                                    Image(systemName: "chevron.down").font(.system(size: 7))
                                }.padding(4).background(ScrivTheme.panel, in: Capsule())
                                    .overlay(Capsule().strokeBorder(ScrivTheme.hairline))
                            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                                .position(x: x + 29, y: end).zIndex(3)
                                .accessibilityLabel("Choose overlapping direction")
                        }
                    }
                }
            }
        }
    }
    @ViewBuilder private func directionChoices(_ choices: [ScriptEntry]) -> some View {
        ForEach(choices) { candidate in
            Button { store.selectEntry(candidate.id) } label: {
                Label(candidate.text, systemImage: store.selectedEntryID == candidate.id ? "checkmark.circle.fill" : "circle.fill")
                    .foregroundStyle(ScrivTheme.color(candidate.color))
            }
        }
    }
    private func y(for time: Int) -> CGFloat { CGFloat(PresentationGeometry.railPosition(at: time, rows: geometryRows)) }
}
