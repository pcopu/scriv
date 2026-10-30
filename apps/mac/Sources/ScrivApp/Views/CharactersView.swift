import SwiftUI
import AppKit
import ScrivCore

/// The item and its edit lease context must enter presentation atomically.
/// A separate optional context can still be nil when SwiftUI first opens a sheet.
struct CharacterEditSelection: Identifiable {
    let character: ScriptCharacter
    let navigationContext: Int
    let isNew: Bool

    init(character: ScriptCharacter, navigationContext: Int, isNew: Bool = false) {
        self.character = character; self.navigationContext = navigationContext; self.isNew = isNew
    }
    var id: String { character.id }
}

struct CharactersView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @State private var search = ""
    @State private var editing: CharacterEditSelection?
    @State private var deleting: ScriptCharacter?
    @State private var editRequestID: UUID?
    private var characters: [ScriptCharacter] {
        store.project.characters.filter { search.isEmpty || ([$0.name] + $0.aliases).contains { $0.localizedCaseInsensitiveContains(search) } }
    }
    private var selected: ScriptCharacter? { characters.first { $0.id == store.selectedCharacterID } ?? characters.first }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Characters").font(.system(size: 29, weight: .semibold))
                Spacer()
                IconButton(symbol: "plus", label: "Add character") { store.addCharacter() }
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search characters", text: $search).textFieldStyle(.plain)
            }.font(.system(size: 14)).padding(11).background(ScrivTheme.inset, in: RoundedRectangle(cornerRadius: 9))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(characters) { character in
                        Button { store.selectCharacter(character.id) } label: {
                            VStack(spacing: 9) {
                                CharacterPortrait(character: character).frame(width: 92, height: 92)
                                    .clipShape(Circle()).padding(3)
                                    .overlay(Circle().strokeBorder(selected?.id == character.id ? ScrivTheme.accent : .clear, lineWidth: 2))
                                Text(character.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                            }.frame(width: 156).padding(.vertical, 10)
                                .background(selected?.id == character.id ? ScrivTheme.accent.opacity(0.075) : .clear, in: RoundedRectangle(cornerRadius: 14))
                        }.buttonStyle(.plain).accessibilityAddTraits(selected?.id == character.id ? .isSelected : [])
                    }
                }
            }
            if let selected {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        profile(selected)
                        imageGallery(selected)
                    }.padding(17).background(ScrivTheme.panel, in: RoundedRectangle(cornerRadius: 14))
                }
            } else if !search.isEmpty {
                EmptyPanel(symbol: "magnifyingglass", title: "No matching characters", message: "Try another name or alias.")
                Button("Clear search") { search = "" }.buttonStyle(.borderless)
            } else {
                EmptyPanel(symbol: "person.crop.rectangle.stack", title: "People make the scene", message: "Add your characters and their aliases. Confirm suggested names from a script line’s Character links review; image tags track who is pictured.")
            }
            Label("Confirmed script names open their character. Review suggestions from a line’s menu.", systemImage: "info.circle.fill")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(16).background(ScrivTheme.inset.opacity(0.42)).clipShape(RoundedRectangle(cornerRadius: 17))
            .onChange(of: store.selectedCharacterID) { _, id in
                editRequestID = nil
                if let id, !characters.contains(where: { $0.id == id }) { search = "" }
            }
            .onAppear { openRequestedCharacter() }
            .onChange(of: store.characterCreationRequest) { _, _ in openRequestedCharacter() }
            .onDisappear { editRequestID = nil }
            .sheet(item: $editing) { selection in
                CharacterEditor(character: selection.character, navigationContext: selection.navigationContext, isNew: selection.isNew).environmentObject(store)
                    .onDisappear { if !selection.isNew { store.endEdit(selection.character.id, context: selection.navigationContext) } }
            }
            .confirmationDialog("Delete \(deleting?.name ?? "character")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Delete Character", role: .destructive) { if let deleting { store.deleteCharacter(deleting.id) }; deleting = nil }
            } message: { Text("Their script text and images are preserved. Speaker links, inline links and character tags are removed; old words will not link to a reused name.") }
    }
    private func profile(_ character: ScriptCharacter) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 18) {
                CharacterPortrait(character: character).frame(width: 132, height: 132).clipShape(RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(character.name).font(.system(size: 25, weight: .semibold))
                            Text("Character").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit") { beginEditing(character) }.buttonStyle(.bordered).disabled(store.lockedByOther(character.id) != nil)
                    }
                    Divider().padding(.vertical, 5)
                    HStack(alignment: .top, spacing: 16) {
                        Text("Also called").foregroundStyle(.secondary)
                        Text(character.aliases.isEmpty ? "No aliases" : character.aliases.joined(separator: ", "))
                    }.font(.system(size: 12))
                    HStack(spacing: 12) {
                        Button { store.loadDiscussion(itemId: character.id) } label: { Label("Discuss", systemImage: "bubble.left") }
                        Menu {
                            Button("Delete character…", role: .destructive) { deleting = character }.disabled(store.lockedByOther(character.id) != nil)
                        } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                    }.font(.system(size: 11)).buttonStyle(.borderless).padding(.top, 4)
                }
            }
            if !character.biography.isEmpty || !character.appearance.isEmpty {
                DisclosureGroup("Character notes & image direction") {
                    VStack(alignment: .leading, spacing: 10) {
                        if !character.biography.isEmpty { Text(character.biography).font(.system(size: 13)).lineSpacing(3).textSelection(.enabled) }
                        if !character.appearance.isEmpty {
                            Text(character.appearance).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                }.font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
    private func openRequestedCharacter() {
        guard store.characterCreationRequest != nil, editing == nil else { return }
        editRequestID = nil
        editing = CharacterEditSelection(character: ScriptCharacter(name: ""), navigationContext: store.navigationContext, isNew: true)
        store.characterCreationRequest = nil
    }
    private func beginEditing(_ character: ScriptCharacter) {
        guard editRequestID == nil else { return }
        let request = UUID(), projectID = store.project.id, context = store.navigationContext; editRequestID = request
        Task { @MainActor in
            let allowed = await store.beginEdit(character.id)
            guard editRequestID == request, store.project.id == projectID, store.navigationContext == context else { if allowed { store.endEdit(character.id, context: context) }; return }
            editRequestID = nil
            if allowed {
                if let current = store.project.character(character.id) { editing = CharacterEditSelection(character: current, navigationContext: context) }
                else { store.endEdit(character.id, context: context) }
            }
        }
    }
    private func imageGallery(_ character: ScriptCharacter) -> some View {
        let images = store.project.images.filter { $0.characterIds.contains(character.id) }
        return VStack(alignment: .leading, spacing: 12) {
            Divider()
            HStack(spacing: 8) {
                Text("Tagged images").font(.system(size: 16, weight: .semibold))
                Text("\(images.count)").font(.system(size: 10, weight: .semibold)).padding(.horizontal, 6).padding(.vertical, 2).background(ScrivTheme.inset, in: Capsule())
                Spacer()
            }
            if images.isEmpty {
                Text("Tag this character in an image to add it here.").font(.callout).foregroundStyle(.secondary).padding(.vertical, 16)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 15) {
                ForEach(images) { image in CharacterImageCard(image: image, profileCharacterID: character.id).environmentObject(store) }
            }
        }
    }
}

struct CharacterPortrait: View {
    @EnvironmentObject private var store: WorkspaceStore
    let character: ScriptCharacter
    private var asset: ImageAsset? { store.project.asset(character.portraitImageId) ?? store.project.images.first { $0.characterIds.contains(character.id) } }
    var body: some View {
        if let url = asset.flatMap({ store.assetURL($0) }) {
            AssetImageView(url: url, title: character.name, cornerRadius: 0)
        } else {
            GeometryReader { proxy in
                ZStack {
                    ScrivTheme.color(character.color).opacity(0.13)
                    Image(systemName: "person.fill").font(.system(size: proxy.size.width * 0.52, weight: .light)).foregroundStyle(ScrivTheme.color(character.color).opacity(0.65))
                }
            }.accessibilityLabel(character.name)
        }
    }
}

private struct CharacterImageCard: View {
    @EnvironmentObject private var store: WorkspaceStore
    let image: ImageAsset
    let profileCharacterID: String
    @State private var tagsOpen = false
    @State private var previewing = false
    private var cue: ImageCue? { store.project.cues.first { $0.imageId == image.id } }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AssetImageView(url: store.assetURL(image), title: cue?.label ?? "Character image", cornerRadius: 9, unavailableText: "Image not on this Mac")
                .aspectRatio(1.6, contentMode: .fit)
                .onTapGesture { previewing = true }
                .contextMenu {
                    if let cue { Button("Show in script") { store.selectScene(cue.sceneId); store.selectedCueID = cue.id; store.seek(toMs: Double(cue.startMs)); store.tab = .script } }
                    Button("Discuss image") { store.loadDiscussion(itemId: image.id) }
                    if store.assetURL(image) == nil { Button("Download image") { store.downloadImage(image) } }
                    if let character = store.project.character(profileCharacterID) {
                        Button("Use as \(character.name)'s portrait") { store.setCharacterPortrait(character.id, imageId: image.id) }.disabled(store.lockedByOther(character.id) != nil)
                    }
                }
            HStack {
                Text(cue.flatMap { $0.label.isEmpty ? nil : $0.label } ?? "Image").font(.system(size: 11, weight: .medium))
                Spacer()
                Text("v\(image.version)").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            FlowLayout(spacing: 4, rowSpacing: 4) {
                ForEach(store.project.characters.filter { image.characterIds.contains($0.id) }) { character in
                    CharacterChip(character: character, compact: true) { store.selectCharacter(character.id) }
                }
                Button { tagsOpen = true } label: { Image(systemName: "plus").frame(width: 22, height: 22).background(ScrivTheme.inset, in: Circle()) }
                    .buttonStyle(.plain).foregroundStyle(ScrivTheme.accent).accessibilityLabel("Edit character tags")
                    .popover(isPresented: $tagsOpen) { CharacterTagsPopover(image: image).environmentObject(store) }
            }
        }.sheet(isPresented: $previewing) {
            ImageDetailSheet(imageID: image.id, cueID: cue?.id).environmentObject(store)
        }
    }
}
