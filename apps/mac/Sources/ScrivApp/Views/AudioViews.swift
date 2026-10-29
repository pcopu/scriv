import SwiftUI
import ScrivCore

/// Draw only measured PCM peaks. Zero amplitude remains a flat, silent baseline.
struct AudioWaveformView: View {
    let peaks: [Float]
    var color: Color = ScrivTheme.accent
    var body: some View {
        Canvas { context, size in
            let middle = size.height / 2
            var baseline = Path(); baseline.move(to: CGPoint(x: 0, y: middle)); baseline.addLine(to: CGPoint(x: size.width, y: middle))
            context.stroke(baseline, with: .color(color.opacity(0.22)), lineWidth: 0.5)
            guard !peaks.isEmpty else { return }
            let step = size.width / CGFloat(peaks.count)
            var bars = Path()
            for (index, value) in peaks.enumerated() where value.isFinite && value > 0 {
                let amplitude = CGFloat(min(1, max(0, value))) * max(0, middle - 1)
                let x = (CGFloat(index) + 0.5) * step
                bars.move(to: CGPoint(x: x, y: middle - amplitude)); bars.addLine(to: CGPoint(x: x, y: middle + amplitude))
            }
            context.stroke(bars, with: .color(color), style: StrokeStyle(lineWidth: min(2, max(0.5, step * 0.65)), lineCap: .round))
        }.accessibilityLabel(peaks.contains(where: { $0 > 0 }) ? "Measured audio waveform" : "Silent audio waveform")
    }
}

struct AudioLaneItem: Identifiable {
    let placement: AudioPlacement
    let lane: Int
    var id: String { placement.clipId }
    static func sceneTracks(project: ScrivProject, sceneID: String) -> [AudioLaneItem] {
        var ends: [Int] = [], result: [AudioLaneItem] = []
        for placement in AudioTimeline.placements(project: project, sceneId: sceneID) {
            let lane = ends.firstIndex { $0 <= placement.startMs } ?? ends.count
            if lane == ends.count { ends.append(placement.endMs) } else { ends[lane] = placement.endMs }
            result.append(AudioLaneItem(placement: placement, lane: lane))
        }
        return result
    }
}

