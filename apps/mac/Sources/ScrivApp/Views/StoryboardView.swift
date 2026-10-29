import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ScrivCore

struct StoryboardView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @State private var frames: [String: CGRect] = [:]
    @State private var marquee: CGRect?
    @State private var selectionAtStart: Set<String> = []
    @State private var selecting = false
    private let space = "storyboard-surface"
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Storyboard").font(.system(size: 23, weight: .semibold))
                    Text("\(store.sceneCues.count) images · \(ScrivFormat.duration(store.sceneDurationMs))")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                if !store.selectedWordIDs.isEmpty {
                    Text("\(store.selectedWordIDs.count) words selected").font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("Deselect") { store.selectedWordIDs = [] }.font(.system(size: 11)).buttonStyle(.borderless)
                }
                Button { store.importImage() } label: { Label("Import image", systemImage: "photo.badge.plus") }.buttonStyle(.bordered)
            }.padding(.horizontal, 22).padding(.top, 19).padding(.bottom, 14)
            if store.sceneCues.isEmpty {
                EmptyPanel(symbol: "rectangle.stack", title: "Build the scene, one image at a time", message: "Add dialogue or direction, then import or generate an image for the selected moment.")
            } else {
                ZStack(alignment: .topLeading) {
                    ScrollView {
                        VStack(spacing: 25) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                                StoryboardRow(cues: row, coordinateSpace: space)
                            }
                        }.padding(.horizontal, 22).padding(.vertical, 8).padding(.bottom, 25)
                    }.scrollDisabled(selecting)
                    if let marquee {
                        Rectangle().fill(ScrivTheme.accent.opacity(0.09))
                            .overlay(Rectangle().stroke(ScrivTheme.accent, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                            .frame(width: marquee.width, height: marquee.height).offset(x: marquee.minX, y: marquee.minY)
                            .allowsHitTesting(false)
                    }
                }.coordinateSpace(name: space)
                    .onPreferenceChange(ViewFramePreference.self) { frames = $0 }
                    .simultaneousGesture(DragGesture(minimumDistance: 4, coordinateSpace: .named(space)).onChanged { value in
                        if !selecting {
                            guard !frames.values.contains(where: { $0.contains(value.startLocation) }) else { return }
                            selecting = true
                            selectionAtStart = NSEvent.modifierFlags.contains(.shift) ? store.selectedWordIDs : []
                        }
                        let rect = CGRect(x: min(value.startLocation.x, value.location.x), y: min(value.startLocation.y, value.location.y), width: abs(value.location.x - value.startLocation.x), height: abs(value.location.y - value.startLocation.y))
                        marquee = rect
                        let selected = frames.filter { !$0.key.hasPrefix("cue:") && $0.value.intersects(rect) }.map(\.key)
                        store.selectedWordIDs = selectionAtStart.union(selected)
                    }.onEnded { _ in selecting = false; marquee = nil })
            }
            HStack(spacing: 20) {
                Text("Select words or drag a marquee. Move them to an adjacent image to move the cut.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                PlaybackBar(compact: true).frame(width: 430)
            }.padding(.horizontal, 22).padding(.vertical, 14).background(.regularMaterial)
        }.background(ScrivTheme.panel).clipShape(RoundedRectangle(cornerRadius: 17))
            .onExitCommand { store.selectedWordIDs = [] }
    }
    private var rows: [[ImageCue]] {
        stride(from: 0, to: store.sceneCues.count, by: 3).map { Array(store.sceneCues[$0..<min($0 + 3, store.sceneCues.count)]) }
    }
}

