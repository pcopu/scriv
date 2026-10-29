import SwiftUI
import ScrivCore

struct LayerTimelineView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @State private var zoom = 1.0
    @State private var snapToWords = true
    private var scale: CGFloat { min(0.04 * zoom, 30_000 / CGFloat(max(1, store.sceneDurationMs))) }
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("Layers").font(.system(size: 16, weight: .semibold))
                Spacer()
                Toggle("Snap to words", isOn: $snapToWords).toggleStyle(.checkbox).font(.system(size: 10))
                HStack(spacing: 5) {
                    Button { zoom = max(0.3, zoom / 1.25) } label: { Image(systemName: "minus") }.buttonStyle(.plain).accessibilityLabel("Zoom timeline out")
                    Slider(value: $zoom, in: 0.3...2.5).frame(width: 65).controlSize(.mini).accessibilityLabel("Timeline zoom")
                    Button { zoom = min(2.5, zoom * 1.25) } label: { Image(systemName: "plus") }.buttonStyle(.plain).accessibilityLabel("Zoom timeline in")
                }.font(.system(size: 11)).foregroundStyle(ScrivTheme.accent)
            }
            ScrollView(.vertical, showsIndicators: laneCount > 4) {
                HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 5) {
                    Color.clear.frame(height: 22)
                    layerLabel("Images", symbol: "photo", height: 55)
                    layerLabel("Dialogue", symbol: "waveform", height: 40)
                    layerLabel("Direction", symbol: "arrow.turn.down.right", height: directionHeight)
                    layerLabel("Words", symbol: "text.word.spacing", height: 32)
                }.frame(width: 68)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: true) {
                        TimelineCanvas(scale: scale, snap: snapToWords, directionHeight: directionHeight)
                    }.onChange(of: store.currentCue?.id) { _, id in
                        guard store.isPlaying, store.followPlayback, let id else { return }
                        withAnimation(.linear(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
                }
            }.frame(maxHeight: 22 + 55 + 40 + directionHeight + 32 + 20)
            .background(ScrivTheme.inset.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ScrivTheme.hairline.opacity(0.3)))
            overview.frame(height: 20)
            HStack {
                Text("0s")
                Spacer()
                Text(ScrivFormat.duration(store.sceneDurationMs))
            }.font(.system(size: 9)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
    private var directionHeight: CGFloat { CGFloat(max(1, laneCount)) * 28 + 3 }
    private var laneCount: Int {
        var ends: [Int] = []
        for entry in store.sceneEntries where entry.kind == .direction {
            let start = store.project.startMs(of: entry.id), end = start + entry.coverageDurationMs
            if let lane = ends.firstIndex(where: { $0 <= start }) { ends[lane] = end } else { ends.append(end) }
        }
        return ends.count
    }
    private func layerLabel(_ title: String, symbol: String, height: CGFloat) -> some View {
        HStack(spacing: 5) { Image(systemName: symbol).font(.system(size: 11)); Text(title).font(.system(size: 9, weight: .medium)) }
            .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 6).frame(height: height)
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
    private var width: CGFloat { max(400, CGFloat(store.sceneDurationMs) * scale) }
    private var height: CGFloat { 22 + 55 + 40 + directionHeight + 32 + 20 }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ruler.frame(height: 22)
            images.frame(height: 55)
            dialogue.frame(height: 40)
            directions.frame(height: directionHeight)
            words.frame(height: 32)
        }.frame(width: width, height: height, alignment: .topLeading)
            .overlay(alignment: .topLeading) {
                Rectangle().fill(ScrivTheme.accent).frame(width: 1.5, height: height)
                    .overlay(alignment: .top) { RoundedRectangle(cornerRadius: 2).fill(ScrivTheme.accent).frame(width: 8, height: 8).offset(y: 15) }
                    .offset(x: CGFloat(store.playheadMs) * scale).allowsHitTesting(false)
            }
            .padding(.trailing, 8)
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
                TimelineBlock(title: store.project.character(entry.characterId)?.name ?? "Dialogue", subtitle: entry.text, color: color)
                    .frame(width: max(2, CGFloat(entry.ownedDurationMs) * scale - 2), height: 40)
                    .offset(x: CGFloat(start) * scale)
                    .onTapGesture { store.selectEntry(entry.id); store.seek(toMs: Double(start)) }
            }
        }
    }
    private var directions: some View {
        ZStack(alignment: .topLeading) {
            ForEach(directionPlacements, id: \.entry.id) { placement in
                let entry = placement.entry, start = store.project.startMs(of: entry.id)
                TimelineBlock(title: entry.text, subtitle: "\(ScrivFormat.time(start)) – \(ScrivFormat.time(start + entry.coverageDurationMs))", color: ScrivTheme.color(entry.color))
                    .frame(width: max(20, CGFloat(entry.coverageDurationMs) * scale - 2), height: 25)
                    .offset(x: CGFloat(start) * scale, y: CGFloat(placement.lane) * 28)
                    .onTapGesture { store.selectEntry(entry.id) }
            }
        }
    }
    private var words: some View {
        ZStack(alignment: .topLeading) {
            ForEach(store.sceneEntries.filter { $0.kind == .dialogue }) { entry in
                let start = store.project.startMs(of: entry.id)
                ForEach(entry.words) { word in
                    Text(word.text).font(.system(size: 9)).lineLimit(1).minimumScaleFactor(0.7)
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
            Text(title).font(.system(size: 9, weight: .medium)).lineLimit(1)
            Text(subtitle).font(.system(size: 8)).lineLimit(1)
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