struct LocalAudioSheet: View {
    let navigationContext: Int
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var editing: AudioClip?
    @State private var removing: AudioClip?
    private var clips: [AudioClip] { store.project.audioClips.filter { $0.sceneId == store.selectedSceneID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Local audio").font(.title2.weight(.semibold))
                    Text("Imported recordings stay in this project package; they are not uploaded or shared through Scriv Cloud.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                Menu {
                    Button("Import scene audio…") { store.importAudio(entryId: nil) }
                    if let entry = store.selectedEntry, entry.kind == .dialogue {
                        Button("Import audio for selected dialogue…") { store.importAudio(entryId: entry.id) }
                    }
                } label: { Label("Import audio", systemImage: "waveform.badge.plus") }
                Spacer()
                Label(store.audioStatus, systemImage: "internaldrive").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if clips.isEmpty {
                EmptyPanel(symbol: "waveform", title: "Add a recording or soundtrack", message: "Import real audio for this scene or a dialogue entry. Waveforms come from its decoded samples; importing does not transcribe or retime words.")
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(clips) { clip in
                            if let asset = store.project.audioAssets.first(where: { $0.id == clip.assetId }) {
                                audioRow(clip, asset: asset)
                            }
                        }
                    }
                }
            }
            Text("Entry-attached audio follows that entry when it moves. Scene tracks keep their scene time. Playback stops at the scene's end.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(22).frame(width: 780, height: 560)
            .onChange(of: store.navigationContext) { _, context in if context != navigationContext { dismiss() } }
            .sheet(item: $editing) { clip in AudioClipEditor(clip: clip, navigationContext: store.navigationContext).environmentObject(store) }
            .confirmationDialog("Remove this audio clip?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                Button("Remove clip", role: .destructive) { if let removing { store.deleteAudioClip(removing.id) }; removing = nil }
            } message: { Text("This removes the placement, not the original recording or script text.") }
    }
    private func audioRow(_ clip: AudioClip, asset: AudioAsset) -> some View {
        let placement = AudioTimeline.placements(project: store.project, sceneId: clip.sceneId).first { $0.clipId == clip.id }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: store.audioURL(asset) == nil ? "exclamationmark.triangle" : "waveform").foregroundStyle(store.audioURL(asset) == nil ? Color.orange : ScrivTheme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(asset.originalName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(clip.entryId.flatMap { id in store.project.entries.first(where: { $0.id == id }).map { "Entry · " + String($0.text.prefix(65)) } } ?? "Scene track")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { var changed = clip; changed.isMuted.toggle(); store.updateAudioClip(changed) } label: {
                    Image(systemName: clip.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }.buttonStyle(.plain).help(clip.isMuted ? "Unmute clip" : "Mute clip")
                Slider(value: Binding(get: { clip.volume }, set: { var changed = clip; changed.volume = $0; store.updateAudioClip(changed) }), in: 0...1)
                    .frame(width: 90).controlSize(.small).accessibilityLabel("Clip volume")
                Button("Trim / timing") { editing = clip }
                Button { removing = clip } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Remove audio clip")
            }
            if let placement {
                AudioWaveformView(peaks: AudioTimeline.waveform(for: placement, asset: asset), color: clip.isMuted ? .secondary : ScrivTheme.accent).frame(height: 38)
                HStack {
                    Text("\(ScrivFormat.time(placement.startMs)) – \(ScrivFormat.time(placement.endMs))")
                    Spacer()
                    if store.audioURL(asset) == nil { Text("Audio file unavailable on this Mac").foregroundStyle(.orange) }
                    else { Button("Play from here") { store.seek(toMs: Double(placement.startMs)); if !store.isPlaying { store.togglePlayback() } }.buttonStyle(.borderless) }
                }.font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Outside the scene's current duration. Adjust timing to hear this clip.").font(.caption).foregroundStyle(.orange)
            }
        }.padding(13).background(ScrivTheme.inset, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct AudioClipEditor: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    let navigationContext: Int
    @State private var draft: AudioClip
    @State private var offset: String
    @State private var source: String
    @State private var duration: String
    @State private var validation: String?
    init(clip: AudioClip, navigationContext: Int) {
        self.navigationContext = navigationContext
        _draft = State(initialValue: clip)
        _offset = State(initialValue: String(format: "%.3f", Double(clip.startMs) / 1000))
        _source = State(initialValue: String(format: "%.3f", Double(clip.sourceStartMs) / 1000))
        _duration = State(initialValue: String(format: "%.3f", Double(clip.durationMs) / 1000))
    }
    private var asset: AudioAsset? { store.project.audioAssets.first { $0.id == draft.assetId } }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Audio trim & timing").font(.title2.weight(.semibold))
            Text(asset?.originalName ?? "Recording").font(.caption).foregroundStyle(.secondary)
            Form {
                Picker("Anchor", selection: Binding(get: { draft.entryId }, set: changeAnchor)) {
                    Text("Scene time").tag(String?.none)
                    ForEach(store.project.entries(in: draft.sceneId)) { entry in
                        Text(String(entry.text.prefix(65))).tag(Optional(entry.id))
                    }
                }
                TextField(draft.entryId == nil ? "Scene start (seconds)" : "Offset from entry (seconds)", text: $offset)
                TextField("Source in (seconds)", text: $source)
                TextField("Duration (seconds)", text: $duration)
                HStack { Text("Clip volume"); Slider(value: $draft.volume, in: 0...1); Text("\(Int(draft.volume * 100))%").monospacedDigit().frame(width: 40) }
                Toggle("Mute clip", isOn: $draft.isMuted)
            }.formStyle(.grouped)
            if let asset { Text("Source length: \(ScrivFormat.duration(asset.durationMs)). Trimming changes this placement only.").font(.caption).foregroundStyle(.secondary) }
            if let validation { Text(validation).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 550, height: 440)
            .onChange(of: store.navigationContext) { _, context in if context != navigationContext { dismiss() } }
    }
    private func milliseconds(_ text: String, maximumMs: Int = AudioTimeline.maximumDurationMs) -> Int? {
        guard let value = Double(text), value.isFinite, value >= 0, value <= Double(maximumMs) / 1000 else { return nil }
        return Int((value * 1000).rounded())
    }
    private func changeAnchor(_ id: String?) {
        let currentOffset = milliseconds(offset, maximumMs: 86_400_000) ?? draft.startMs
        let absolute = (draft.entryId.map { store.project.startMs(of: $0) } ?? 0) + currentOffset
        draft.entryId = id
        let newOffset = max(0, absolute - (id.map { store.project.startMs(of: $0) } ?? 0))
        offset = String(format: "%.3f", Double(newOffset) / 1000)
    }
    private func save() {
        guard store.navigationContext == navigationContext else { dismiss(); return }
        guard let asset, let start = milliseconds(offset, maximumMs: 86_400_000), let sourceStart = milliseconds(source), let length = milliseconds(duration), length > 0,
              sourceStart < asset.durationMs, length <= asset.durationMs - sourceStart else {
            validation = "Use nonnegative times and a positive duration that fits inside the source recording."
            return
        }
        draft.startMs = start; draft.sourceStartMs = sourceStart; draft.durationMs = length
        store.updateAudioClip(draft); dismiss()
    }
}