private struct StoryboardRow: View {
    @EnvironmentObject private var store: WorkspaceStore
    let cues: [ImageCue]
    let coordinateSpace: String
    private var spanning: [ScriptEntry] {
        guard let first = cues.first, let last = cues.last else { return [] }
        return store.sceneEntries.filter { entry in
            let start = store.project.startMs(of: entry.id)
            return entry.kind == .direction && start <= first.startMs && start + entry.coverageDurationMs >= last.endMs
        }
    }
    var body: some View {
        VStack(spacing: 9) {
            HStack(alignment: .top, spacing: 18) {
                ForEach(cues) { cue in
                    StoryboardCard(cue: cue, coordinateSpace: coordinateSpace, spanningIDs: Set(spanning.map(\.id))).frame(maxWidth: .infinity)
                }
                ForEach(0..<max(0, 3 - cues.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) }
            }
            ForEach(spanning) { entry in
                DirectionBand(text: entry.text, color: ScrivTheme.color(entry.color), selected: store.selectedEntryID == entry.id) { store.selectEntry(entry.id) }
            }
        }
    }
}

private struct BoardWord: Identifiable {
    let word: TimedWord
    let entryId: String
    let startMs: Int
    let endMs: Int
    var id: String { word.id }
}
private struct BoardDragPayload: Codable {
    var type = "scriv.words.v1"
    var cueId: String
    var wordIds: [String]
}

