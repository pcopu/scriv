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
    @State private var selectedClipID: String?
    @State private var openingSceneID: String?
    private var clips: [AudioClip] { store.project.audioClips.filter { $0.sceneId == store.selectedSceneID } }
    private var sceneTitle: String { store.project.scenes.first { $0.id == store.selectedSceneID }?.title ?? "Scene" }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Local audio").font(.system(size: 22, weight: .semibold))
                    Text(store.project.title + " · " + sceneTitle).font(.system(size: 13)).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 12)
                Menu {
                    Button("Import scene audio…") { store.importAudio(entryId: nil) }
                    if let entry = store.selectedEntry, entry.kind == .dialogue {
                        Button("Import audio for selected dialogue…") { store.importAudio(entryId: entry.id) }
                    }
                } label: { Label("Import audio", systemImage: "waveform.badge.plus") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 15).padding(.vertical, 11)
                    .background(ScrivTheme.accent, in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityIdentifier("audio-import-menu")
                    .disabled(store.audioStatus == "Importing and measuring audio…")
                Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).padding(6)
                    .help("Close local audio").accessibilityLabel("Close local audio").keyboardShortcut(.cancelAction)
            }.padding(.horizontal, 22).padding(.vertical, 18)
            Divider()
            VStack(spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "lock.fill").foregroundStyle(.secondary)
                    Text("Stored in this project on this Mac · Not shared")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }.padding(14).background(ScrivTheme.inset, in: RoundedRectangle(cornerRadius: 10))

                if clips.isEmpty {
                    EmptyPanel(symbol: "waveform", title: "Add a recording or soundtrack", message: "Import audio for this scene or a selected dialogue line. Real recordings stay local; importing does not transcribe or retime words.")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 13) {
                            ForEach(clips) { clip in
                                if let asset = store.project.audioAssets.first(where: { $0.id == clip.assetId }) {
                                    LocalAudioClipCard(clip: clip, asset: asset, selected: selectedClipID == clip.id,
                                        select: { selectedClipID = clip.id },
                                        edit: { selectedClipID = clip.id; editing = clip },
                                        remove: { removing = clip })
                                }
                            }
                        }.padding(.bottom, 2)
                    }
                }
                VStack(alignment: .leading, spacing: 11) {
                    if !store.audioStatus.isEmpty {
                        Text(store.audioStatus).font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("local-audio-status")
                    }
                    Divider()
                    Label("Dialogue audio follows its line. Scene audio stays at its scene time.", systemImage: "info.circle")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(22)
        }
        .frame(width: 780, height: 680).background(ScrivTheme.panel)
        .accessibilityIdentifier("local-audio-sheet")
        .onAppear { openingSceneID = store.selectedSceneID; selectedClipID = clips.first?.id }
        .onChange(of: store.navigationContext) { _, context in if context != navigationContext { dismiss() } }
        .onChange(of: store.selectedSceneID) { _, scene in if scene != openingSceneID { dismiss() } }
        .onChange(of: clips.map(\.id)) { _, ids in
            if selectedClipID == nil || !ids.contains(selectedClipID ?? "") { selectedClipID = ids.first }
        }
        .sheet(item: $editing) { clip in AudioClipEditor(clip: clip, navigationContext: navigationContext).environmentObject(store) }
        .confirmationDialog("Remove this audio clip?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remove clip", role: .destructive) {
                if let removing, store.navigationContext == navigationContext { store.deleteAudioClip(removing.id) }
                removing = nil
            }
        } message: { Text("This removes the placement, not the original recording or script text.") }
    }
}

