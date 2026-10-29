import SwiftUI
import ScrivCore

struct LayerTimelineView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @State private var zoom = 1.0
    @State private var snapToWords = true
    @State private var viewportWidth: CGFloat = 0
    @State private var canvasOffset: CGFloat = 0
    @State private var expanded = false
    @State private var audioOpen = false
    var allowsExpansion = true
    private var scale: CGFloat { min(CGFloat(0.04) * CGFloat(zoom), CGFloat(30_000) / CGFloat(max(1, store.sceneDurationMs))) }
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("Layers").font(.system(size: 16, weight: .semibold))
                Button { audioOpen = true } label: { Label("Local audio", systemImage: "waveform.badge.plus").font(.system(size: 10)) }
                    .buttonStyle(.borderless).help("Import and edit audio stored in this project package")
                Spacer()
                Toggle("Snap to words", isOn: $snapToWords).toggleStyle(.checkbox).font(.system(size: 10))
                HStack(spacing: 5) {
                    Button { zoom = max(0.3, zoom / 1.25) } label: { Image(systemName: "minus") }.buttonStyle(.plain).accessibilityLabel("Zoom timeline out")
                    Slider(value: $zoom, in: 0.3...2.5).frame(width: 65).controlSize(.mini).accessibilityLabel("Timeline zoom")
                    Button { zoom = min(2.5, zoom * 1.25) } label: { Image(systemName: "plus") }.buttonStyle(.plain).accessibilityLabel("Zoom timeline in")
                }.font(.system(size: 11)).foregroundStyle(ScrivTheme.accent)
                if allowsExpansion { IconButton(symbol: "arrow.up.left.and.arrow.down.right", label: "Expand layers") { expanded = true } }
            }
            ScrollView(.vertical, showsIndicators: true) {
                HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 5) {
                    Color.clear.frame(height: 22)
                    layerLabel("Images", symbol: "photo", height: 55)
                    layerLabel("Dialogue", symbol: "waveform", height: 40)
                    layerLabel("Direction", symbol: "arrow.turn.down.right", height: directionHeight)
                    layerLabel("Words", symbol: "text.word.spacing", height: 32)
                    if audioHeight > 0 { layerLabel("Audio", symbol: "speaker.wave.2", height: audioHeight) }
                }.frame(width: 68)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: true) {
                        TimelineCanvas(scale: scale, snap: snapToWords, directionHeight: directionHeight, audioHeight: audioHeight)
                            .measureFrame("timeline-canvas", in: "timeline-viewport")
                    }.coordinateSpace(name: "timeline-viewport")
                        .background(GeometryReader { geometry in
                            Color.clear.onChange(of: geometry.size.width, initial: true) { _, width in viewportWidth = width }
                        })
                        .onPreferenceChange(ViewFramePreference.self) { frames in canvasOffset = frames["timeline-canvas"]?.minX ?? 0 }
                        .onAppear {
                        if let id = (store.selectedCue ?? store.currentCue)?.id { proxy.scrollTo(id, anchor: .center) }
                    }.onChange(of: store.selectedCueID) { _, id in
                        guard !store.isPlaying, let id else { return }
                        withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                    }.onChange(of: store.currentCue?.id) { _, id in
                        guard store.isPlaying, store.followPlayback, let id else { return }
                        withAnimation(.linear(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
                }
            }.frame(maxHeight: 22 + 55 + 40 + directionHeight + 32 + 20 + audioHeight + (audioHeight > 0 ? 5 : 0))
            .background(ScrivTheme.inset.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ScrivTheme.hairline.opacity(0.3)))
            overview.frame(height: 20)
            HStack {
                Text("0s")
                Spacer()
                Text(ScrivFormat.duration(store.sceneDurationMs))
            }.font(.system(size: 9)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }.sheet(isPresented: $audioOpen) { LocalAudioSheet(navigationContext: store.navigationContext).environmentObject(store) }
        .sheet(isPresented: $expanded) {
            VStack(spacing: 16) {
                HStack { Text("Layers").font(.title2.weight(.semibold)); Spacer(); Button("Done") { expanded = false }.keyboardShortcut(.cancelAction) }
                LayerTimelineView(allowsExpansion: false).environmentObject(store)
                PlaybackBar().environmentObject(store)
            }.padding(20).frame(width: 1040, height: 480)
        }
    }
    private var audioHeight: CGFloat {
        let lanes = AudioLaneItem.sceneTracks(project: store.project, sceneID: store.selectedSceneID)
        return lanes.isEmpty ? 0 : CGFloat((lanes.map(\.lane).max() ?? 0) + 1) * 36
    }
    private var directionHeight: CGFloat { CGFloat(max(1, laneCount)) * 35 + 3 }
    private var laneCount: Int {
        var ends: [Int] = []
        for entry in store.sceneEntries where entry.kind == .direction {
            let start = store.project.startMs(of: entry.id), end = start + entry.coverageDurationMs
            if let lane = ends.firstIndex(where: { $0 <= start }) { ends[lane] = end } else { ends.append(end) }
        }
        return ends.count
    }
    private func layerLabel(_ title: String, symbol: String, height: CGFloat) -> some View {
        HStack(spacing: 5) { Image(systemName: symbol).font(.system(size: 11)); Text(title).font(.system(size: 10, weight: .medium)) }
            .foregroundStyle(ScrivTheme.accent).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 6).frame(height: height)
    }
    private var overview: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(ScrivTheme.inset)
                ForEach(store.sceneCues) { cue in
                    RoundedRectangle(cornerRadius: 1).fill(ScrivTheme.accent.opacity(cue.id == store.currentCue?.id ? 0.65 : 0.22))
                        .frame(width: max(1, proxy.size.width * CGFloat(cue.durationMs) / CGFloat(max(1, store.sceneDurationMs))), height: 12)
                        .offset(x: proxy.size.width * CGFloat(cue.startMs) / CGFloat(max(1, store.sceneDurationMs)))
                }
                let canvasWidth = max(400, CGFloat(store.sceneDurationMs) * scale)
                let visibleFraction = min(1, max(0, viewportWidth / canvasWidth))
                let startFraction = min(1 - visibleFraction, max(0, -canvasOffset / canvasWidth))
                RoundedRectangle(cornerRadius: 4).fill(ScrivTheme.accent.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ScrivTheme.accent, lineWidth: 1.5))
                    .frame(width: max(4, proxy.size.width * visibleFraction), height: 18)
                    .offset(x: proxy.size.width * startFraction)
                Rectangle().fill(ScrivTheme.accent).frame(width: 2, height: 20)
                    .offset(x: proxy.size.width * min(1, CGFloat(store.playheadMs) / CGFloat(max(1, store.sceneDurationMs))))
            }.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0).onChanged { value in
                store.seek(toMs: Double(min(1, max(0, value.location.x / max(1, proxy.size.width)))) * Double(store.sceneDurationMs))
            })
            .accessibilityLabel("Scene overview. Use playback slider to seek.")
        }
    }
}

