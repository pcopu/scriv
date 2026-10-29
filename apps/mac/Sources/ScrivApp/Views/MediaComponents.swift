import SwiftUI
import AppKit
import ScrivCore

struct AssetImageView: View {
    var url: URL?
    var title: String = "Storyboard image"
    var cornerRadius: CGFloat = 12
    var fill = true
    var unavailableText: String?
    @State private var loaded: NSImage?
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(colors: [ScrivTheme.canvas, ScrivTheme.inset], startPoint: .topLeading, endPoint: .bottomTrailing)
                if let loaded {
                    if fill {
                        Image(nsImage: loaded).resizable().scaledToFill().frame(width: proxy.size.width, height: proxy.size.height).clipped()
                    } else {
                        Image(nsImage: loaded).resizable().scaledToFit().frame(width: proxy.size.width, height: proxy.size.height)
                    }
                } else {
                    VStack(spacing: 9) {
                        Image(systemName: "photo").font(.system(size: 29, weight: .ultraLight))
                        Text(unavailableText ?? (url == nil ? "Add an image" : "Image unavailable on this Mac")).font(.system(size: 12, weight: .medium))
                    }.foregroundStyle(.secondary)
                }
            }
        }.clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .accessibilityLabel(title)
            .task(id: url) {
                loaded = nil
                guard let url, url.isFileURL else { return }
                let data = await Task.detached(priority: .utility) { try? Data(contentsOf: url, options: .mappedIfSafe) }.value
                guard !Task.isCancelled, let data else { return }
                loaded = NSImage(data: data)
            }
    }
}

struct LinkedScriptText: View {
    let text: String
    let characters: [ScriptCharacter]
    var characterLinks: [CharacterTextLink] = []
    var size: CGFloat = 17
    var direction = false
    var color: Color = ScrivTheme.ink
    var activeWordIndex: Int? = nil
    var remoteSelections: [PresencePeer] = []
    var onCharacter: (String) -> Void
    var body: some View {
        Text(attributedText).font(direction ? Font.system(size: size).italic() : Font.system(size: size))
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "scriv-character" else { return .systemAction }
                let id = url.lastPathComponent
                guard !id.isEmpty else { return .discarded }
                onCharacter(id); return .handled
            })
            .overlay(alignment: .topLeading) {
                GeometryReader { proxy in
                    ForEach(Array(remoteSelections.enumerated()), id: \.element.id) { index, peer in
                        if let offset = peer.selection?["end"]?.int {
                            let point = caretPoint(offset: offset, width: proxy.size.width)
                            let peerColor = ScrivTheme.color(["blue", "green", "purple", "orange"][index % 4])
                            Rectangle().fill(peerColor).frame(width: 2, height: size + 3)
                                .overlay(alignment: .bottomLeading) {
                                    Text(peer.name).font(.system(size: 9, weight: .medium)).foregroundStyle(.white)
                                        .padding(.horizontal, 4).padding(.vertical, 2).background(peerColor, in: RoundedRectangle(cornerRadius: 3))
                                        .fixedSize().offset(y: 15)
                                }.offset(x: point.x, y: point.y)
                        }
                    }
                }.allowsHitTesting(false)
            }
    }
    private var attributedText: AttributedString {
        var value = AttributedString(text)
        value.foregroundColor = color
        for suggestion in characterLinks where !suggestion.isConfirmed && CharacterMentions.matchesSource(suggestion, in: text) {
            guard let range = Range(suggestion.range, in: text),
                  let start = AttributedString.Index(range.lowerBound, within: value),
                  let end = AttributedString.Index(range.upperBound, within: value) else { continue }
            value[start..<end].backgroundColor = Color.orange.opacity(0.09)
        }
        for mention in CharacterMentions.resolved(in: text, links: characterLinks) {
            guard let character = characters.first(where: { $0.id == mention.characterId }),
                  let range = Range(mention.range, in: text),
                  let start = AttributedString.Index(range.lowerBound, within: value),
                  let end = AttributedString.Index(range.upperBound, within: value),
                  let url = URL(string: "scriv-character://open/" + character.id) else { continue }
            value[start..<end].link = url
            value[start..<end].backgroundColor = ScrivTheme.color(character.color).opacity(0.13)
            value[start..<end].foregroundColor = ScrivTheme.accent
        }
        for (index, peer) in remoteSelections.enumerated() {
            guard let begin = peer.selection?["start"]?.int, let end = peer.selection?["end"]?.int, begin >= 0, end > begin,
                  let range = Range(NSRange(location: begin, length: end - begin), in: text),
                  let lower = AttributedString.Index(range.lowerBound, within: value), let upper = AttributedString.Index(range.upperBound, within: value) else { continue }
            value[lower..<upper].backgroundColor = ScrivTheme.color(["blue", "green", "purple", "orange"][index % 4]).opacity(0.16)
        }
        if let index = activeWordIndex, let regex = try? NSRegularExpression(pattern: "\\S+") {
            let words = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            if words.indices.contains(index), let range = Range(words[index].range, in: text),
               let lower = AttributedString.Index(range.lowerBound, within: value), let upper = AttributedString.Index(range.upperBound, within: value) {
                value[lower..<upper].backgroundColor = ScrivTheme.accent
                value[lower..<upper].foregroundColor = .white
            }
        }
        return value
    }
    private func caretPoint(offset: Int, width: CGFloat) -> CGPoint {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 3
        let baseFont = NSFont.systemFont(ofSize: size)
        let font = direction ? NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask) : baseFont
        let storage = NSTextStorage(string: text, attributes: [.font: font, .paragraphStyle: paragraph])
        let manager = NSLayoutManager(), container = NSTextContainer(size: CGSize(width: max(1, width), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0; manager.addTextContainer(container); storage.addLayoutManager(manager); manager.ensureLayout(for: container)
        let length = (text as NSString).length
        guard length > 0 else { return .zero }
        let position = min(max(0, offset), length)
        if position == length {
            let glyph = manager.glyphIndexForCharacter(at: length - 1)
            let rect = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            return CGPoint(x: min(width - 1, rect.maxX), y: rect.minY)
        }
        let glyph = manager.glyphIndexForCharacter(at: position)
        let rect = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        return CGPoint(x: rect.minX, y: rect.minY)
    }
}