private struct LocalAudioClipCard: View {
    @EnvironmentObject private var store: WorkspaceStore
    let clip: AudioClip
    let asset: AudioAsset
    let selected: Bool
    let select: () -> Void
    let edit: () -> Void
    let remove: () -> Void
    private var placement: AudioPlacement? { AudioTimeline.placements(project: store.project, sceneId: clip.sceneId).first { $0.clipId == clip.id } }
    private var available: Bool { store.audioURL(asset) != nil }
    private var active: Bool { store.isPlaying && placement?.sourcePosition(at: Int(store.playheadMs)) != nil }
    private var anchorLabel: String {
        guard let id = clip.entryId, let entry = store.project.entries.first(where: { $0.id == id }) else { return "Scene track" }
        if let character = store.project.characters.first(where: { $0.id == entry.characterId }) { return "Follows " + character.name + "’s dialogue" }
        return entry.kind == .dialogue ? "Follows dialogue" : "Follows direction"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: available ? "waveform" : "exclamationmark.triangle")
                .font(.system(size: 22, weight: .light)).foregroundStyle(available ? ScrivTheme.accent : .orange)
                .frame(width: 40, height: 48)
                .background(ScrivTheme.panel, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(ScrivTheme.hairline))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { fileName; anchorBadge }
                        VStack(alignment: .leading, spacing: 6) { fileName; anchorBadge }
                    }
                    Spacer(minLength: 8)
                    Menu {
                        Button("Trim & timing…", action: edit)
                        Button(clip.isMuted ? "Unmute clip" : "Mute clip") { update { $0.isMuted.toggle() } }
                        Divider()
                        Button("Remove clip…", role: .destructive, action: remove)
                    } label: { Image(systemName: "ellipsis").frame(width: 26, height: 24) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .padding(3).background(ScrivTheme.panel.opacity(0.65), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(ScrivTheme.hairline))
                        .accessibilityLabel("Audio options for " + asset.originalName)
                }
                HStack(spacing: 16) {
                    Button(action: play) {
                        Image(systemName: active ? "pause.fill" : "play.fill")
                            .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 44, height: 44).background(ScrivTheme.accent, in: Circle())
                    }.buttonStyle(.plain).disabled(!available || placement == nil)
                        .opacity(available && placement != nil ? 1 : 0.4)
                        .help(active ? "Pause scene playback" : "Play the scene from this clip; overlapping audio plays together")
                        .accessibilityLabel(active ? "Pause scene playback" : "Play scene from " + asset.originalName)
                        .accessibilityIdentifier("audio-clip-play-" + clip.id)
                    if let placement {
                        AudioPlaybackWaveform(peaks: AudioTimeline.waveform(for: placement, asset: asset), playedFraction: (store.playheadMs - Double(placement.startMs)) / Double(max(1, placement.durationMs)), selected: selected, muted: clip.isMuted)
                            .frame(height: 42)
                        Text("\(ScrivFormat.time(placement.startMs))  –  \(ScrivFormat.time(placement.endMs))")
                            .font(.system(size: 13)).monospacedDigit().fixedSize()
                    } else {
                        Text("Outside the scene’s current duration. Adjust timing to hear this clip.")
                            .font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 12) {
                    Image(systemName: "speaker.wave.2.fill").foregroundStyle(.secondary).accessibilityHidden(true)
                    Slider(value: Binding(get: { clip.volume }, set: { value in update { $0.volume = value } }), in: 0...1)
                        .frame(maxWidth: 230).controlSize(.small).tint(ScrivTheme.accent)
                        .accessibilityLabel("Clip volume for " + asset.originalName)
                        .help("Clip volume: \(Int(clip.volume * 100))%")
                    Button { update { $0.isMuted.toggle() } } label: {
                        Image(systemName: clip.isMuted ? "speaker.slash.fill" : "speaker.wave.1.fill")
                            .font(.system(size: 15)).frame(width: 25, height: 28)
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                        .help(clip.isMuted ? "Unmute clip" : "Mute clip")
                        .accessibilityLabel((clip.isMuted ? "Unmute " : "Mute ") + asset.originalName)
                    Spacer(minLength: 5)
                    Button("Trim & timing", action: edit).buttonStyle(.bordered).controlSize(.large).tint(ScrivTheme.accent)
                        .accessibilityIdentifier("audio-clip-trim-" + clip.id)
                }
                if !available {
                    Label("Audio file unavailable on this Mac. Restore the recording in this project package, or import it again.", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
        }.padding(18)
        .background(selected ? ScrivTheme.accent.opacity(0.075) : ScrivTheme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? ScrivTheme.accent.opacity(0.22) : ScrivTheme.hairline.opacity(0.7)))
        .contentShape(RoundedRectangle(cornerRadius: 12)).onTapGesture(perform: select)
    }
    private var fileName: some View { Text(asset.originalName).font(.system(size: 17, weight: .semibold)).lineLimit(2).help(asset.originalName) }
    private var anchorBadge: some View {
        Text(anchorLabel).font(.system(size: 11)).lineLimit(2)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(clip.entryId == nil ? ScrivTheme.inset : ScrivTheme.color("purple").opacity(0.12), in: Capsule())
    }
    private func update(_ mutate: (inout AudioClip) -> Void) {
        guard var current = store.project.audioClips.first(where: { $0.id == clip.id }) else { return }
        mutate(&current); store.updateAudioClip(current)
    }
    private func play() {
        select()
        guard available, let placement else { return }
        if active { store.togglePlayback() }
        else { store.seek(toMs: Double(placement.startMs)); if !store.isPlaying { store.togglePlayback() } }
    }
}

