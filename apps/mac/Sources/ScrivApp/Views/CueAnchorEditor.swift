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
        VStack(alignment: .leading, spacing: 19) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Picture source").font(.system(size: 25, weight: .semibold))
                Text(selection.cue.label.isEmpty ? "Image placement" : selection.cue.label)
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let image = store.project.asset(selection.cue.imageId) {
                        AssetImageView(url: store.assetURL(image), title: selection.cue.label, unavailableText: "Not on this Mac")
                            .frame(width: 190, height: 107)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Follow this script entry").font(.system(size: 13, weight: .semibold))
                        Picker("Follow this script entry", selection: $entryID) {
                            Text("Choose an entry…").tag("")
                            ForEach(store.project.entries(in: selection.cue.sceneId)) { candidate in
                                Text(CueAnchorEditor.label(candidate, project: store.project)).tag(candidate.id)
                            }
                        }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                        if let entry {
                            Text(entry.text.isEmpty ? "Untitled entry" : entry.text)
                                .font(.system(size: 14)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                .background(ScrivTheme.accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ScrivTheme.accent.opacity(0.15)))
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Offset from entry").font(.system(size: 13, weight: .semibold))
                        HStack(spacing: 9) {
                            TextField("Offset from entry", text: $offset).textFieldStyle(.roundedBorder).frame(width: 110)
                                .disabled(entry == nil || entry?.ownedDurationMs == 0)
                            Text("seconds").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        if let entry {
                            Text(entry.ownedDurationMs == 0 ? "This zero-owned direction starts at its authored position; its offset is 0." : "Within this entry’s " + ScrivFormat.duration(entry.ownedDurationMs) + " owned slot.")
                                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Forward coverage").font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Text(ScrivFormat.duration(selection.cue.authoredDurationMs ?? selection.cue.durationMs)).font(.system(size: 14, weight: .medium)).monospacedDigit()
                        }
                        Text("Coverage stays authored, even when it overlaps another picture or reaches beyond the current scene.")
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    ScrivNotice(title: "Moves with its source", message: "Other pictures and audio stay unchanged.")
                    if let validation { ScrivNotice(tone: .error, title: "Source not saved", message: validation) }
                }
            }
            Divider()
            HStack {
                if !ready { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(ScrivSecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Save source", action: save).buttonStyle(ScrivPrimaryButtonStyle()).keyboardShortcut(.defaultAction).disabled(!ready || entry == nil)
            }
        }.padding(24).frame(width: 530, height: 690).background(ScrivTheme.sheetBackground)
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