private struct StoryboardCard: View {
    @EnvironmentObject private var store: WorkspaceStore
    let cue: ImageCue
    let coordinateSpace: String
    let spanningIDs: Set<String>
    @State private var hovering = false
    @State private var dropTarget = false
    @State private var dragDelta: CGFloat = 0
    private var asset: ImageAsset? { store.project.asset(cue.imageId) }
    private var words: [BoardWord] {
        store.sceneEntries.flatMap { entry -> [BoardWord] in
            let start = store.project.startMs(of: entry.id)
            return entry.words.filter { start + $0.startMs >= cue.startMs && start + $0.startMs < cue.endMs }
                .map { BoardWord(word: $0, entryId: entry.id, startMs: start + $0.startMs, endMs: start + $0.endMs) }
        }
    }
    private var directions: [ScriptEntry] {
        store.sceneEntries.filter { entry in
            let start = store.project.startMs(of: entry.id)
            return entry.kind == .direction && !spanningIDs.contains(entry.id) && start < cue.endMs && start + entry.coverageDurationMs > cue.startMs
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack(alignment: .topTrailing) {
                AssetImageView(url: asset.flatMap { store.assetURL($0) }, title: cue.label)
                    .aspectRatio(1.6, contentMode: .fit)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(dropTarget ? ScrivTheme.accent : cue.id == store.selectedCueID ? ScrivTheme.accent.opacity(0.7) : Color.clear, lineWidth: dropTarget ? 3 : 2))
                    .measureFrame("cue:" + cue.id, in: coordinateSpace)
                    .onTapGesture { store.selectedCueID = cue.id; store.seek(toMs: Double(cue.startMs)) }
                DurationPill(milliseconds: max(1, cue.durationMs + Int(dragDelta * 20)), dark: true, editable: adjacent != nil) { duration in resize(to: duration) }
                    .padding(10)
                    .simultaneousGesture(DragGesture(minimumDistance: 5).onChanged { dragDelta = $0.translation.width }.onEnded { value in
                        dragDelta = 0; resize(to: cue.durationMs + Int(value.translation.width * 20))
                    })
                    .help("Drag left or right to transfer time with an adjacent image")
                if hovering {
                    HStack {
                        Text(cue.label.isEmpty ? "Image" : cue.label).font(.system(size: 11, weight: .medium)).padding(6).background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 5))
                        Spacer()
                    }.foregroundStyle(.white).padding(10).allowsHitTesting(false)
                }
            }
            .onHover { hovering = $0 }
            .contextMenu {
                Button("Import image…", systemImage: "photo.badge.plus") { store.importImage(cueId: cue.id) }
                Button("Generate image", systemImage: "sparkles") { store.generateImage(cueId: cue.id) }
                Button("Split image in half", systemImage: "scissors") { store.seek(toMs: Double(cue.startMs + cue.durationMs / 2)); store.splitCue(cue.id) }
                Button("Discuss image", systemImage: "bubble.left") { store.loadDiscussion(itemId: cue.imageId ?? cue.id); store.showDiscussion = true }
            }
            FlowLayout(spacing: 5, rowSpacing: 6) {
                ForEach(words) { item in
                    WordPill(text: item.word.text, selected: store.selectedWordIDs.contains(item.id), active: store.isPlaying && store.currentWordID == item.id) {
                        select(item)
                    }.measureFrame(item.id, in: coordinateSpace)
                        .onDrag { provider(for: item) }
                        .contextMenu {
                            Button("Play word") { store.seek(toMs: Double(item.startMs)) }
                            if let previous = previousCue { Button("Move to previous image") { move(item, to: previous.id) } }
                            if let next = nextCue { Button("Move to next image") { move(item, to: next.id) } }
                            Button("Discuss line") { store.loadDiscussion(itemId: item.entryId); store.showDiscussion = true }
                        }
                }
            }.frame(minHeight: words.isEmpty ? 0 : 34)
            ForEach(directions) { entry in
                DirectionBand(text: entry.text, color: ScrivTheme.color(entry.color), selected: store.selectedEntryID == entry.id) { store.selectEntry(entry.id) }
            }
        }
        .padding(2)
        .background(dropTarget ? ScrivTheme.accent.opacity(0.035) : Color.clear, in: RoundedRectangle(cornerRadius: 13))
        .onDrop(of: [UTType.utf8PlainText], isTargeted: $dropTarget) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: String.self) { text, _ in
                guard let text, let data = text.data(using: .utf8), let payload = try? JSONDecoder().decode(BoardDragPayload.self, from: data), payload.type == "scriv.words.v1" else { return }
                Task { @MainActor in store.moveWords(Set(payload.wordIds), fromCueId: payload.cueId, toCueId: cue.id) }
            }
            return true
        }
    }
    private var previousCue: ImageCue? {
        guard let index = store.sceneCues.firstIndex(where: { $0.id == cue.id }), index > 0 else { return nil }
        return store.sceneCues[index - 1]
    }
    private var nextCue: ImageCue? {
        guard let index = store.sceneCues.firstIndex(where: { $0.id == cue.id }), index + 1 < store.sceneCues.count else { return nil }
        return store.sceneCues[index + 1]
    }
    private var adjacent: ImageCue? { nextCue ?? previousCue }
    private func resize(to duration: Int) {
        if let next = nextCue, next.startMs == cue.endMs { store.moveBoundary(leftId: cue.id, rightId: next.id, toMs: cue.startMs + max(1, duration)) }
        else if let previous = previousCue, previous.endMs == cue.startMs { store.moveBoundary(leftId: previous.id, rightId: cue.id, toMs: cue.endMs - max(1, duration)) }
    }
    private func select(_ item: BoardWord) {
        if NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift) {
            if store.selectedWordIDs.contains(item.id) { store.selectedWordIDs.remove(item.id) } else { store.selectedWordIDs.insert(item.id) }
        } else { store.selectedWordIDs = [item.id] }
        store.selectedCueID = cue.id
    }
    private func selected(for item: BoardWord) -> Set<String> {
        store.selectedWordIDs.contains(item.id) ? store.selectedWordIDs.intersection(Set(words.map(\.id))) : [item.id]
    }
    private func provider(for item: BoardWord) -> NSItemProvider {
        let ids = selected(for: item)
        store.selectedWordIDs = ids
        let payload = BoardDragPayload(cueId: cue.id, wordIds: Array(ids))
        let data = (try? JSONEncoder().encode(payload)) ?? Data()
        return NSItemProvider(object: (String(data: data, encoding: .utf8) ?? "") as NSString)
    }
    private func move(_ item: BoardWord, to id: String) { store.moveWords(selected(for: item), fromCueId: cue.id, toCueId: id) }
}