private struct AudioPlaybackWaveform: View {
    let peaks: [Float]
    let playedFraction: Double
    let selected: Bool
    let muted: Bool
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                AudioWaveformView(peaks: peaks, color: selected && !muted ? ScrivTheme.accent.opacity(0.28) : .secondary.opacity(0.4))
                if !muted {
                    AudioWaveformView(peaks: peaks)
                        .mask(alignment: .leading) { Rectangle().frame(width: proxy.size.width * CGFloat(min(1, max(0, playedFraction)))) }
                }
            }
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel(peaks.contains(where: { $0 > 0 }) ? "Measured audio waveform" : "Silent audio waveform")
    }
}

struct AudioClipEditor: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    let navigationContext: Int
    private let original: AudioClip
    @State private var draft: AudioClip
    @State private var offset: String
    @State private var source: String
    @State private var duration: String
    @State private var validation: String?
    @State private var anchorNote: String?
    init(clip: AudioClip, navigationContext: Int) {
        self.navigationContext = navigationContext; original = clip
        _draft = State(initialValue: clip)
        _offset = State(initialValue: PreciseTimingInput.seconds(clip.startMs))
        _source = State(initialValue: PreciseTimingInput.seconds(clip.sourceStartMs))
        _duration = State(initialValue: PreciseTimingInput.seconds(clip.durationMs))
    }
    private var asset: AudioAsset? { store.project.audioAssets.first { $0.id == draft.assetId } }
    private var trim: ClosedRange<Int>? {
        guard let asset, let start = PreciseTimingInput.milliseconds(source, maximum: asset.durationMs),
              let length = PreciseTimingInput.milliseconds(duration, maximum: asset.durationMs),
              length > 0, start < asset.durationMs, length <= asset.durationMs - start else { return nil }
        return start...(start + length)
    }
    private var sceneStart: Int? {
        guard let value = PreciseTimingInput.milliseconds(offset, maximum: 86_400_000) else { return nil }
        return (draft.entryId.map { store.project.startMs(of: $0) } ?? 0) + value
    }
    private var sourcePlayhead: Int? {
        guard let trim, let sceneStart else { return nil }
        let elapsed = Int(store.playheadMs) - sceneStart
        guard elapsed >= 0, elapsed < trim.upperBound - trim.lowerBound else { return nil }
        return trim.lowerBound + elapsed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Trim & timing").font(.system(size: 19, weight: .semibold))
            Text(asset?.originalName ?? "Recording").font(.system(size: 14, weight: .medium)).lineLimit(2)
            if let asset {
                if let trim {
                    AudioTrimWaveform(asset: asset, trim: trim, playheadMs: sourcePlayhead) { start, end in
                        source = PreciseTimingInput.seconds(start); duration = PreciseTimingInput.seconds(end - start)
                    }.frame(height: 65)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        AudioWaveformView(peaks: asset.waveform, color: .secondary.opacity(0.4)).frame(height: 38)
                        Text("Enter valid source in and duration to show the trim.").font(.caption).foregroundStyle(.secondary)
                    }.frame(height: 65)
                }
            }
            HStack(alignment: .top, spacing: 24) {
                PreciseSecondsField(title: "Source in", accessibilityName: "Source in", text: $source, maximumMs: asset?.durationMs ?? AudioTimeline.maximumDurationMs, identifier: "audio-source-in")
                Divider().frame(height: 56)
                PreciseSecondsField(title: "Duration", accessibilityName: "Audio duration", text: $duration, maximumMs: asset?.durationMs ?? AudioTimeline.maximumDurationMs, minimumMs: 1, identifier: "audio-duration")
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    Text("Attach to").font(.system(size: 13)).frame(width: 140, alignment: .leading)
                    Picker("Attach to", selection: Binding(get: { draft.entryId }, set: changeAnchor)) {
                        Text("Scene time").tag(String?.none)
                        ForEach(store.project.entries(in: draft.sceneId)) { entry in
                            Text(anchorTitle(entry)).tag(Optional(entry.id))
                        }
                    }.labelsHidden().controlSize(.large).frame(maxWidth: .infinity)
                        .accessibilityIdentifier("audio-anchor")
                }
                HStack(spacing: 16) {
                    Text(draft.entryId == nil ? "Scene start" : "Offset from line").font(.system(size: 13)).frame(width: 140, alignment: .leading)
                    PreciseSecondsField(accessibilityName: draft.entryId == nil ? "Scene start" : "Offset from line", text: $offset, maximumMs: 86_400_000, identifier: "audio-placement-offset")
                        .frame(width: 165)
                    Spacer(minLength: 0)
                }
                if let anchorNote { Text(anchorNote).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                if let asset, let trim, let sceneStart {
                    let end = sceneStart + trim.upperBound - trim.lowerBound
                    Text("Source length: \(ScrivFormat.duration(asset.durationMs)) · Scene placement: \(ScrivFormat.time(sceneStart)) – \(ScrivFormat.time(end))")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if end > store.project.durationMs(of: draft.sceneId) {
                        Text(sceneStart >= store.project.durationMs(of: draft.sceneId) ? "This placement starts after the scene ends. Move it earlier or extend the scene to hear it." : "Playback stops at the scene’s end; the saved source trim is unchanged.")
                            .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let validation { TimingValidationNotice(message: validation) }
            HStack(alignment: .center, spacing: 10) {
                Text("Trimming changes this clip, not the recording.").font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).controlSize(.large)
                Button("Apply", action: save).buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("audio-apply")
            }
        }.padding(22).frame(width: 500).background(ScrivTheme.panel)
            .accessibilityIdentifier("audio-trim-editor")
            .onChange(of: store.navigationContext) { _, context in if context != navigationContext { dismiss() } }
            .onChange(of: store.selectedSceneID) { _, scene in if scene != draft.sceneId { dismiss() } }
    }
    private func anchorTitle(_ entry: ScriptEntry) -> String {
        let speaker = store.project.characters.first { $0.id == entry.characterId }?.name ?? (entry.kind == .dialogue ? "Dialogue" : "Direction")
        return speaker + " · " + String(entry.text.prefix(50))
    }
    private func changeAnchor(_ id: String?) {
        guard let currentOffset = PreciseTimingInput.milliseconds(offset, maximum: 86_400_000) else {
            validation = "Enter a valid placement offset before changing which line this clip follows."; return
        }
        let absolute = (draft.entryId.map { store.project.startMs(of: $0) } ?? 0) + currentOffset
        let base = id.map { store.project.startMs(of: $0) } ?? 0
        draft.entryId = id
        offset = PreciseTimingInput.seconds(max(0, absolute - base))
        anchorNote = absolute < base ? "Moved to the start of this line; negative offsets are not supported." : nil
    }
    private func save() {
        guard store.navigationContext == navigationContext, store.selectedSceneID == draft.sceneId else { dismiss(); return }
        guard let current = store.project.audioClips.first(where: { $0.id == original.id }), current == original else {
            validation = "This clip changed while the editor was open. Cancel and reopen Trim & timing to review its current placement."; return
        }
        guard asset != nil, let start = PreciseTimingInput.milliseconds(offset, maximum: 86_400_000), let trim else {
            validation = "Use nonnegative times and a positive duration that fits inside the source recording. Source in and duration trim the recording; the placement offset sets where it plays in the scene."; return
        }
        draft.startMs = start; draft.sourceStartMs = trim.lowerBound; draft.durationMs = trim.upperBound - trim.lowerBound
        if draft == original { dismiss(); return }
        if store.updateAudioClip(draft) { dismiss() }
        else { validation = store.errorMessage ?? "This clip could not be changed. Review its source and attachment, then try again." }
    }
}

