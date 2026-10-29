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
    @State private var columnCount = 3
    @State private var scrollRequest = 0
    private let space = "storyboard-surface"
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Storyboard").font(.system(size: 18, weight: .semibold))
                    Text("\(store.sceneCues.count) images · \(ScrivFormat.duration(store.sceneDurationMs))")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                if !store.selectedWordIDs.isEmpty {
                    Text("\(store.selectedWordIDs.count) words selected").font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("Deselect") { store.selectedWordIDs = [] }.font(.system(size: 11)).buttonStyle(.borderless)
                }
                Button { scrollRequest += 1 } label: { Label("Current moment", systemImage: "scope") }.buttonStyle(.borderless)
                Button { store.addCue() } label: { Label("Add placement", systemImage: "plus.rectangle") }.buttonStyle(.borderless).disabled(store.sceneDurationMs <= 0)
                Button { store.importImage() } label: { Label("Import image", systemImage: "photo.badge.plus") }.buttonStyle(.bordered)
            }.padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 10)
            if store.sceneCues.isEmpty {
                EmptyPanel(symbol: "rectangle.stack", title: "Build the scene, one image at a time", message: "Add dialogue or direction, then import or generate an image for the selected moment.")
            } else {
                ZStack(alignment: .topLeading) {
                    ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 30) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                                StoryboardRow(cues: row, columns: columnCount, coordinateSpace: space)
                            }
                        }.padding(.horizontal, 22).padding(.vertical, 8).padding(.bottom, 25)
                    }.scrollDisabled(selecting)
                        .task(id: store.selectedSceneID) {
                            await Task.yield()
                            if let id = focusedCueID { proxy.scrollTo(id, anchor: .top) }
                        }
                        .onChange(of: scrollRequest) { _, _ in
                            if let id = focusedCueID { withAnimation { proxy.scrollTo(id, anchor: .top) } }
                        }
                    }
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
                Text("Select words or drag a marquee. Move the last words forward, or the first words back, to shift the cut.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                PlaybackBar(compact: true).frame(width: 430)
            }.padding(.horizontal, 22).padding(.vertical, 14).background(ScrivTheme.panel.opacity(0.92))
        }.background(ScrivTheme.panel).clipShape(RoundedRectangle(cornerRadius: 17))
            .background(GeometryReader { proxy in
                Color.clear.onChange(of: proxy.size.width, initial: true) { _, width in columnCount = width < 1050 ? 2 : 3 }
            })
            .onExitCommand { store.selectedWordIDs = [] }
    }
    private var focusedCueID: String? {
        if let entry = store.project.activeEntry(at: Int(store.playheadMs), sceneId: store.selectedSceneID) {
            let start = store.project.startMs(of: entry.id)
            return store.sceneCues.first { $0.startMs <= start && $0.endMs > start }?.id ?? store.selectedCueID
        }
        return store.selectedCueID ?? store.sceneCues.first?.id
    }
    private var rows: [[ImageCue]] {
        PresentationGeometry.storyboardRows(cues: store.sceneCues,
            entryStarts: Set(store.sceneEntries.map { store.project.startMs(of: $0.id) }), columns: columnCount)
    }
}

