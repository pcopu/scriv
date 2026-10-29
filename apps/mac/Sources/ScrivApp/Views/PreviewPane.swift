import SwiftUI
import AppKit
import ScrivCore

struct PreviewPane: View {
    @EnvironmentObject private var store: WorkspaceStore
    @State private var fullScreen = false
    @State private var tagsOpen = false
    private var cue: ImageCue? { store.isPlaying ? store.currentCue : (store.selectedCue ?? store.currentCue) }
    private var asset: ImageAsset? { store.project.asset(cue?.imageId) }
    var body: some View {
        VStack(spacing: 11) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Preview").font(.system(size: 23, weight: .semibold))
                    Text(previewSubtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("16:9").font(.system(size: 11, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 7)
                    .background(ScrivTheme.inset, in: RoundedRectangle(cornerRadius: 8))
                IconButton(symbol: "arrow.up.left.and.arrow.down.right", label: "Expand preview") { fullScreen = true }
            }
            ZStack(alignment: .bottomTrailing) {
                AssetImageView(url: asset.flatMap { store.assetURL($0) }, title: cue?.label ?? "Scene preview")
                    .aspectRatio(16 / 9, contentMode: .fit)
                Menu {
                    Button("Import image…", systemImage: "photo.badge.plus") { store.importImage(cueId: cue?.id) }
                    Button("Generate image", systemImage: "sparkles") { store.generateImage(cueId: cue?.id) }
                    if let cue {
                        Button("Split image at playhead", systemImage: "scissors") { store.splitCue(cue.id) }
                        Button("Discuss image", systemImage: "bubble.left") { store.loadDiscussion(itemId: cue.imageId ?? cue.id); store.showDiscussion = true }
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 30, height: 28).background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
                }.menuStyle(.borderlessButton).fixedSize().padding(11)
            }
            HStack(spacing: 5) {
                if let asset {
                    ForEach(store.project.characters.filter { asset.characterIds.contains($0.id) }) { character in
                        CharacterChip(character: character, compact: true) { store.selectCharacter(character.id) }
                    }
                    Button { tagsOpen = true } label: { Image(systemName: "plus").font(.system(size: 13)).frame(width: 24, height: 24).background(ScrivTheme.inset, in: Circle()) }
                        .buttonStyle(.plain).foregroundStyle(ScrivTheme.accent).help("Tag characters in this image")
                        .popover(isPresented: $tagsOpen) { CharacterTagsPopover(image: asset).environmentObject(store) }
                } else {
                    Button("Import an image…") { store.importImage(cueId: cue?.id) }.font(.system(size: 11)).buttonStyle(.borderless)
                }
                Spacer(minLength: 0)
                if let asset { Text("Version \(asset.version)").font(.system(size: 10)).foregroundStyle(.tertiary) }
            }.frame(height: 24)
            PlaybackBar(compact: false)
            LayerTimelineView().frame(maxHeight: .infinity)
            GenerationBar(controller: store.codex).environmentObject(store)
        }.padding(17).background(ScrivTheme.panel).clipShape(RoundedRectangle(cornerRadius: 17))
            .sheet(isPresented: $fullScreen) {
                VStack(spacing: 16) {
                    HStack { Text(store.project.title).font(.headline); Spacer(); Button("Done") { fullScreen = false }.keyboardShortcut(.cancelAction) }
                    AssetImageView(url: asset.flatMap { store.assetURL($0) }, title: cue?.label ?? "Preview", fill: false).frame(minWidth: 800, minHeight: 450)
                    PlaybackBar(compact: false).environmentObject(store)
                }.padding(20).frame(width: 960, height: 640)
            }
    }
    private var previewSubtitle: String {
        if let entry = store.project.activeEntry(at: Int(store.playheadMs), sceneId: store.selectedSceneID) {
            let number = (store.sceneEntries.firstIndex { $0.id == entry.id } ?? 0) + 1
            return "Entry \(String(format: "%02d", number)) · \(entry.kind == .direction ? "Direction" : store.project.character(entry.characterId)?.name ?? "Dialogue")"
        }
        return cue?.label ?? "Select an entry or image"
    }
}