/// Selection and handles refer to measured source audio, not scene placement time.
private struct AudioTrimWaveform: View {
    let asset: AudioAsset
    let trim: ClosedRange<Int>
    let playheadMs: Int?
    let change: (Int, Int) -> Void
    private let coordinateSpace = "audio-source-trim"
    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let left = width * CGFloat(trim.lowerBound) / CGFloat(max(1, asset.durationMs))
            let right = width * CGFloat(trim.upperBound) / CGFloat(max(1, asset.durationMs))
            ZStack(alignment: .topLeading) {
                AudioWaveformView(peaks: asset.waveform, color: .secondary.opacity(0.35)).padding(.vertical, 10)
                Rectangle().fill(ScrivTheme.accent.opacity(0.09)).frame(width: max(1, right - left), height: 45).offset(x: left, y: 10)
                AudioWaveformView(peaks: asset.waveform).padding(.vertical, 10)
                    .mask(alignment: .leading) { Rectangle().frame(width: max(1, right - left)).offset(x: left) }
                if let playheadMs {
                    TimingPlayhead().frame(width: 8, height: 62)
                        .offset(x: width * CGFloat(playheadMs) / CGFloat(max(1, asset.durationMs)) - 4)
                }
                handle(at: left, isStart: true, width: width)
                handle(at: right, isStart: false, width: width)
            }.coordinateSpace(name: coordinateSpace)
        }.accessibilityElement(children: .contain)
    }
    private func handle(at x: CGFloat, isStart: Bool, width: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(ScrivTheme.accent).frame(width: 3, height: 47)
            RoundedRectangle(cornerRadius: 2).fill(ScrivTheme.accent).frame(width: 8, height: 26)
            Rectangle().fill(.white.opacity(0.85)).frame(width: 1, height: 13)
        }.frame(width: 22, height: 65).contentShape(Rectangle()).offset(x: x - 11)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(coordinateSpace)).onChanged { value in
                let fraction = min(1, max(0, value.location.x / max(1, width)))
                let time = Int((fraction * CGFloat(asset.durationMs)).rounded())
                if isStart { change(min(trim.upperBound - 1, max(0, time)), trim.upperBound) }
                else { change(trim.lowerBound, min(asset.durationMs, max(trim.lowerBound + 1, time))) }
            })
            .accessibilityLabel(isStart ? "Source trim start" : "Source trim end")
            .accessibilityValue(PreciseTimingInput.seconds(isStart ? trim.lowerBound : trim.upperBound) + " seconds")
            .accessibilityAdjustableAction { direction in
                let delta = direction == .increment ? 100 : -100
                if isStart { change(min(trim.upperBound - 1, max(0, trim.lowerBound + delta)), trim.upperBound) }
                else { change(trim.lowerBound, min(asset.durationMs, max(trim.lowerBound + 1, trim.upperBound + delta))) }
            }
    }
}
