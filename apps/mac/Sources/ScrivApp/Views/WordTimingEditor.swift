import SwiftUI
import ScrivCore

struct WordTimingSelection: Identifiable {
    let entry: ScriptEntry
    let word: TimedWord
    let navigationContext: Int
    var id: String { word.id }
}

/// Editorial speech timing only. Pending edits to all words are saved together;
/// switching chips never applies a partial edit or moves image cuts or audio.
struct WordTimingEditor: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    let selection: WordTimingSelection
    @State private var selectedWordID: String
    @State private var drafts: [String: WordTimingDraft]
    @State private var ready = false
    @State private var leaseResolved = false
    @State private var validation: String?
    init(selection: WordTimingSelection) {
        self.selection = selection
        _selectedWordID = State(initialValue: selection.word.id)
        _drafts = State(initialValue: Dictionary(uniqueKeysWithValues: selection.entry.words.map { ($0.id, WordTimingDraft(word: $0)) }))
    }
    private var selectedWord: TimedWord? { selection.entry.words.first { $0.id == selectedWordID } }
    private var playhead: Int? {
        let relative = Int(store.playheadMs) - store.project.startMs(of: selection.entry.id)
        return (0...selection.entry.ownedDurationMs).contains(relative) ? relative : nil
    }
    private var previews: [TimedWord] {
        selection.entry.words.compactMap { word in
            guard let draft = drafts[word.id], let range = draft.range(maximum: selection.entry.ownedDurationMs) else { return nil }
            var preview = word; preview.startMs = range.lowerBound; preview.endMs = range.upperBound
            return preview
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Word timing").font(.system(size: 19, weight: .semibold))
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(selection.entry.words) { word in
                            Button { selectedWordID = word.id } label: {
                                Text(word.text).font(.system(size: 13, weight: word.id == selectedWordID ? .medium : .regular))
                                    .foregroundStyle(word.id == selectedWordID ? Color.white : ScrivTheme.ink)
                                    .padding(.horizontal, 14).frame(height: 35)
                                    .background(word.id == selectedWordID ? ScrivTheme.accent : ScrivTheme.inset, in: RoundedRectangle(cornerRadius: 7))
                            }.buttonStyle(.plain).id(word.id)
                                .accessibilityLabel("Edit timing for “" + word.text + "”")
                                .accessibilityAddTraits(word.id == selectedWordID ? [.isSelected] : [])
                                .accessibilityIdentifier("word-timing-chip-" + word.id)
                        }
                    }.padding(.vertical, 1)
                }.scrollIndicators(.automatic)
                    .onAppear { proxy.scrollTo(selectedWordID, anchor: .center) }
                    .onChange(of: selectedWordID) { _, id in withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) } }
            }.frame(height: 50)
            ManualWordTimingStrip(words: previews, selectedID: selectedWordID, durationMs: selection.entry.ownedDurationMs, playheadMs: playhead,
                select: { selectedWordID = $0 }, change: changeSelectedRange)
                .frame(height: 70)
            if let word = selectedWord {
                HStack(alignment: .top, spacing: 24) {
                    PreciseSecondsField(title: "Start", accessibilityName: "Start of “" + word.text + "”", text: draftBinding(\.start), maximumMs: selection.entry.ownedDurationMs, identifier: "word-timing-start")
                    Divider().frame(height: 56)
                    PreciseSecondsField(title: "End", accessibilityName: "End of “" + word.text + "”", text: draftBinding(\.end), maximumMs: selection.entry.ownedDurationMs, minimumMs: 1, identifier: "word-timing-end")
                }
            }
            Text("Relative to this dialogue · \(PreciseTimingInput.seconds(selection.entry.ownedDurationMs)) s")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if let validation { TimingValidationNotice(message: validation) }
            if !leaseResolved {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Acquiring edit lease…").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            Divider()
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Image cuts and audio stay unchanged.")
                    Text("Manual timing, not automatic alignment.").foregroundStyle(.secondary)
                }.font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 5)
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).controlSize(.large)
                Button("Save timing", action: save).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).controlSize(.large).disabled(!ready)
                    .accessibilityIdentifier("word-timing-save")
            }
        }.padding(22).frame(width: 500).background(ScrivTheme.panel)
            .accessibilityIdentifier("word-timing-editor")
            .task {
                let allowed = await store.beginEdit(selection.entry.id)
                guard !Task.isCancelled, store.navigationContext == selection.navigationContext, store.selectedSceneID == selection.entry.sceneId else {
                    if allowed { store.endEdit(selection.entry.id, context: selection.navigationContext) }; return
                }
                ready = allowed; leaseResolved = true
                if !allowed { validation = "This line cannot currently be edited. Close and retry when its edit lease is available." }
            }
            .onDisappear { if ready { store.endEdit(selection.entry.id, context: selection.navigationContext) } }
            .onChange(of: store.navigationContext) { _, value in if value != selection.navigationContext { dismiss() } }
            .onChange(of: store.selectedSceneID) { _, value in if value != selection.entry.sceneId { dismiss() } }
    }
    private func draftBinding(_ path: WritableKeyPath<WordTimingDraft, String>) -> Binding<String> {
        Binding(get: { drafts[selectedWordID]?[keyPath: path] ?? "" }, set: { value in
            guard var draft = drafts[selectedWordID] else { return }
            draft[keyPath: path] = value; drafts[selectedWordID] = draft
        })
    }
    private func changeSelectedRange(_ start: Int, _ end: Int) {
        drafts[selectedWordID] = WordTimingDraft(start: PreciseTimingInput.seconds(start), end: PreciseTimingInput.seconds(end))
    }
    private func save() {
        guard ready, store.navigationContext == selection.navigationContext, store.selectedSceneID == selection.entry.sceneId else { dismiss(); return }
        guard let entry = store.project.entries.first(where: { $0.id == selection.entry.id }),
              entry.words == selection.entry.words, entry.ownedDurationMs == selection.entry.ownedDurationMs else {
            validation = "This dialogue changed while the editor was open. Cancel and reopen Word timing to review its current words and timing."; return
        }
        var updated: [TimedWord] = []
        for word in entry.words {
            guard let range = drafts[word.id]?.range(maximum: entry.ownedDurationMs) else {
                selectedWordID = word.id
                validation = "Enter a start and end for “\(word.text)” within this dialogue, with end after start. Times are in seconds."; return
            }
            if let previous = updated.last, previous.endMs > range.lowerBound {
                selectedWordID = word.id
                validation = "“\(word.text)” would overlap “\(previous.text)”. Shorten the previous word’s end time or move this word’s start later. Select either word above to adjust it; all changes save together."; return
            }
            var changed = word
            changed.startMs = range.lowerBound; changed.endMs = range.upperBound
            if changed.startMs != word.startMs || changed.endMs != word.endMs { changed.timingSource = .authored }
            updated.append(changed)
        }
        if updated == entry.words { dismiss(); return }
        if store.setWordTimings(entryId: entry.id, expectedWords: selection.entry.words, expectedDurationMs: selection.entry.ownedDurationMs, updatedWords: updated) { dismiss() }
        else { validation = store.errorMessage ?? "Timing could not be changed. Keep words in source order without overlaps, then try again." }
    }
}

