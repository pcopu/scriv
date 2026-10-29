import SwiftUI
import AppKit
import ScrivCore

struct PreviewPane: View {
    @EnvironmentObject private var store: WorkspaceStore
    @State private var fullScreen = false
    @State private var tagsOpen = false
    @State private var versionsOpen = false
    @State private var choosingImage = false
    @State private var anchorEditor: CueAnchorSelection?
    private var cue: ImageCue? { store.isPlaying ? store.currentCue : (store.selectedCue ?? store.currentCue) }
    private var asset: ImageAsset? { store.project.asset(cue?.imageId) }
    private var overlappingCues: [ImageCue] { store.sceneCues.filter { $0.startMs <= Int(store.playheadMs) && $0.endMs > Int(store.playheadMs) } }
    var body: some View {
        ScrollView {
        VStack(spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Preview").font(.system(size: 27, weight: .semibold))
                    Text(previewSubtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("16:9").font(.system(size: 11, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 7)
                    .background(ScrivTheme.inset, in: RoundedRectangle(cornerRadius: 8))
                IconButton(symbol: "arrow.up.left.and.arrow.down.right", label: "Expand preview") { fullScreen = true }
            }
            ZStack(alignment: .bottomTrailing) {
                AssetImageView(url: asset.flatMap { store.assetURL($0) }, title: cue?.label ?? "Scene preview", unavailableText: asset == nil ? nil : "Image not on this Mac")
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay(alignment: .bottom) {
                        if let asset, store.assetURL(asset) == nil {
                            Button("Fetch image", systemImage: "arrow.down.circle") { store.downloadImage(asset) }
                                .buttonStyle(.borderedProminent).padding(.bottom, 20)
                        }
                    }
                Menu {
                    if let asset, store.assetURL(asset) == nil { Button("Fetch image", systemImage: "arrow.down.circle") { store.downloadImage(asset) } }
                    if cue != nil { Button("Choose existing image…", systemImage: "photo.on.rectangle") { choosingImage = true } }
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
            if overlappingCues.count > 1 {
                HStack(spacing: 8) {
                    Menu {
                        ForEach(overlappingCues.reversed()) { candidate in
                            Button {
                                if store.isPlaying { store.togglePlayback() }
                                store.selectedCueID = candidate.id
                            } label: {
                                Label(candidate.label.isEmpty ? "Placement at \(ScrivFormat.time(candidate.startMs))" : candidate.label,
                                      systemImage: candidate.id == cue?.id ? "checkmark.circle.fill" : "photo")
                            }
                        }
                    } label: { Label("\(overlappingCues.count) overlapping pictures", systemImage: "square.3.layers.3d") }
                        .font(.caption).menuStyle(.borderlessButton).fixedSize()
                    Spacer()
                    Text("Playback uses latest start").font(.caption2).foregroundStyle(.secondary)
                }.help("All placements are preserved. Choose one to inspect it while paused; playback shows one picture, not a blend.")
            }
            if let cue {
                if cue.durationMs == 0, (cue.authoredDurationMs ?? 0) > 0 {
                    Label("Dormant · waiting for following script time", systemImage: "clock")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(alignment: .top) {
                    Text("\(ScrivFormat.duration(cue.authoredDurationMs ?? cue.durationMs)) authored · \(ScrivFormat.duration(cue.durationMs)) in scene")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    if !store.isPlaying, cue.id != store.currentCue?.id {
                        Button("Follow playhead") { store.selectedCueID = store.currentCue?.id }.font(.caption).buttonStyle(.borderless)
                            .help("Currently inspecting a selected picture instead of the playback picture")
                    }
                }
            }
            if let cue {
                Button {
                    if store.isPlaying { store.togglePlayback() }
                    anchorEditor = CueAnchorSelection(cue: cue, navigationContext: store.navigationContext)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "link")
                        if let anchor = cue.startAnchor, let entry = store.project.entries.first(where: { $0.id == anchor.entryId }) {
                            Text("Source: " + CueAnchorEditor.label(entry, project: store.project)).lineLimit(1)
                        } else { Text("Choose picture source… (legacy scene placement)") }
                        Spacer(minLength: 0)
                        Image(systemName: "pencil").font(.caption2)
                    }.font(.caption)
                }.buttonStyle(.borderless).disabled(store.lockedByOther(cue.id) != nil)
                    .help("Choose an explicit source owner, including a zero-owned direction, and its entry-relative offset")
            }
            HStack(spacing: 5) {
                if let asset {
                    ForEach(store.project.characters.filter { asset.characterIds.contains($0.id) }) { character in
                        CharacterChip(character: character) { store.selectCharacter(character.id) }
                    }
                    Button { tagsOpen = true } label: { Image(systemName: "plus").font(.system(size: 13)).frame(width: 24, height: 24).background(ScrivTheme.inset, in: Circle()) }
                        .buttonStyle(.plain).foregroundStyle(ScrivTheme.accent).help("Tag characters in this image")
                        .popover(isPresented: $tagsOpen) { CharacterTagsPopover(image: asset).environmentObject(store) }
                } else {
                    Button("Import an image…") { store.importImage(cueId: cue?.id) }.font(.system(size: 11)).buttonStyle(.borderless)
                }
                Spacer(minLength: 0)
                if let asset, let cue {
                    Button { versionsOpen = true } label: {
                        HStack(spacing: 4) { Text("Version \(asset.version)"); Image(systemName: "chevron.down").font(.system(size: 8)) }.font(.system(size: 11))
                    }.buttonStyle(.borderless).help("View and restore image versions")
                        .popover(isPresented: $versionsOpen) { ImageVersionsPopover(cueID: cue.id, imageID: asset.id).environmentObject(store) }
                }
            }.frame(minHeight: 28)
            PlaybackBar(compact: false)
            LayerTimelineView().frame(height: 320)
            GenerationBar(controller: store.codex).environmentObject(store)
        }.padding(12)
        }.background(ScrivTheme.panel).clipShape(RoundedRectangle(cornerRadius: ScrivTheme.panelRadius))
            .sheet(isPresented: $choosingImage) {
                if let cue { ProjectImagePicker(cueID: cue.id, navigationContext: store.navigationContext).environmentObject(store) }
            }
            .sheet(item: $anchorEditor) { CueAnchorEditor(selection: $0).environmentObject(store) }
            .sheet(isPresented: $fullScreen) {
                VStack(spacing: 16) {
                    HStack { Text(store.project.title).font(.headline); Spacer(); Button("Done") { fullScreen = false }.keyboardShortcut(.cancelAction) }
                    AssetImageView(url: asset.flatMap { store.assetURL($0) }, title: cue?.label ?? "Preview", fill: false, unavailableText: asset == nil ? nil : "Image not on this Mac").frame(minWidth: 800, minHeight: 450)
                    PlaybackBar(compact: false).environmentObject(store)
                }.padding(20).frame(width: 960, height: 640)
            }
    }
    private var previewSubtitle: String {
        if let entry = store.project.activeEntry(at: Int(store.playheadMs), sceneId: store.selectedSceneID) {
            let timedEntries = store.sceneEntries.filter { $0.ownedDurationMs > 0 }
            let number = (timedEntries.firstIndex { $0.id == entry.id } ?? 0) + 1
            return "Entry \(String(format: "%02d", number)) · \(entry.kind == .direction ? "Direction" : store.project.character(entry.characterId)?.name ?? "Dialogue")"
        }
        return cue?.label ?? "Select an entry or image"
    }
}

struct PlaybackBar: View {
    @EnvironmentObject private var store: WorkspaceStore
    var compact = false
    var body: some View {
        HStack(spacing: compact ? 10 : 10) {
            Button { previous() } label: { Image(systemName: "backward.end.fill").font(.system(size: 16)) }.buttonStyle(.plain).help("Previous image")
            Button { store.togglePlayback() } label: {
                Image(systemName: store.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white).frame(width: 40, height: 40).background(ScrivTheme.accent.gradient, in: Circle())
            }.buttonStyle(.plain).accessibilityLabel(store.isPlaying ? "Pause" : "Play").help("Play / pause (Option–Space)")
            Button { next() } label: { Image(systemName: "forward.end.fill").font(.system(size: 16)) }.buttonStyle(.plain).help("Next image")
            if !compact {
                Text("\(ScrivFormat.time(Int(store.playheadMs))) / \(ScrivFormat.time(store.sceneDurationMs))")
                    .font(.system(size: 12, weight: .medium, design: .rounded)).lineLimit(1).fixedSize()
            }
            Slider(value: Binding(get: { min(Double(max(1, store.sceneDurationMs)), max(0, store.playheadMs)) }, set: { store.seek(toMs: $0) }), in: 0...Double(max(1, store.sceneDurationMs)))
                .controlSize(.small).accessibilityLabel("Playback position")
            if compact { Text(ScrivFormat.time(Int(store.playheadMs))).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).monospacedDigit() }
            Button { store.toggleAudioMute() } label: {
                Image(systemName: store.project.audioVolume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.system(size: 14))
            }.buttonStyle(.plain).disabled(store.project.audioClips.isEmpty)
                .help(store.project.audioClips.isEmpty ? "Import local audio in Layers to enable sound" : store.project.audioVolume == 0 ? "Unmute local audio" : "Mute local audio")
                .accessibilityLabel(store.project.audioVolume == 0 ? "Unmute local audio" : "Mute local audio")
            Slider(value: Binding(get: { store.project.audioVolume }, set: { store.setAudioVolume($0) }), in: 0...1)
                .frame(width: compact ? 50 : 64).controlSize(.small).disabled(store.project.audioClips.isEmpty)
                .accessibilityLabel("Local audio volume").help("Volume of imported project audio")
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
    @State private var cancelling = false
    @State private var showingContext = false
    var body: some View {
        let context = store.selectedImageGenerationContext
        VStack(alignment: .leading, spacing: 6) {
        if let context {
            Text("Script-aware · \(context.cueLabel.isEmpty ? "Selected cue" : context.cueLabel) · \(context.passages.count) source passages · \(context.portraits.count) portraits")
                .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
        }
        HStack(alignment: .center, spacing: 10) {
            TextField("Optional visual override for this cue…", text: $store.generationPrompt, axis: .vertical)
                .font(.system(size: 12)).textFieldStyle(.plain).lineLimit(1...3)
                .accessibilityLabel("Visual override for this image cue")
                .help("Dialogue, active forward directions and relevant identities are included automatically. This cue's override changes visual choices without rewriting the script. Clear it to follow only the source.")

            Button { store.generateImage(cueId: store.selectedCue?.id ?? store.currentCue?.id) } label: {
                HStack(spacing: 6) {
                    if controller.isGenerating { ProgressView().controlSize(.mini).tint(.white) }
                    else { Image(systemName: "sparkles") }
                    Text(controller.isGenerating ? "Generating" : "Generate image")
                }.font(.system(size: 12, weight: .semibold)).padding(.vertical, 5)
            }.buttonStyle(.borderedProminent).disabled(controller.isGenerating || context?.hasContent != true)
                .help(controller.isConnected ? "Generate with Codex on this Mac" : "Connect Codex on this Mac to generate")
            if controller.isGenerating {
                Button {
                    cancelling = true
                    Task { await controller.cancelGeneration(); cancelling = false }
                } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 17)) }
                    .buttonStyle(.plain).disabled(cancelling).help("Cancel image generation")
                    .accessibilityLabel("Cancel image generation")
            }
        }
        if let context {
            DisclosureGroup("Review source, identities and exact brief", isExpanded: $showingContext) {
                ScrollView {
                    Text(context.prompt).font(.system(size: 11)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                }.frame(maxHeight: 200)
                Text("This brief and copied portraits stay in local generation history. Only this cue's manual direction is saved with the generated image.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }.font(.system(size: 10)).foregroundStyle(.secondary)
            if !context.unreferencedCharacters.isEmpty {
                Text("Text identity only (no local portrait attached): \(context.unreferencedCharacters.map(\.name).joined(separator: ", "))")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        if controller.isGenerating { Text(controller.status).font(.system(size: 10)).foregroundStyle(.secondary) }
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
                })) {
                    HStack(spacing: 8) {
                        InitialAvatar(name: character.name, color: ScrivTheme.color(character.color), size: 23)
                        Text(character.name).font(.system(size: 12))
                    }
                }.disabled(store.lockedByOther(current.id) != nil)
            }
            if store.project.characters.isEmpty { Button("Add a character") { store.addCharacter() } }
        }.padding(18).frame(width: 270)
    }
}