private struct TimelineCanvas: View {
    @EnvironmentObject private var store: WorkspaceStore
    let scale: CGFloat
    let snap: Bool
    let directionHeight: CGFloat
    let audioHeight: CGFloat
    @State private var editingAudio: AudioClip?
    @State private var audioDrag: [String: CGFloat] = [:]
    private var width: CGFloat { max(400, CGFloat(store.sceneDurationMs) * scale) }
    private var height: CGFloat { 22 + 55 + 40 + directionHeight + 32 + 20 + audioHeight + (audioHeight > 0 ? 5 : 0) }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ruler.frame(height: 22)
            images.frame(height: 55)
            dialogue.frame(height: 40)
            directions.frame(height: directionHeight)
            words.frame(height: 32)
            if audioHeight > 0 { audio.frame(height: audioHeight) }
        }.frame(width: width, height: height, alignment: .topLeading)
            .overlay(alignment: .topLeading) {
                Rectangle().fill(ScrivTheme.accent).frame(width: 1.5, height: height)
                    .overlay(alignment: .top) { RoundedRectangle(cornerRadius: 2).fill(ScrivTheme.accent).frame(width: 8, height: 8).offset(y: 15) }
                    .offset(x: CGFloat(store.playheadMs) * scale).allowsHitTesting(false)
            }
            .padding(.trailing, 8)
            .sheet(item: $editingAudio) { clip in AudioClipEditor(clip: clip, navigationContext: store.navigationContext).environmentObject(store) }
    }
    private var ruler: some View {
        ZStack(alignment: .topLeading) {
            let seconds = max(1, Int(ceil(Double(store.sceneDurationMs) / 1000)))
            let increment = max(1, Int(ceil(50 / max(1, scale * 1000))))
            ForEach(Array(stride(from: 0, through: seconds, by: increment)), id: \.self) { second in
                VStack(spacing: 2) {
                    Text("\(second)s").font(.system(size: 9, design: .rounded)).foregroundStyle(.secondary)
                    Rectangle().fill(ScrivTheme.hairline).frame(width: 1, height: 5)
                }.position(x: CGFloat(second * 1000) * scale, y: 10)
            }
        }.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0).onChanged { value in
            store.seek(toMs: Double(max(0, value.location.x / scale)))
        }).accessibilityLabel("Timeline ruler")
    }
    private var images: some View {
        ZStack(alignment: .topLeading) {
            ForEach(store.sceneCues) { cue in
                let asset = store.project.asset(cue.imageId)
                Button {
                    store.selectedCueID = cue.id; store.seek(toMs: Double(cue.startMs))
                } label: {
                    AssetImageView(url: asset.flatMap { store.assetURL($0) }, title: cue.label, cornerRadius: 5)
                        .overlay(alignment: .bottomLeading) {
                            Text(cue.label.isEmpty ? ScrivFormat.duration(cue.durationMs) : cue.label).font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.white).padding(3).background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 3)).padding(3)
                        }
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(cue.id == store.selectedCueID || cue.id == store.currentCue?.id ? ScrivTheme.accent : Color.clear, lineWidth: 2))
                }.buttonStyle(.plain).frame(width: max(2, CGFloat(cue.durationMs) * scale - 2), height: 55)
                    .offset(x: CGFloat(cue.startMs) * scale).id(cue.id)
                    .contextMenu {
                        Button("Import image…") { store.importImage(cueId: cue.id) }
                        Button("Generate image") { store.generateImage(cueId: cue.id) }
                        Button("Split at playhead") { store.splitCue(cue.id) }
                    }
            }
            ForEach(Array(store.sceneCues.dropLast().enumerated()), id: \.element.id) { index, cue in
                let next = store.sceneCues[index + 1]
                if cue.endMs == next.startMs {
                    CutHandle(left: cue, right: next, scale: scale, snap: snap)
                        .offset(x: CGFloat(cue.endMs) * scale - 5)
                }
            }
        }
    }
    private var dialogue: some View {
        ZStack(alignment: .topLeading) {
            ForEach(store.sceneEntries.filter { $0.kind == .dialogue }) { entry in
                let start = store.project.startMs(of: entry.id)
                let color = ScrivTheme.color(store.project.character(entry.characterId)?.color ?? "blue")
                ZStack(alignment: .bottomLeading) {
                    TimelineBlock(title: store.project.character(entry.characterId)?.name ?? "Dialogue", subtitle: entry.text, color: color)
                    ForEach(entryAudio(entry.id)) { placement in
                        if let asset = store.project.audioAssets.first(where: { $0.id == placement.assetId }) {
                            AudioWaveformView(peaks: AudioTimeline.waveform(for: placement, asset: asset), color: color.opacity(0.7))
                                .frame(width: max(1, CGFloat(placement.durationMs) * scale), height: 10)
                                .offset(x: CGFloat(placement.startMs - start) * scale)
                                .allowsHitTesting(false)
                        }
                    }
                }.frame(width: max(2, CGFloat(entry.ownedDurationMs) * scale - 2), height: 40).clipped()
                    .offset(x: CGFloat(start) * scale)
                    .onTapGesture { store.selectEntry(entry.id); store.seek(toMs: Double(start)) }
                    .contextMenu {
                        Button("Import audio for this dialogue…", systemImage: "waveform.badge.plus") { store.importAudio(entryId: entry.id) }
                        ForEach(store.project.audioClips.filter { $0.entryId == entry.id }) { clip in
                            Button("Edit audio: " + (store.project.audioAssets.first(where: { $0.id == clip.assetId })?.originalName ?? "Recording")) { editingAudio = clip }
                        }
                    }
            }
        }
    }
    private var directions: some View {
        ZStack(alignment: .topLeading) {
            ForEach(directionPlacements, id: \.entry.id) { placement in
                let entry = placement.entry, start = store.project.startMs(of: entry.id)
                let blockWidth = max(20, CGFloat(entry.coverageDurationMs) * scale - 2)
                HStack(spacing: 3) {
                    TimelineBlock(title: entry.text, subtitle: "\(ScrivFormat.time(start)) – \(ScrivFormat.time(start + entry.coverageDurationMs))", color: ScrivTheme.color(entry.color))
                    if blockWidth > 115 {
                        DurationPill(milliseconds: entry.ownedDurationMs, editable: store.lockedByOther(entry.id) == nil) { store.setDuration(entry.id, seconds: Double($0) / 1000) }
                            .scaleEffect(0.75).frame(width: 38)
                    }
                }.background(ScrivTheme.color(entry.color).opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                    .frame(width: blockWidth, height: 32)
                    .offset(x: CGFloat(start) * scale, y: CGFloat(placement.lane) * 35)
                    .onTapGesture { store.selectEntry(entry.id) }
                    .help("\(entry.text) · owned \(ScrivFormat.duration(entry.ownedDurationMs)); coverage \(ScrivFormat.duration(entry.coverageDurationMs))")
            }
        }
    }
    private var words: some View {
        ZStack(alignment: .topLeading) {
            ForEach(store.sceneEntries.filter { $0.kind == .dialogue }) { entry in
                let start = store.project.startMs(of: entry.id)
                ForEach(entry.words) { word in
                    Text(word.text).font(.system(size: 11)).lineLimit(1).minimumScaleFactor(0.7)
                        .foregroundStyle(store.currentWordID == word.id ? Color.white : ScrivTheme.accent)
                        .frame(width: max(3, CGFloat(word.endMs - word.startMs) * scale - 1), height: 28)
                        .background(store.currentWordID == word.id ? ScrivTheme.accent : ScrivTheme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                        .offset(x: CGFloat(start + word.startMs) * scale)
                        .onTapGesture { store.seek(toMs: Double(start + word.startMs)) }
                        .help(word.text)
                }
            }
        }
    }
    private func entryAudio(_ entryID: String) -> [AudioPlacement] {
        let ids = Set(store.project.audioClips.filter { $0.entryId == entryID }.map(\.id))
        return AudioTimeline.placements(project: store.project, sceneId: store.selectedSceneID).filter { ids.contains($0.clipId) }
    }
    private var audio: some View {
        ZStack(alignment: .topLeading) {
            ForEach(AudioLaneItem.sceneTracks(project: store.project, sceneID: store.selectedSceneID)) { row in
                if let clip = store.project.audioClips.first(where: { $0.id == row.placement.clipId }),
                   let asset = store.project.audioAssets.first(where: { $0.id == row.placement.assetId }) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(asset.originalName).font(.system(size: 9, weight: .medium)).lineLimit(1).padding(.horizontal, 4)
                        AudioWaveformView(peaks: AudioTimeline.waveform(for: row.placement, asset: asset), color: clip.isMuted ? .secondary : .teal)
                            .frame(height: 18)
                    }.frame(width: max(2, CGFloat(row.placement.durationMs) * scale - 2), height: 32)
                        .background(Color.teal.opacity(clip.isMuted ? 0.04 : 0.1), in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.teal.opacity(0.3)))
                        .offset(x: CGFloat(row.placement.startMs) * scale + (audioDrag[clip.id] ?? 0), y: CGFloat(row.lane) * 36)
                        .onTapGesture { store.seek(toMs: Double(row.placement.startMs)) }
                        .gesture(DragGesture(minimumDistance: 3).onChanged { audioDrag[clip.id] = $0.translation.width }.onEnded { value in
                            audioDrag.removeValue(forKey: clip.id)
                            var changed = clip
                            let base = clip.entryId.map { store.project.startMs(of: $0) } ?? 0
                            var absolute = base + clip.startMs + Int(value.translation.width / scale)
                            if snap {
                                let times = TimingEngine.absoluteWords(store.project, sceneId: store.selectedSceneID).map(\.startMs)
                                if let closest = times.min(by: { abs($0 - absolute) < abs($1 - absolute) }), abs(closest - absolute) < 300 { absolute = closest }
                            }
                            changed.startMs = min(86_400_000, max(0, absolute - base))
                            store.updateAudioClip(changed)
                        })
                        .contextMenu {
                            Button("Trim and timing…") { editingAudio = clip }
                            Button(clip.isMuted ? "Unmute clip" : "Mute clip") { var changed = clip; changed.isMuted.toggle(); store.updateAudioClip(changed) }
                            Button("Remove clip", role: .destructive) { store.deleteAudioClip(clip.id) }
                        }
                        .help(asset.originalName + " · Local audio, not uploaded. Drag to move; context menu edits source trim and volume.")
                }
            }
        }
    }
    private var directionPlacements: [(entry: ScriptEntry, lane: Int)] {
        var ends: [Int] = [], result: [(ScriptEntry, Int)] = []
        for entry in store.sceneEntries where entry.kind == .direction {
            let start = store.project.startMs(of: entry.id), end = start + entry.coverageDurationMs
            let lane = ends.firstIndex { $0 <= start } ?? ends.count
            if lane == ends.count { ends.append(end) } else { ends[lane] = end }
            result.append((entry, lane))
        }
        return result
    }
}

