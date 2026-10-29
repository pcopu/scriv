import SwiftUI
import ScrivCore

struct WordTimingSelection: Identifiable {
    let entry: ScriptEntry
    let word: TimedWord
    let navigationContext: Int
    var id: String { word.id }
}

/// Editorial speech timing only. This never moves an image cut or modifies audio.
struct WordTimingEditor: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    let selection: WordTimingSelection
    @State private var start: String
    @State private var end: String
    @State private var ready = false
    @State private var validation: String?
    init(selection: WordTimingSelection) {
        self.selection = selection
        _start = State(initialValue: String(format: "%.3f", Double(selection.word.startMs) / 1000))
        _end = State(initialValue: String(format: "%.3f", Double(selection.word.endMs) / 1000))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Word timing").font(.title2.weight(.semibold))
            Text("“\(selection.word.text)”").font(.title3)
            Text("Set when this word happens, relative to its dialogue entry. Image cuts and imported recordings stay unchanged.")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                TextField("Start (seconds)", text: $start)
                TextField("End (seconds)", text: $end)
            }.textFieldStyle(.roundedBorder)
            Text("Entry length: \(ScrivFormat.duration(selection.entry.ownedDurationMs)). Trim this word or its neighbors to create room before dragging. Words stay in source order without overlapping.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Manual editorial timing — not speech recognition or audio alignment.").font(.caption).foregroundStyle(.secondary)
            if let validation { Text(validation).font(.caption).foregroundStyle(.red) }
            HStack {
                if !ready { ProgressView().controlSize(.small); Text("Acquiring edit lease…").font(.caption) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save timing", action: save).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!ready)
            }
        }.padding(24).frame(width: 470)
            .task {
                let allowed = await store.beginEdit(selection.entry.id)
                guard !Task.isCancelled, store.navigationContext == selection.navigationContext, store.selectedSceneID == selection.entry.sceneId else {
                    if allowed { store.endEdit(selection.entry.id, context: selection.navigationContext) }; return
                }
                ready = allowed
                if !allowed { validation = "This line cannot currently be edited. Close and retry when its edit lease is available." }
            }
            .onDisappear { if ready { store.endEdit(selection.entry.id, context: selection.navigationContext) } }
            .onChange(of: store.navigationContext) { _, value in if value != selection.navigationContext { dismiss() } }
            .onChange(of: store.selectedSceneID) { _, value in if value != selection.entry.sceneId { dismiss() } }
    }
    private func save() {
        guard ready, store.navigationContext == selection.navigationContext, store.selectedSceneID == selection.entry.sceneId,
              let entry = store.project.entries.first(where: { $0.id == selection.entry.id }),
              let current = entry.words.first(where: { $0.id == selection.word.id }) else { dismiss(); return }
        guard current == selection.word, entry.ownedDurationMs == selection.entry.ownedDurationMs else {
            validation = "This word changed while the editor was open. Close and reopen it to review its current timing."; return
        }
        guard let startSeconds = Double(start), let endSeconds = Double(end), startSeconds.isFinite, endSeconds.isFinite,
              startSeconds >= 0, endSeconds > startSeconds, endSeconds <= Double(entry.ownedDurationMs) / 1000 else {
            validation = "Enter a start and end within the dialogue entry, with end after start."; return
        }
        if store.setWordTiming(wordId: current.id, startMs: Int((startSeconds * 1000).rounded()), endMs: Int((endSeconds * 1000).rounded())) { dismiss() }
        else { validation = store.errorMessage ?? "Timing could not be changed. Keep words in order without overlaps." }
    }
}

struct WordTimelineBlock: View {
    @EnvironmentObject private var store: WorkspaceStore
    let entry: ScriptEntry
    let word: TimedWord
    let scale: CGFloat
    @State private var dragMs = 0
    @State private var dragContext: Int?
    @State private var originalWord: TimedWord?
    @State private var editor: WordTimingSelection?
    private var start: Int { store.project.startMs(of: entry.id) }
    private var active: Bool { store.currentWordID == word.id }
    private var availableDelta: ClosedRange<Int> {
        guard let index = entry.words.firstIndex(where: { $0.id == word.id }) else { return 0...0 }
        let lower = (index > 0 ? entry.words[index - 1].endMs : 0) - word.startMs
        let upper = (index + 1 < entry.words.count ? entry.words[index + 1].startMs : entry.ownedDurationMs) - word.endMs
        return min(0, lower)...max(0, upper)
    }
    var body: some View {
        Text(word.text).font(.system(size: 11)).lineLimit(1).minimumScaleFactor(0.7)
            .foregroundStyle(active ? Color.white : ScrivTheme.accent)
            .frame(width: max(3, CGFloat(word.endMs - word.startMs) * scale - 1), height: 28)
            .background(active ? ScrivTheme.accent : ScrivTheme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
            .overlay(alignment: .bottom) { if word.timingSource == .authored { Capsule().fill(ScrivTheme.accent).frame(height: 2).padding(.horizontal, 2) } }
            .offset(x: CGFloat(start + word.startMs + dragMs) * scale)
            .onTapGesture(count: 2, perform: edit)
            .onTapGesture { store.seek(toMs: Double(start + word.startMs)); store.selectedWordIDs = [word.id] }
            .gesture(DragGesture(minimumDistance: 4).onChanged { value in
                guard store.lockedByOther(entry.id) == nil else { return }
                if dragContext == nil { dragContext = store.navigationContext; originalWord = word }
                dragMs = clamped(Int((value.translation.width / scale).rounded()))
            }.onEnded { _ in
                let delta = dragMs, context = dragContext, original = originalWord
                dragMs = 0; dragContext = nil; originalWord = nil
                guard context == store.navigationContext, store.selectedSceneID == entry.sceneId,
                      store.project.entries.first(where: { $0.id == entry.id })?.words.first(where: { $0.id == word.id }) == original else { return }
                if delta == 0 {
                    store.errorMessage = "Trim this word or its neighbors in Edit word timing to create room before dragging. Source order stays fixed."
                } else { store.shiftWords(wordIds: [word.id], byMs: delta) }
            })
            .contextMenu {
                Button("Edit word timing…", systemImage: "clock", action: edit).disabled(store.lockedByOther(entry.id) != nil)
                Button("Play word") { store.seek(toMs: Double(start + word.startMs)) }
            }
            .help("\(word.text) · \(ScrivFormat.time(word.startMs))–\(ScrivFormat.time(word.endMs)) within line. Drag within available gaps; double-click to edit start/end. Image cuts stay fixed.")
            .accessibilityLabel("Word timing: \(word.text)")
            .accessibilityValue("\(ScrivFormat.time(word.startMs)) to \(ScrivFormat.time(word.endMs))")
            .accessibilityAdjustableAction { value in
                let delta = clamped(value == .increment ? 100 : -100)
                if delta != 0 { store.shiftWords(wordIds: [word.id], byMs: delta) }
            }
            .sheet(item: $editor) { WordTimingEditor(selection: $0).environmentObject(store) }
    }
    private func clamped(_ delta: Int) -> Int { min(availableDelta.upperBound, max(availableDelta.lowerBound, delta)) }
    private func edit() { editor = WordTimingSelection(entry: entry, word: word, navigationContext: store.navigationContext) }
}
