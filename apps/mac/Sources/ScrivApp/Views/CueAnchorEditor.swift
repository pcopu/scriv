import SwiftUI
import ScrivCore

struct CueAnchorSelection: Identifiable {
    let cue: ImageCue
    let navigationContext: Int
    var id: String { cue.id }
}

struct CueAnchorEditor: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    let selection: CueAnchorSelection
    @State private var entryID: String
    @State private var offset: String
    @State private var ready = false
    @State private var validation: String?
    init(selection: CueAnchorSelection) {
        self.selection = selection
        _entryID = State(initialValue: selection.cue.startAnchor?.entryId ?? "")
        _offset = State(initialValue: String(format: "%.3f", Double(selection.cue.startAnchor?.offsetMs ?? 0) / 1000))
    }
    private var entry: ScriptEntry? { store.project.entries.first { $0.id == entryID && $0.sceneId == selection.cue.sceneId } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Picture source").font(.title2.weight(.semibold))
            Text(selection.cue.label.isEmpty ? "Image placement" : selection.cue.label).font(.headline)
            Text("Choose the dialogue or direction this picture belongs to. It follows that source when reordered; its forward coverage stays authored, even when it overlaps other pictures.")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                Picker("Source entry", selection: $entryID) {
                    Text("Choose an entry…").tag("")
                    ForEach(store.project.entries(in: selection.cue.sceneId)) { candidate in
                        Text(CueAnchorEditor.label(candidate, project: store.project)).tag(candidate.id)
                    }
                }
                TextField("Offset from source (seconds)", text: $offset)
                    .disabled(entry == nil || entry?.ownedDurationMs == 0)
            }.textFieldStyle(.roundedBorder)
            if let entry {
                Text(entry.ownedDurationMs == 0 ? "This zero-owned direction starts at its authored position; its picture offset is 0." : "Offset must be inside the source's \(ScrivFormat.duration(entry.ownedDurationMs)) owned slot.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Forward coverage: \(ScrivFormat.duration(selection.cue.authoredDurationMs ?? selection.cue.durationMs)). Other pictures and imported audio are not removed or blended.")
                .font(.caption).foregroundStyle(.secondary)
            if let validation { Text(validation).font(.caption).foregroundStyle(.red) }
            HStack {
                if !ready { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save source", action: save).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!ready || entry == nil)
            }
        }.padding(24).frame(width: 530)
            .onChange(of: entryID) { _, _ in offset = "0.000"; validation = nil }
            .task {
                let allowed = await store.beginEdit(selection.cue.id)
                guard !Task.isCancelled, store.navigationContext == selection.navigationContext, store.selectedSceneID == selection.cue.sceneId else {
                    if allowed { store.endEdit(selection.cue.id, context: selection.navigationContext) }; return
                }
                ready = allowed
                if !allowed { validation = "This picture cannot currently be edited. Close and retry when its lease is available." }
            }
            .onDisappear { if ready { store.endEdit(selection.cue.id, context: selection.navigationContext) } }
            .onChange(of: store.navigationContext) { _, value in if value != selection.navigationContext { dismiss() } }
            .onChange(of: store.selectedSceneID) { _, value in if value != selection.cue.sceneId { dismiss() } }
    }
    private func save() {
        guard ready, store.navigationContext == selection.navigationContext, store.selectedSceneID == selection.cue.sceneId, let entry,
              let current = store.project.cues.first(where: { $0.id == selection.id }) else { dismiss(); return }
        guard current == selection.cue else { validation = "This placement changed. Close and reopen the editor to review its current source."; return }
        guard let seconds = Double(offset), seconds.isFinite, seconds >= 0, seconds <= Double(entry.ownedDurationMs) / 1000 else {
            validation = "Enter an offset inside the selected source's owned slot."; return
        }
        let ms = Int((seconds * 1000).rounded())
        guard ms < entry.ownedDurationMs || entry.kind == .direction && entry.ownedDurationMs == 0 && ms == 0 else {
            validation = "The offset must be before the source's end; zero-owned directions use 0."; return
        }
        if current.startAnchor == ScriptTimeAnchor(entryId: entry.id, offsetMs: ms) { dismiss(); return }
        if store.setCueAnchor(cueId: current.id, entryId: entry.id, offsetMs: ms) { dismiss() }
        else { validation = store.errorMessage ?? "This source cannot own the placement at that offset." }
    }
    static func label(_ entry: ScriptEntry, project: ScrivProject) -> String {
        let kind = entry.kind == .direction ? "Direction" : project.character(entry.characterId)?.name ?? "Dialogue"
        return "\(kind) · \(entry.text.isEmpty ? "Untitled entry" : String(entry.text.prefix(70)))"
    }
}
