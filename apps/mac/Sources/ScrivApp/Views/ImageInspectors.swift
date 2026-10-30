import SwiftUI
import AppKit
import ScrivCore

/// Modal identity is an immutable image version, never the changing playhead.
struct ImageInspectionSelection: Identifiable {
    let imageID: String
    var cueID: String? = nil
    var id: String { imageID }
}

struct ImagePickerSelection: Identifiable {
    let cueID: String
    let navigationContext: Int
    var id: String { cueID }
}

enum ImageInspectorContext {
    static func placement(imageID: String, cueID: String?, project: ScrivProject) -> ImageCue? {
        if let cueID, let cue = project.cues.first(where: { $0.id == cueID && $0.imageId == imageID }) { return cue }
        return project.cues.first { $0.imageId == imageID }
    }
    static func title(imageID: String, cueID: String? = nil, project: ScrivProject) -> String {
        if let cue = placement(imageID: imageID, cueID: cueID, project: project), !cue.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return cue.label }
        if let character = project.characters.first(where: { $0.portraitImageId == imageID }) { return character.name + " portrait" }
        return "Image"
    }
}

/// The same inspector is used from Preview, Characters, Storyboard and Layers.
/// Editing tags does not replace this image, its captured prompt or its discussion.
struct ImageDetailSheet: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    let imageID: String
    var cueID: String? = nil
    @State private var tagsOpen = false
    @State private var capturedPromptOpen = false
    @State private var navigationContext: Int?
    @State private var choosingImage: ImagePickerSelection?
    private var image: ImageAsset? { store.project.asset(imageID) }
    private var cue: ImageCue? { ImageInspectorContext.placement(imageID: imageID, cueID: cueID, project: store.project) }
    private var title: String { ImageInspectorContext.title(imageID: imageID, cueID: cueID, project: store.project) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text(title).font(.system(size: 23, weight: .semibold)).lineLimit(2)
                if let image { ImageVersionBadge(version: image.version) }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(ScrivPrimaryButtonStyle()).keyboardShortcut(.cancelAction)
            }
            if let image {
                imageContent(image)
                Divider()
                imageActions(image)
            } else {
                ScrivNotice(tone: .warning, title: "This image is no longer in the project", message: "Close this preview and choose another image. No replacement version has been selected.")
                Spacer()
            }
        }.padding(22).frame(width: 900, height: 740).background(ScrivTheme.sheetBackground)
            .onAppear { navigationContext = store.navigationContext }
            .onChange(of: store.navigationContext) { _, context in if let navigationContext, context != navigationContext { dismiss() } }
            .sheet(item: $choosingImage) { ProjectImagePicker(cueID: $0.cueID, navigationContext: $0.navigationContext).environmentObject(store) }
    }
    private func imageContent(_ image: ImageAsset) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                if store.assetURL(image) == nil {
                    MissingImagePanel(image: image, title: title, chooseImage: chooseImageAction).frame(minHeight: 310)
                } else {
                    AssetImageView(url: store.assetURL(image), title: title, fill: false)
                        .aspectRatio(16 / 9, contentMode: .fit)
                }
                FlowLayout(spacing: 8) {
                    ForEach(store.project.characters.filter { image.characterIds.contains($0.id) }) { ImageCharacterTag(character: $0) }
                    Button { tagsOpen = true } label: { Label("Edit tags", systemImage: "plus") }
                        .buttonStyle(ScrivSecondaryButtonStyle(fontSize: 12))
                        .popover(isPresented: $tagsOpen) { CharacterTagsPopover(image: image, cueID: cue?.id, onAddCharacter: { dismiss(); store.addCharacter() }).environmentObject(store) }
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text("Image direction").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    Text(image.prompt.isEmpty ? "No manual image direction was recorded." : image.prompt)
                        .font(.system(size: 15)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                DisclosureGroup("Captured generation prompt", isExpanded: $capturedPromptOpen) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(image.generationPrompt ?? "No exact generation prompt was captured for this imported or older image. Its origin is not inferred from the current script.")
                            .font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        if image.generationPrompt != nil {
                            Text("The exact text submitted for this version. It is separate from the manual image direction above.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }.padding(.top, 8)
                }.font(.system(size: 12)).foregroundStyle(.secondary)
            }.padding(2)
        }
    }
    private func imageActions(_ image: ImageAsset) -> some View {
        HStack(spacing: 12) {
            Button(action: showInScript) { Label("Show in script", systemImage: "doc.text") }
                .buttonStyle(ScrivSecondaryButtonStyle()).disabled(cue == nil)
                .help(cue == nil ? "This exact image version has no current script placement." : "Show a placement of this exact image version")
            Button {
                store.loadDiscussion(itemId: image.id); store.showDiscussion = true; dismiss()
            } label: { Label("Discuss this version", systemImage: "bubble.left") }.buttonStyle(ScrivSecondaryButtonStyle())
            Spacer(minLength: 8)
            Menu {
                Button("Copy image direction") { copy(image.prompt) }.disabled(image.prompt.isEmpty)
                Button("Copy captured generation prompt") { if let prompt = image.generationPrompt { copy(prompt) } }.disabled(image.generationPrompt == nil)
                if let url = store.assetURL(image) { Button("Show image in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
            } label: { Image(systemName: "ellipsis").frame(width: 24, height: 20) }.menuStyle(.borderlessButton).fixedSize()
            Text("Viewing the original image version.").font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    private var chooseImageAction: (() -> Void)? {
        guard let cue else { return nil }
        return { choosingImage = ImagePickerSelection(cueID: cue.id, navigationContext: store.navigationContext) }
    }
    private func showInScript() {
        guard let cue else { return }
        if store.isPlaying { store.togglePlayback() }
        store.selectScene(cue.sceneId)
        store.tab = .script
        store.seek(toMs: Double(cue.startMs)); store.selectedCueID = cue.id
        if let anchor = cue.startAnchor { store.selectedEntryID = anchor.entryId }
        dismiss()
    }
    private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
}

struct ImageVersionBadge: View {
    let version: Int
    var body: some View {
        Text("Version \(version)").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 5).background(ScrivTheme.inset, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ImageCharacterTag: View {
    let character: ScriptCharacter
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(ScrivTheme.color(character.color)).frame(width: 9, height: 9)
            Text(character.name).font(.system(size: 12))
        }.padding(.horizontal, 10).padding(.vertical, 6)
            .background(ScrivTheme.inset.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(ScrivTheme.hairline))
    }
}

struct ImageChoiceTile: View {
    @EnvironmentObject private var store: WorkspaceStore
    let image: ImageAsset
    let selected: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            AssetImageView(url: store.assetURL(image), title: ImageInspectorContext.title(imageID: image.id, project: store.project), cornerRadius: 9, unavailableText: "Not on this Mac")
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay(alignment: .topTrailing) {
                    if selected { Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.white, ScrivTheme.accent).padding(9) }
                }
            HStack(alignment: .top, spacing: 6) {
                Text(ImageInspectorContext.title(imageID: image.id, project: store.project)).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                Spacer(minLength: 2)
                ImageVersionBadge(version: image.version)
            }
            FlowLayout(spacing: 5, rowSpacing: 4) {
                ForEach(store.project.characters.filter { image.characterIds.contains($0.id) }) { ImageCharacterTag(character: $0) }
            }
            if store.assetURL(image) == nil {
                Label("Not on this Mac", systemImage: "icloud.and.arrow.down").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }.padding(9).frame(maxWidth: .infinity, alignment: .topLeading)
            .background(ScrivTheme.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? ScrivTheme.accent : ScrivTheme.hairline, lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .combine).accessibilityAddTraits(selected ? .isSelected : [])
            .help(image.prompt.isEmpty ? "Image version \(image.version)" : image.prompt)
    }
}

struct MissingImagePanel: View {
    @EnvironmentObject private var store: WorkspaceStore
    let image: ImageAsset
    let title: String
    var chooseImage: (() -> Void)? = nil
    @State private var detailsOpen = false
    var body: some View {
        VStack(spacing: 13) {
            Image(systemName: "photo.badge.exclamationmark").font(.system(size: 32, weight: .light)).foregroundStyle(.secondary)
            Text("Image isn’t on this Mac").font(.system(size: 20, weight: .semibold))
            Text("\(title) · Version \(image.version)").font(.system(size: 12)).foregroundStyle(.secondary)
            Text("The script and timing are intact. Fetch this image to view it here.")
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Fetch image") { store.downloadImage(image) }.buttonStyle(ScrivPrimaryButtonStyle())
                if let chooseImage { Button("Choose another image", action: chooseImage).buttonStyle(ScrivSecondaryButtonStyle()) }
            }
            DisclosureGroup("Details", isExpanded: $detailsOpen) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("No verified local copy is available. Fetch tries the project's configured cloud storage and available peer Macs.")
                    Text("Peer transfer: " + store.peerTransferStatus)
                }.font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.font(.system(size: 11)).frame(maxWidth: 430)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ScrivTheme.inset.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct CharacterTagsPopover: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    let image: ImageAsset
    var cueID: String? = nil
    var onAddCharacter: (() -> Void)? = nil
    private var current: ImageAsset { store.project.asset(image.id) ?? image }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Who is pictured?").font(.system(size: 21, weight: .semibold))
            Text("\(ImageInspectorContext.title(imageID: image.id, cueID: cueID, project: store.project)) · Version \(image.version)")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            AssetImageView(url: store.assetURL(current), title: "Image being tagged", fill: false, unavailableText: "Not on this Mac")
                .aspectRatio(16 / 9, contentMode: .fit)
            Text("Tag people visible in this image, not people mentioned in the script.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(store.project.characters) { character in
                        HStack(spacing: 10) {
                            if let portrait = store.project.asset(character.portraitImageId), let url = store.assetURL(portrait) {
                                AssetImageView(url: url, title: character.name, cornerRadius: 22).frame(width: 40, height: 40).clipShape(Circle())
                            } else { InitialAvatar(name: character.name, color: ScrivTheme.color(character.color), size: 40) }
                            Circle().fill(ScrivTheme.color(character.color)).frame(width: 9, height: 9)
                            Text(character.name).font(.system(size: 14, weight: .medium))
                            Spacer()
                            Toggle(character.name, isOn: Binding(get: { current.characterIds.contains(character.id) }, set: { enabled in
                                var tags = current.characterIds
                                if enabled { if !tags.contains(character.id) { tags.append(character.id) } }
                                else { tags.removeAll { $0 == character.id } }
                                store.setCharacterTags(imageId: current.id, characterIds: tags)
                            })).labelsHidden().toggleStyle(.checkbox)
                                .disabled(store.lockedByOther(current.id) != nil || store.project.asset(image.id) == nil)
                        }.padding(.vertical, 9)
                        Divider()
                    }
                    if store.project.characters.isEmpty {
                        Button("Add a character") { dismiss(); if let onAddCharacter { onAddCharacter() } else { store.addCharacter() } }.buttonStyle(ScrivSecondaryButtonStyle())
                    }
                }
            }.frame(maxHeight: 240)
            HStack(spacing: 8) {
                Image(systemName: "checkmark").foregroundStyle(.green)
                Text("Changes save automatically").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(ScrivSecondaryButtonStyle()).keyboardShortcut(.cancelAction)
            }
        }.padding(20).frame(width: 370).background(ScrivTheme.sheetBackground)
    }
}