private struct TimelineBlock: View {
    let title: String
    let subtitle: String
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10, weight: .medium)).lineLimit(1)
            Text(subtitle).font(.system(size: 10)).lineLimit(1)
        }.foregroundStyle(color).padding(.horizontal, 5).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(color.opacity(0.22)))
    }
}

private struct CutHandle: View {
    @EnvironmentObject private var store: WorkspaceStore
    let left: ImageCue
    let right: ImageCue
    let scale: CGFloat
    let snap: Bool
    @State private var delta: CGFloat = 0
    var body: some View {
        Capsule().fill(ScrivTheme.accent.opacity(delta == 0 ? 0.65 : 1)).frame(width: 3, height: 44).padding(.horizontal, 4).frame(height: 55)
            .contentShape(Rectangle()).offset(x: delta)
            .gesture(DragGesture(minimumDistance: 1).onChanged { delta = $0.translation.width }.onEnded { value in
                let requested = left.endMs + Int(value.translation.width / scale)
                let boundary: Int
                if snap {
                    let times = store.sceneEntries.flatMap { entry in entry.words.map { store.project.startMs(of: entry.id) + $0.startMs } }
                    let closest = times.min { abs($0 - requested) < abs($1 - requested) }
                    boundary = closest.map { abs($0 - requested) < 300 ? $0 : requested } ?? requested
                } else { boundary = requested }
                delta = 0; store.moveBoundary(leftId: left.id, rightId: right.id, toMs: boundary)
            })
            .help("Drag the cut to transfer time between images")
            .accessibilityLabel("Cut between \(left.label) and \(right.label)")
            .accessibilityAdjustableAction { value in store.moveBoundary(leftId: left.id, rightId: right.id, toMs: left.endMs + (value == .increment ? 100 : -100)) }
            .disabled(store.lockedByOther(left.id) != nil || store.lockedByOther(right.id) != nil)
    }
}