private struct WordTimingDraft {
    var start: String
    var end: String
    init(word: TimedWord) { start = PreciseTimingInput.seconds(word.startMs); end = PreciseTimingInput.seconds(word.endMs) }
    init(start: String, end: String) { self.start = start; self.end = end }
    func range(maximum: Int) -> ClosedRange<Int>? {
        guard let startMs = PreciseTimingInput.milliseconds(start, maximum: maximum), let endMs = PreciseTimingInput.milliseconds(end, maximum: maximum), endMs > startMs else { return nil }
        return startMs...endMs
    }
}

/// The blocks and highlighted edges come from draft word times; the playhead is
/// actual scene playback. Dragging adjusts only this word, never audio or images.
private struct ManualWordTimingStrip: View {
    let words: [TimedWord]
    let selectedID: String
    let durationMs: Int
    let playheadMs: Int?
    let select: (String) -> Void
    let change: (Int, Int) -> Void
    private let coordinateSpace = "manual-word-timing"
    private var selected: TimedWord? { words.first { $0.id == selectedID } }
    var body: some View {
        GeometryReader { proxy in
            strip(width: proxy.size.width)
        }
    }

    // Keep each SwiftUI expression small enough for native debug/release type
    // checking. These helpers preserve the same overlay order and geometry.
    private func strip(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ruler
            wordBlocks(width: width)
            playheadMarker(width: width)
            selectedHandles(width: width)
            endpointLabels
        }.coordinateSpace(name: coordinateSpace)
    }

    private var ruler: some View {
        Canvas { context, size in
            var ticks = Path()
            ticks.move(to: CGPoint(x: 0, y: 45))
            ticks.addLine(to: CGPoint(x: size.width, y: 45))
            for index in 0...10 {
                let tickX: CGFloat = CGFloat(index) / CGFloat(10) * size.width
                let bottom: CGFloat = index.isMultiple(of: 5) ? 54 : 51
                ticks.move(to: CGPoint(x: tickX, y: 45))
                ticks.addLine(to: CGPoint(x: tickX, y: bottom))
            }
            let tickColor: Color = ScrivTheme.secondary.opacity(0.35)
            context.stroke(ticks, with: .color(tickColor), lineWidth: 0.7)
        }.accessibilityHidden(true)
    }

    private func wordBlocks(width: CGFloat) -> some View {
        ForEach(words) { word in
            wordBlock(word, width: width)
        }
    }

    private func wordBlock(_ word: TimedWord, width: CGFloat) -> some View {
        let startX: CGFloat = x(word.startMs, width: width)
        let endX: CGFloat = x(word.endMs, width: width)
        let blockWidth: CGFloat = max(CGFloat(2), endX - startX - CGFloat(2))
        let fill: Color = word.id == selectedID ? ScrivTheme.accent.opacity(0.23) : ScrivTheme.secondary.opacity(0.13)
        let timing: String = PreciseTimingInput.seconds(word.startMs) + " to " + PreciseTimingInput.seconds(word.endMs) + " seconds"
        return Button { select(word.id) } label: {
            RoundedRectangle(cornerRadius: 3)
                .fill(fill)
                .frame(width: blockWidth, height: 17)
        }
        .buttonStyle(.plain)
        .offset(x: startX, y: 19)
        .accessibilityLabel("Select “" + word.text + "”")
        .accessibilityValue(timing)
    }

    @ViewBuilder
    private func playheadMarker(width: CGFloat) -> some View {
        if let playheadMs {
            TimingPlayhead().frame(width: 8, height: 51)
                .offset(x: x(playheadMs, width: width) - CGFloat(4), y: 5)
        }
    }

    @ViewBuilder
    private func selectedHandles(width: CGFloat) -> some View {
        if let selected {
            handle(word: selected, isStart: true, width: width)
            handle(word: selected, isStart: false, width: width)
        }
    }

    private var endpointLabels: some View {
        HStack {
            Text("0.0")
            Spacer()
            Text(String(format: "%.1f s", Double(durationMs) / 1000))
        }
        .font(.system(size: 10))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .offset(y: 57)
    }

    private func x(_ milliseconds: Int, width: CGFloat) -> CGFloat {
        width * CGFloat(milliseconds) / CGFloat(max(1, durationMs))
    }

    private func handle(word: TimedWord, isStart: Bool, width: CGFloat) -> some View {
        let edgeMs: Int = isStart ? word.startMs : word.endMs
        let horizontalPosition: CGFloat = x(edgeMs, width: width) - CGFloat(9)
        let label: String = (isStart ? "Start of “" : "End of “") + word.text + "”"
        let drag = DragGesture(minimumDistance: 0, coordinateSpace: .named(coordinateSpace))
            .onChanged { value in
                let fraction: CGFloat = value.location.x / max(CGFloat(1), width)
                let boundedFraction: CGFloat = min(CGFloat(1), max(CGFloat(0), fraction))
                let time: Int = Int((boundedFraction * CGFloat(durationMs)).rounded())
                adjust(word: word, isStart: isStart, to: time)
            }
        return Rectangle().fill(ScrivTheme.accent).frame(width: 3, height: 23)
            .frame(width: 18, height: 35).contentShape(Rectangle())
            .offset(x: horizontalPosition, y: 10)
            .gesture(drag)
            .accessibilityLabel(label)
            .accessibilityValue(PreciseTimingInput.seconds(edgeMs) + " seconds")
            .accessibilityAdjustableAction { direction in
                let delta: Int = direction == .increment ? 100 : -100
                adjust(word: word, isStart: isStart, to: edgeMs + delta)
            }
    }
    private func adjust(word: TimedWord, isStart: Bool, to time: Int) {
        // Keep the selected span positive and inside its line. Neighbor conflicts
        // remain visible and reviewable until the atomic Save timing validation.
        if isStart { change(min(word.endMs - 1, max(0, time)), word.endMs) }
        else { change(word.startMs, min(durationMs, max(word.startMs + 1, time))) }
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
                Button("Play from word") { store.seek(toMs: Double(start + word.startMs)); if !store.isPlaying { store.togglePlayback() } }
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