struct WordPill: View {
    let text: String
    var selected = false
    var active = false
    var small = false
    var onSelect: () -> Void
    var body: some View {
        Button(action: onSelect) {
            Text(text).font(.system(size: small ? 10 : 18, weight: selected || active ? .medium : .regular))
                .foregroundStyle(selected || active ? Color.white : ScrivTheme.ink)
                .padding(.horizontal, small ? 7 : 13).padding(.vertical, small ? 5 : 8)
                .background(selected || active ? ScrivTheme.accent : ScrivTheme.inset.opacity(0.85), in: RoundedRectangle(cornerRadius: small ? 5 : 8))
                .overlay(RoundedRectangle(cornerRadius: small ? 5 : 8).strokeBorder(selected ? ScrivTheme.accent : ScrivTheme.hairline.opacity(0.35)))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct DirectionBand: View {
    let text: String
    let color: Color
    var selected = false
    var onSelect: () -> Void
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease").font(.system(size: 8, weight: .medium)).rotationEffect(.degrees(90))
                Text(text).font(.system(size: 14)).italic().lineLimit(2).minimumScaleFactor(0.8).frame(maxWidth: .infinity)
                Image(systemName: "line.3.horizontal.decrease").font(.system(size: 8, weight: .medium)).rotationEffect(.degrees(90))
            }.foregroundStyle(color).padding(.vertical, 7).padding(.horizontal, 8)
                .background(color.opacity(selected ? 0.22 : 0.12), in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }
}

struct PillSegmentPicker<Value: Hashable>: View {
    let values: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    var body: some View {
        HStack(spacing: 2) {
            ForEach(values, id: \.self) { value in
                Button { withAnimation(.easeInOut(duration: 0.15)) { selection = value } } label: {
                    Text(title(value)).font(.system(size: 13, weight: selection == value ? .semibold : .medium))
                        .foregroundStyle(selection == value ? ScrivTheme.ink : ScrivTheme.secondary)
                        .padding(.vertical, 8).frame(minWidth: 94)
                        .background(selection == value ? ScrivTheme.panel : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        .shadow(color: selection == value ? .black.opacity(0.07) : .clear, radius: 3, y: 1)
                }.buttonStyle(.plain).accessibilityAddTraits(selection == value ? .isSelected : [])
            }
        }.padding(3).background(ScrivTheme.inset.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Choosing a version changes only this placement. Historical image identities,
/// character tags and discussions continue to reference their original assets.
struct ImageVersionsPopover: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    let cueID: String
    let imageID: String
    private var versions: [ImageAsset] { ProjectEditing.imageVersions(in: store.project, imageId: imageID) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Image versions").font(.headline)
            Text("Use a version for this placement. Existing discussions keep their original image.").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(versions) { image in
                        Button {
                            store.setCueImage(cueID, imageId: image.id)
                            dismiss()
                        } label: {
                            HStack(spacing: 10) {
                                AssetImageView(url: store.assetURL(image), title: "Version \(image.version)", cornerRadius: 6, unavailableText: "Not downloaded")
                                    .frame(width: 94, height: 58)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("Version \(image.version)").font(.system(size: 13, weight: .semibold))
                                    Text(image.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if store.project.cues.first(where: { $0.id == cueID })?.imageId == image.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(ScrivTheme.accent) }
                            }.padding(7).background(ScrivTheme.inset, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).disabled(store.lockedByOther(cueID) != nil)
                    }
                }
            }.frame(maxHeight: 330)
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }.padding(16).frame(width: 340)
    }
}

/// Reusing an image never imports a duplicate or rewrites its version identity.
struct ProjectImagePicker: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    let cueID: String
    let navigationContext: Int
    @State private var search = ""
    @State private var selectedImageID: String?
    private var images: [ImageAsset] {
        store.project.images.filter { image in
            search.isEmpty || image.prompt.localizedCaseInsensitiveContains(search)
                || store.project.characters.contains { image.characterIds.contains($0.id) && ([$0.name] + $0.aliases).contains { $0.localizedCaseInsensitiveContains(search) } }
        }.sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Choose an image").font(.title2.weight(.semibold))
                    Text("Reuse an existing asset for this placement. Other placements and image discussions stay unchanged.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            TextField("Find by image direction, character or alias", text: $search).textFieldStyle(.roundedBorder)
            if images.isEmpty {
                EmptyPanel(symbol: "photo.on.rectangle", title: search.isEmpty ? "No project images yet" : "No matching images", message: search.isEmpty ? "Import or generate an image first, then reuse it in any placement." : "Try another character name or a word from the image direction.")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 15) {
                        ForEach(images) { image in
                            Button { selectedImageID = image.id } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    AssetImageView(url: store.assetURL(image), title: "Image version \(image.version)", cornerRadius: 9, unavailableText: "Not downloaded")
                                        .aspectRatio(16 / 9, contentMode: .fit)
                                        .overlay(alignment: .topTrailing) {
                                            if selectedImageID == image.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, ScrivTheme.accent).font(.title3).padding(8) }
                                        }
                                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selectedImageID == image.id ? ScrivTheme.accent : .clear, lineWidth: 3))
                                    Text(image.prompt.isEmpty ? "Image" : image.prompt).font(.system(size: 11)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                    HStack {
                                        Text("Version \(image.version)")
                                        Spacer()
                                        if store.assetURL(image) == nil { Image(systemName: "icloud.and.arrow.down") }
                                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                                }.padding(4).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityAddTraits(selectedImageID == image.id ? .isSelected : [])
                        }
                    }
                }
            }
            HStack {
                Text("Only this image placement changes.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Use image") {
                    guard store.navigationContext == navigationContext, let selectedImageID else { dismiss(); return }
                    store.setCueImage(cueID, imageId: selectedImageID); dismiss()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(selectedImageID == nil || store.lockedByOther(cueID) != nil || !store.project.cues.contains(where: { $0.id == cueID }))
            }
        }.padding(22).frame(width: 820, height: 600)
            .onAppear { selectedImageID = store.project.cues.first(where: { $0.id == cueID })?.imageId }
            .onChange(of: store.navigationContext) { _, context in if context != navigationContext { dismiss() } }
    }
}
