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
    @State private var sceneTitle = ""
    @State private var renamingScene = false
    private let coordinateSpace = "script-layout"

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 18).padding(.top, 17).padding(.bottom, 12)
            if showSearch {
                TextField("Find in script", text: $search).textFieldStyle(.roundedBorder).padding(.horizontal, 18).padding(.bottom, 10)
            }
            Divider().opacity(0.25)
            ScrollViewReader { proxy in
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: compact ? 10 : 17) {
                            ForEach(store.sceneEntries) { entry in
                                ScriptRow(entry: entry, compact: compact, editingID: $editingID, search: search)
                                    .id(entry.id).measureFrame(entry.id, in: coordinateSpace)
                            }
                            addEntryBar.padding(.leading, compact ? 90 : 146).padding(.top, 8)
                        }.padding(.vertical, 20).padding(.horizontal, compact ? 10 : 14)
                        if !compact { DirectionRailOverlay(entries: store.sceneEntries, frames: entryFrames) }
                    }.coordinateSpace(name: coordinateSpace)
                        .onPreferenceChange(ViewFramePreference.self) { entryFrames = $0 }
                }
                .onChange(of: store.selectedEntryID) { _, id in
                    guard store.followPlayback, store.isPlaying, let id else { return }
                    withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                }
                .onChange(of: search) { _, value in
                    guard !value.isEmpty, let entry = store.sceneEntries.first(where: { $0.text.localizedCaseInsensitiveContains(value) }) else { return }
                    withAnimation { proxy.scrollTo(entry.id, anchor: .center) }
                }
            }
            footer
        }.background(ScrivTheme.panel).clipShape(RoundedRectangle(cornerRadius: 17))
            .sheet(isPresented: $showHistory) { HistorySheet().environmentObject(store) }
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
                        Button(scene.title) { store.selectedSceneID = scene.id; store.seek(toMs: 0) }
                    }
                    Divider()
                    Button("New scene", systemImage: "plus") { store.addScene() }
                    Button("Rename scene…") {
                        sceneTitle = store.project.scenes.first { $0.id == store.selectedSceneID }?.title ?? ""
                        renamingScene = true
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(store.project.scenes.first { $0.id == store.selectedSceneID }?.title ?? "No scene")
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    }.font(.system(size: 12)).foregroundStyle(.secondary)
                }.menuStyle(.borderlessButton).fixedSize()
            }
            Spacer(minLength: 0)
            if !compact {
                IconButton(symbol: "magnifyingglass", label: "Find in script", prominent: showSearch) { withAnimation { showSearch.toggle() } }
                Button { showHistory = true } label: { Label("History", systemImage: "clock.arrow.circlepath").font(.system(size: 12)) }
                    .buttonStyle(.bordered).controlSize(.regular)
            }
        }
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
            Text("\(store.sceneEntries.count) entries · \(ScrivFormat.duration(store.sceneDurationMs))").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Toggle("Follow playback", isOn: $store.followPlayback).toggleStyle(.switch).controlSize(.mini).font(.system(size: 11))
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
                DurationPill(milliseconds: entry.ownedDurationMs, editable: store.lockedByOther(entry.id) == nil) { store.setDuration(entry.id, seconds: Double($0) / 1000) }
                Text(ScrivFormat.time(start)).font(.system(size: compact ? 10 : 11, design: .monospaced)).foregroundStyle(.secondary)
            }.frame(width: compact ? 65 : 72).padding(.top, 2)
            Color.clear.frame(width: compact ? 12 : 60)
            VStack(alignment: .leading, spacing: compact ? 3 : 7) {
                if !direction { speakerLabel }
                else if compact { Text("Direction").font(.system(size: 11)).italic().foregroundStyle(.secondary) }
                if isEditing {
                    LiveScriptTextEditor(text: $draft, pointSize: compact ? 13 : 17, italic: direction,
                        onSelection: { range in store.updatePresence(itemId: entry.id, selectionStart: range.location, selectionEnd: range.location + range.length) },
                        onFinish: finishEdit)
                        .onChange(of: draft) { _, value in
                            editDebounce?.cancel()
                            editDebounce = Task {
                                try? await Task.sleep(for: .milliseconds(250))
                                guard !Task.isCancelled, isEditing else { return }
                                store.commitText(entry.id, text: value)
                            }
                        }
                        .accessibilityLabel(direction ? "Direction text" : "Dialogue text")
                } else if !entry.text.isEmpty {
                    LinkedScriptText(text: entry.text, characters: store.project.characters, size: compact ? 13 : 17, direction: direction, color: rowColor,
                        activeWordIndex: store.isPlaying ? entry.words.firstIndex(where: { $0.id == store.currentWordID }) : nil,
                        remoteSelections: store.peers.filter { $0.itemId == entry.id }) { store.selectCharacter($0) }
                } else {
                    Text(direction ? "Describe the action…" : "Write dialogue…").font(.system(size: compact ? 13 : 17)).foregroundStyle(.tertiary)
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
        .padding(.vertical, compact ? 4 : 8).padding(.trailing, 10)
        .background((selected || active) ? ScrivTheme.accent.opacity(active ? 0.08 : 0.055) : matched ? Color.yellow.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { beginEdit() }
        .onTapGesture { store.selectEntry(entry.id) }
        .contextMenu {
            Button("Edit text", systemImage: "pencil") { beginEdit() }.disabled(store.lockedByOther(entry.id) != nil)
            Button("Discuss this \(direction ? "direction" : "line")", systemImage: "bubble.left") { store.loadDiscussion(itemId: entry.id); store.showDiscussion = true }
            Button("Play from here", systemImage: "play") { store.seek(toMs: Double(start)); if !store.isPlaying { store.togglePlayback() } }
            Divider()
            Button("Move up", systemImage: "arrow.up") { store.moveEntry(entry.id, offset: -1) }.disabled(store.lockedByOther(entry.id) != nil)
            Button("Move down", systemImage: "arrow.down") { store.moveEntry(entry.id, offset: 1) }.disabled(store.lockedByOther(entry.id) != nil)
            Button("Delete entry", systemImage: "trash", role: .destructive) { store.deleteEntry(entry.id) }.disabled(store.lockedByOther(entry.id) != nil)
        }
        .onDisappear { if isEditing { finishEdit() } }
        .onReceive(NotificationCenter.default.publisher(for: .scrivFinishEditing)) { _ in finishEdit() }
        .onChange(of: editingID) { old, new in
            if old == entry.id && new != entry.id {
                editDebounce?.cancel(); store.commitText(entry.id, text: draft); store.endEdit(entry.id)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityHint("Double-click to edit. Context menu contains timing, discussion and reorder actions.")
    }
    private var matched: Bool { !search.isEmpty && entry.text.localizedCaseInsensitiveContains(search) }
    private var speakerLabel: some View {
        HStack(spacing: 5) {
            if let character = store.project.character(entry.characterId) {
                Button { store.selectCharacter(character.id) } label: {
                    Text(character.name.uppercased()).font(.system(size: compact ? 11 : 12, weight: .semibold))
                        .foregroundStyle(ScrivTheme.color(character.color)).padding(.horizontal, 5).padding(.vertical, 2)
                        .background(ScrivTheme.color(character.color).opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
                }.buttonStyle(.plain)
            } else { Text("DIALOGUE").font(.system(size: compact ? 10 : 11, weight: .semibold)).foregroundStyle(.secondary) }
            if selected {
                Menu {
                    Button("No speaker") { store.setEntryCharacter(entry.id, characterId: nil) }
                    ForEach(store.project.characters) { character in
                        Button(character.name) { store.setEntryCharacter(entry.id, characterId: character.id) }
                    }
                } label: { Image(systemName: "chevron.down").font(.system(size: 8)) }.menuStyle(.borderlessButton).fixedSize().disabled(store.lockedByOther(entry.id) != nil)
                Spacer()
                Button { beginEdit() } label: { Image(systemName: "pencil").font(.system(size: 10)) }.buttonStyle(.plain).foregroundStyle(.secondary).help("Edit line").disabled(store.lockedByOther(entry.id) != nil)
            }
        }
    }
    private func beginEdit() {
        guard !acquiring, !isEditing, store.lockedByOther(entry.id) == nil else { return }
        acquiring = true
        Task {
            let allowed = await store.beginEdit(entry.id)
            acquiring = false
            guard allowed else { return }
            draft = entry.text; editingID = entry.id; isFocused = true
        }
    }
    private func finishEdit() { guard isEditing else { return }; editDebounce?.cancel(); store.commitText(entry.id, text: draft); store.endEdit(entry.id); editingID = nil; isFocused = false }
}

private struct DirectionRailOverlay: View {
    @EnvironmentObject private var store: WorkspaceStore
    let entries: [ScriptEntry]
    let frames: [String: CGRect]
    @State private var draggingEnd: [String: CGFloat] = [:]
    private let x: CGFloat = 96
    private var directions: [ScriptEntry] { entries.filter { $0.kind == .direction } }
    var body: some View {
        GeometryReader { _ in
            ZStack(alignment: .topLeading) {
                ForEach(Array(directions.enumerated()), id: \.element.id) { index, entry in
                    if let frame = frames[entry.id] {
                        let color = ScrivTheme.color(entry.color)
                        let selected = store.selectedEntryID == entry.id
                        let top = frame.minY + 24
                        let end = max(top + 12, draggingEnd[entry.id] ?? y(for: store.project.startMs(of: entry.id) + entry.coverageDurationMs))
                        Path { path in
                            path.move(to: CGPoint(x: x, y: end))
                            path.addLine(to: CGPoint(x: x, y: top + 9))
                            path.addQuadCurve(to: CGPoint(x: x + 18, y: top), control: CGPoint(x: x, y: top))
                            path.addLine(to: CGPoint(x: 145, y: top))
                        }.stroke(color.opacity(selected ? 1 : 0.8), style: StrokeStyle(lineWidth: selected ? 3 : 2.5, lineCap: .round, dash: selected ? [] : [6, 4], dashPhase: CGFloat(index * 3))).allowsHitTesting(false)
                        Path { path in
                            path.move(to: CGPoint(x: 151, y: top)); path.addLine(to: CGPoint(x: 143, y: top - 4)); path.addLine(to: CGPoint(x: 143, y: top + 4)); path.closeSubpath()
                        }.fill(color).allowsHitTesting(false)
                        Circle().fill(color).frame(width: 9, height: 9).position(x: x, y: top).allowsHitTesting(false)
                        Button { store.selectEntry(entry.id) } label: { Circle().fill(color).frame(width: selected ? 11 : 8, height: selected ? 11 : 8).padding(8).contentShape(Circle()) }
                            .buttonStyle(.plain).position(x: x, y: end)
                            .disabled(store.lockedByOther(entry.id) != nil)
                            .gesture(DragGesture(minimumDistance: selected ? 0 : 8).onChanged { value in
                                store.selectEntry(entry.id)
                                // Location is measured in the local handle; use the initial baseline plus translation.
                                draggingEnd[entry.id] = max(top + 12, y(for: store.project.startMs(of: entry.id) + entry.coverageDurationMs) + value.translation.height)
                            }.onEnded { _ in
                                let minEnd = store.project.startMs(of: entry.id) + entry.ownedDurationMs
                                let result = max(minEnd, milliseconds(for: draggingEnd[entry.id] ?? end))
                                draggingEnd.removeValue(forKey: entry.id)
                                store.setCoverage(entry.id, endMs: result)
                            })
                            .help("Drag downward to extend: \(entry.text)")
                            .accessibilityLabel("Coverage end for \(entry.text)")
                            .accessibilityAdjustableAction { direction in
                                let delta = direction == .increment ? 100 : -100
                                let start = store.project.startMs(of: entry.id)
                                store.setCoverage(entry.id, endMs: max(start + entry.ownedDurationMs, start + entry.coverageDurationMs + delta))
                            }
                    }
                }
            }
        }.allowsHitTesting(true)
    }
    private func y(for time: Int) -> CGFloat {
        let timed = entries.filter { $0.ownedDurationMs > 0 && frames[$0.id] != nil }
        guard let last = timed.last, let lastFrame = frames[last.id] else { return 0 }
        for entry in timed {
            let start = store.project.startMs(of: entry.id)
            guard time <= start + entry.ownedDurationMs, let frame = frames[entry.id] else { continue }
            let fraction = min(1, max(0, CGFloat(time - start) / CGFloat(max(1, entry.ownedDurationMs))))
            return frame.minY + 24 + fraction * max(24, frame.height + 17)
        }
        return lastFrame.maxY + 12
    }
    private func milliseconds(for position: CGFloat) -> Int {
        let timed = entries.filter { $0.ownedDurationMs > 0 && frames[$0.id] != nil }
        for entry in timed {
            guard let frame = frames[entry.id], position <= frame.maxY + 41 else { continue }
            let fraction = min(1, max(0, (position - frame.minY - 24) / max(24, frame.height + 17)))
            return store.project.startMs(of: entry.id) + Int((fraction * CGFloat(entry.ownedDurationMs) / 100).rounded()) * 100
        }
        return store.sceneDurationMs
    }
}
