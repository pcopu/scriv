import SwiftUI
import AppKit
import ScrivCore

struct CharactersView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @State private var search = ""
    @State private var editing: ScriptCharacter?
    @State private var deleting: ScriptCharacter?
    private var characters: [ScriptCharacter] {
        store.project.characters.filter { search.isEmpty || ([$0.name] + $0.aliases).contains { $0.localizedCaseInsensitiveContains(search) } }
    }
    private var selected: ScriptCharacter? { store.selectedCharacter ?? characters.first }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Characters").font(.system(size: 25, weight: .semibold))
                Spacer()
                IconButton(symbol: "plus", label: "Add character") { store.addCharacter() }
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search characters", text: $search).textFieldStyle(.plain)
            }.font(.system(size: 13)).padding(10).background(ScrivTheme.inset, in: RoundedRectangle(cornerRadius: 9))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(characters) { character in
                        Button { store.selectCharacter(character.id) } label: {
                            VStack(spacing: 9) {
                                CharacterPortrait(character: character).frame(width: 82, height: 82)
                                    .clipShape(Circle()).padding(3)
                                    .overlay(Circle().strokeBorder(selected?.id == character.id ? ScrivTheme.accent : .clear, lineWidth: 2))
                                Text(character.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            }.frame(width: 145).padding(.vertical, 10)
                                .background(selected?.id == character.id ? ScrivTheme.accent.opacity(0.075) : .clear, in: RoundedRectangle(cornerRadius: 14))
                        }.buttonStyle(.plain).accessibilityAddTraits(selected?.id == character.id ? .isSelected : [])
                    }
                }
            }
            if let selected {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        profile(selected)
                        imageGallery(selected)
                    }.padding(17).background(ScrivTheme.inset.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
                }
            } else {
                EmptyPanel(symbol: "person.crop.rectangle.stack", title: "People make the scene", message: "Add your characters and their aliases. Names in the script open their profiles; image tags track who is pictured.")
            }
            Label("Select a name in the script to open its character.", systemImage: "info.circle.fill")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(18).background(ScrivTheme.panel).clipShape(RoundedRectangle(cornerRadius: 17))
            .sheet(item: $editing) { character in
                CharacterEditor(character: character).environmentObject(store)
                    .onDisappear { store.endEdit(character.id) }
            }
            .confirmationDialog("Delete \(deleting?.name ?? "character")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Delete Character", role: .destructive) { if let deleting { store.deleteCharacter(deleting.id) }; deleting = nil }
            } message: { Text("Their script text and images are preserved. Speaker links and character tags are removed.") }
    }
    private func profile(_ character: ScriptCharacter) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 18) {
                CharacterPortrait(character: character).frame(width: 125, height: 125).clipShape(RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(character.name).font(.system(size: 23, weight: .semibold))
                            Text("Character").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit") { Task { if await store.beginEdit(character.id) { editing = character } } }.buttonStyle(.bordered).disabled(store.lockedByOther(character.id) != nil)
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
            if !character.biography.isEmpty { Text(character.biography).font(.system(size: 13)).lineSpacing(3).textSelection(.enabled) }
            if !character.appearance.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Appearance & image direction").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Text(character.appearance).font(.system(size: 12)).textSelection(.enabled)
                }
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
                ForEach(images) { image in CharacterImageCard(image: image).environmentObject(store) }
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
    @State private var tagsOpen = false
    @State private var previewing = false
    private var cue: ImageCue? { store.project.cues.first { $0.imageId == image.id } }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AssetImageView(url: store.assetURL(image), title: cue?.label ?? "Character image", cornerRadius: 9, unavailableText: "Image not on this Mac")
                .aspectRatio(1.6, contentMode: .fit)
                .onTapGesture { previewing = true }
                .contextMenu {
                    if let cue { Button("Show in script") { store.selectedSceneID = cue.sceneId; store.selectedCueID = cue.id; store.seek(toMs: Double(cue.startMs)); store.tab = .script } }
                    Button("Discuss image") { store.loadDiscussion(itemId: image.id) }
                    if store.assetURL(image) == nil { Button("Download image") { store.downloadImage(image) } }
                    if let character = store.selectedCharacter {
                        Button("Use as \(character.name)'s portrait") { var changed = character; changed.portraitImageId = image.id; store.updateCharacter(changed) }
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
            VStack(spacing: 16) {
                HStack {
                    Text("\(cue?.label.isEmpty == false ? cue?.label ?? "Image" : "Image") · Version \(image.version)").font(.headline)
                    Spacer()
                    if store.assetURL(image) == nil { Button("Fetch image") { store.downloadImage(image) } }
                    Button("Done") { previewing = false }.keyboardShortcut(.cancelAction)
                }
                AssetImageView(url: store.assetURL(image), title: "Character image", fill: false, unavailableText: "Image not on this Mac")
                if !image.prompt.isEmpty { Text(image.prompt).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled) }
            }.padding(20).frame(width: 860, height: 590)
        }
    }
}

private struct CharacterEditor: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ScriptCharacter
    @State private var aliases: String
    init(character: ScriptCharacter) { _draft = State(initialValue: character); _aliases = State(initialValue: character.aliases.joined(separator: ", ")) }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Edit character").font(.title2.weight(.semibold))
            Form {
                TextField("Name", text: $draft.name)
                TextField("Aliases, separated by commas", text: $aliases)
                Picker("Color", selection: $draft.color) {
                    ForEach(["blue", "teal", "orange", "purple", "coral", "green", "pink"], id: \.self) { color in Text(color.capitalized).tag(color) }
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("Biography").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $draft.biography).font(.body).frame(height: 100).border(ScrivTheme.hairline)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("Appearance and image direction").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $draft.appearance).font(.body).frame(height: 85).border(ScrivTheme.hairline)
                }
            }.formStyle(.grouped)
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button("Save") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(24).frame(width: 540, height: 540)
    }
    private func save() {
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.aliases = Array(Set(aliases.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
        store.updateCharacter(draft); dismiss()
    }
}