private struct StoryboardRow: View {
    @EnvironmentObject private var store: WorkspaceStore
    let cues: [ImageCue]
    let columns: Int
    let coordinateSpace: String
    private let gap: CGFloat = 18
    private var directions: [ScriptEntry] {
        guard let first = cues.first, let last = cues.last else { return [] }
        return store.sceneEntries.filter { entry in
            let start = store.project.startMs(of: entry.id)
            return entry.kind == .direction && start < last.endMs && start + entry.coverageDurationMs > first.startMs
        }
    }
    var body: some View {
        VStack(spacing: 9) {
            HStack(alignment: .top, spacing: gap) {
                ForEach(cues) { cue in
                    StoryboardCard(cue: cue, coordinateSpace: coordinateSpace).frame(maxWidth: .infinity).id(cue.id)
                }
                ForEach(0..<max(0, columns - cues.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) }
            }
            // Coverage is clipped to its true start/end inside each equal-width
            // image card, not repeated as a misleading full-image label.
            ForEach(directions) { entry in
                GeometryReader { proxy in
                    let cardWidth = max(1, (proxy.size.width - CGFloat(columns - 1) * gap) / CGFloat(columns))
                    let bounds = coverageBounds(entry, cardWidth: cardWidth)
                    DirectionBand(text: entry.text, color: ScrivTheme.color(entry.color), selected: store.selectedEntryID == entry.id) { store.selectEntry(entry.id) }
                        .frame(width: max(1, bounds.upperBound - bounds.lowerBound), height: 34)
                        .offset(x: bounds.lowerBound)
                        .help("\(entry.text) · \(ScrivFormat.time(store.project.startMs(of: entry.id)))–\(ScrivFormat.time(store.project.startMs(of: entry.id) + entry.coverageDurationMs))")
                }.frame(height: 34)
            }
        }
    }
    private func coverageBounds(_ entry: ScriptEntry, cardWidth: CGFloat) -> ClosedRange<CGFloat> {
        let start = store.project.startMs(of: entry.id), end = start + entry.coverageDurationMs
        let spans = cues.enumerated().compactMap { index, cue -> ClosedRange<CGFloat>? in
            guard let range = PresentationGeometry.coverageFractions(startMs: start, endMs: end, cueStartMs: cue.startMs, cueEndMs: cue.endMs) else { return nil }
            let origin = CGFloat(index) * (cardWidth + gap)
            return (origin + CGFloat(range.lowerBound) * cardWidth)...(origin + CGFloat(range.upperBound) * cardWidth)
        }
        return (spans.first?.lowerBound ?? 0)...(spans.last?.upperBound ?? 0)
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
    @State private var hovering = false
    @State private var dropTarget = false
    @State private var dragDelta: CGFloat = 0
    @State private var selectionAnchor: String?
    @State private var confirmingRemoval = false
    @State private var choosingImage = false
    private var asset: ImageAsset? { store.project.asset(cue.imageId) }
    private var words: [BoardWord] {
        store.sceneEntries.flatMap { entry -> [BoardWord] in
            let start = store.project.startMs(of: entry.id)
            return entry.words.filter { start + $0.startMs >= cue.startMs && start + $0.startMs < cue.endMs }
                .map { BoardWord(word: $0, entryId: entry.id, startMs: start + $0.startMs, endMs: start + $0.endMs) }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack(alignment: .topTrailing) {
                AssetImageView(url: asset.flatMap { store.assetURL($0) }, title: cue.label, unavailableText: asset == nil ? nil : "Image not on this Mac")
                    .aspectRatio(1.5, contentMode: .fit)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(dropTarget ? ScrivTheme.accent : cue.id == store.selectedCueID ? ScrivTheme.accent.opacity(0.7) : Color.clear, lineWidth: dropTarget ? 3 : 2))
                    .measureFrame("cue:" + cue.id, in: coordinateSpace)
                    .onTapGesture { store.selectedCueID = cue.id; store.seek(toMs: Double(cue.startMs)) }
                    .overlay(alignment: .trailing) {
                        if canResize, let next = nextCue, next.startMs == cue.endMs, hovering || dragDelta != 0 {
                            Capsule().fill(.white).frame(width: 4, height: 48).padding(8)
                                .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(Rectangle()).gesture(cutGesture)
                                .accessibilityLabel("Resize cut after " + cue.label)
                                .accessibilityAdjustableAction { direction in resize(to: cue.durationMs + (direction == .increment ? 100 : -100)) }
                                .help("Drag this cut; the next image keeps the remaining time")
                        }
                    }
                DurationPill(milliseconds: clampedDuration(cue.durationMs + Int(dragDelta * 20)), dark: true, editable: canResize, minimumMilliseconds: 1, title: "Image duration") { duration in resize(to: duration) }
                    .padding(10)
                    .highPriorityGesture(cutGesture, including: canResize ? .all : .none)
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
                if let asset, store.assetURL(asset) == nil { Button("Fetch image", systemImage: "arrow.down.circle") { store.downloadImage(asset) } }
                Button("Choose existing image…", systemImage: "photo.on.rectangle") { choosingImage = true }
                Button("Import image…", systemImage: "photo.badge.plus") { store.importImage(cueId: cue.id) }
                Button("Generate image", systemImage: "sparkles") { store.generateImage(cueId: cue.id) }
                Button("Split image in half", systemImage: "scissors") { store.seek(toMs: Double(cue.startMs + cue.durationMs / 2)); store.splitCue(cue.id) }
                Button("Discuss image", systemImage: "bubble.left") { store.loadDiscussion(itemId: cue.imageId ?? cue.id); store.showDiscussion = true }
                if let next = nextCue, next.startMs == cue.endMs { Button("Merge with next placement", systemImage: "rectangle.on.rectangle") { store.mergeCue(cue.id, with: next.id) }.disabled(!canResize) }
                Divider()
                Button("Remove placement…", systemImage: "trash", role: .destructive) { confirmingRemoval = true }.disabled(store.lockedByOther(cue.id) != nil)
            }
            FlowLayout(spacing: 5, rowSpacing: 6) {
                ForEach(words) { item in
                    WordPill(text: item.word.text, selected: store.selectedWordIDs.contains(item.id), active: store.currentWordID == item.id) {
                        select(item)
                    }.measureFrame(item.id, in: coordinateSpace)
                        .onDrag { provider(for: item) }
                        .contextMenu {
                            Button("Play word") { store.seek(toMs: Double(item.startMs)) }
                            if let previous = previousCue { Button("Move to previous image") { move(item, to: previous.id) }.disabled(previous.endMs != cue.startMs) }
                            if let next = nextCue { Button("Move to next image") { move(item, to: next.id) }.disabled(cue.endMs != next.startMs) }
                            Button("Discuss line") { store.loadDiscussion(itemId: item.entryId); store.showDiscussion = true }
                        }
                }
            }.frame(minHeight: words.isEmpty ? 0 : 34)
        }
        .padding(2)
        .background(dropTarget ? ScrivTheme.accent.opacity(0.035) : Color.clear, in: RoundedRectangle(cornerRadius: 13))
        .sheet(isPresented: $choosingImage) {
            ProjectImagePicker(cueID: cue.id, navigationContext: store.navigationContext).environmentObject(store)
        }
        .confirmationDialog("Remove this image placement?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Remove placement", role: .destructive) { store.deleteCue(cue.id) }
        } message: { Text("The image asset, script, words and their timing are preserved.") }
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
    private var adjacent: ImageCue? {
        if let next = nextCue, next.startMs == cue.endMs { return next }
        if let previous = previousCue, previous.endMs == cue.startMs { return previous }
        return nil
    }
    private var canResize: Bool { adjacent != nil && store.lockedByOther(cue.id) == nil && adjacent.map { store.lockedByOther($0.id) == nil } == true }
    private var cutGesture: some Gesture {
        DragGesture(minimumDistance: 5).onChanged { dragDelta = $0.translation.width }.onEnded { value in
            dragDelta = 0; resize(to: cue.durationMs + Int(value.translation.width * 20))
        }
    }
    private func clampedDuration(_ proposed: Int) -> Int {
        PresentationGeometry.clampedCueDuration(proposed: proposed, current: cue.durationMs, neighbor: adjacent?.durationMs)
    }
    private func resize(to proposed: Int) {
        guard canResize else { return }
        let duration = clampedDuration(proposed)
        if let next = nextCue, next.startMs == cue.endMs { store.moveBoundary(leftId: cue.id, rightId: next.id, toMs: cue.startMs + max(1, duration)) }
        else if let previous = previousCue, previous.endMs == cue.startMs { store.moveBoundary(leftId: previous.id, rightId: cue.id, toMs: cue.endMs - max(1, duration)) }
    }
    private func select(_ item: BoardWord) {
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.shift), let anchor = selectionAnchor,
           let first = words.firstIndex(where: { $0.id == anchor }), let last = words.firstIndex(where: { $0.id == item.id }) {
            store.selectedWordIDs.formUnion(words[min(first, last)...max(first, last)].map(\.id))
        } else if modifiers.contains(.command) {
            if store.selectedWordIDs.contains(item.id) { store.selectedWordIDs.remove(item.id) } else { store.selectedWordIDs.insert(item.id) }
            selectionAnchor = item.id
        } else {
            store.selectedWordIDs = [item.id]; selectionAnchor = item.id
        }
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