struct PlaybackBar: View {
    @EnvironmentObject private var store: WorkspaceStore
    var compact = false
    @State private var rate = 1.0
    var body: some View {
        HStack(spacing: compact ? 14 : 12) {
            Button { previous() } label: { Image(systemName: "backward.end.fill").font(.system(size: 16)) }.buttonStyle(.plain).help("Previous image")
            Button { store.togglePlayback() } label: {
                Image(systemName: store.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white).frame(width: 40, height: 40).background(ScrivTheme.accent.gradient, in: Circle())
            }.buttonStyle(.plain).accessibilityLabel(store.isPlaying ? "Pause" : "Play").help("Play / pause (Option–Space)")
            Button { next() } label: { Image(systemName: "forward.end.fill").font(.system(size: 16)) }.buttonStyle(.plain).help("Next image")
            if !compact {
                Text("\(ScrivFormat.time(Int(store.playheadMs))) / \(ScrivFormat.time(store.sceneDurationMs))")
                    .font(.system(size: 11, weight: .medium, design: .monospaced)).lineLimit(1).fixedSize()
            }
            Slider(value: Binding(get: { min(Double(max(1, store.sceneDurationMs)), max(0, store.playheadMs)) }, set: { store.seek(toMs: $0) }), in: 0...Double(max(1, store.sceneDurationMs)))
                .controlSize(.small).accessibilityLabel("Playback position")
            if compact { Text(ScrivFormat.time(Int(store.playheadMs))).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).monospacedDigit() }
        }.foregroundStyle(ScrivTheme.accent).padding(.horizontal, 13).padding(.vertical, 7)
            .background(ScrivTheme.inset.opacity(0.35), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(ScrivTheme.hairline.opacity(0.35)))
    }
    private func previous() {
        let times = store.sceneCues.map(\.startMs).filter { Double($0) < store.playheadMs - 100 }
        store.seek(toMs: Double(times.last ?? 0))
    }
    private func next() {
        let time = store.sceneCues.first { Double($0.startMs) > store.playheadMs + 100 }?.startMs ?? store.sceneDurationMs
        store.seek(toMs: Double(time))
    }
}

struct GenerationBar: View {
    @EnvironmentObject private var store: WorkspaceStore
    @ObservedObject var controller: CodexController
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            TextField("Describe the image for this moment…", text: $store.generationPrompt, axis: .vertical)
                .font(.system(size: 12)).textFieldStyle(.plain).lineLimit(1...3)
                .accessibilityLabel("Image generation prompt")
            Button { store.generateImage(cueId: store.selectedCue?.id ?? store.currentCue?.id) } label: {
                HStack(spacing: 6) {
                    if controller.isGenerating { ProgressView().controlSize(.mini).tint(.white) }
                    else { Image(systemName: "sparkles") }
                    Text(controller.isGenerating ? "Generating" : "Generate image")
                }.font(.system(size: 12, weight: .semibold)).padding(.vertical, 5)
            }.buttonStyle(.borderedProminent).disabled(controller.isGenerating || store.generationPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help(controller.isConnected ? "Generate with Codex on this Mac" : "Connect Codex on this Mac to generate")
        }.padding(10).background(ScrivTheme.inset.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct CharacterTagsPopover: View {
    @EnvironmentObject private var store: WorkspaceStore
    let image: ImageAsset
    private var current: ImageAsset { store.project.asset(image.id) ?? image }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Who is pictured?").font(.headline)
            Text("Tags describe the people visible in this image.").font(.caption).foregroundStyle(.secondary)
            ForEach(store.project.characters) { character in
                Toggle(isOn: Binding(get: { current.characterIds.contains(character.id) }, set: { enabled in
                    var tags = current.characterIds
                    if enabled { tags.append(character.id) } else { tags.removeAll { $0 == character.id } }
                    store.setCharacterTags(imageId: current.id, characterIds: Array(Set(tags)))
                })) { CharacterChip(character: character, compact: false) }
            }
            if store.project.characters.isEmpty { Button("Add a character") { store.addCharacter() } }
        }.padding(18).frame(width: 270)
    }
}
