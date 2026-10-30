import SwiftUI
import AppKit
import ScrivCore

enum AssetImageLoadPhase: Equatable { case empty, loading, loaded, failed }
struct AssetImageLoadResult {
    let url: URL
    let image: NSImage?
    static func phase(for url: URL?, result: AssetImageLoadResult?) -> AssetImageLoadPhase {
        guard let url else { return .empty }
        guard let result, result.url == url else { return .loading }
        return result.image == nil ? .failed : .loaded
    }
}
private struct AssetImageLoadRequest: Equatable {
    let url: URL?
    let retry: Int
}

struct AssetImageView: View {
    var url: URL?
    var title: String = "Storyboard image"
    var cornerRadius: CGFloat = 12
    var fill = true
    var unavailableText: String?
    @State private var result: AssetImageLoadResult?
    @State private var retry = 0
    private var phase: AssetImageLoadPhase { AssetImageLoadResult.phase(for: url, result: result) }
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(colors: [ScrivTheme.canvas, ScrivTheme.inset], startPoint: .topLeading, endPoint: .bottomTrailing)
                if phase == .loaded, let loaded = result?.image {
                    if fill {
                        Image(nsImage: loaded).resizable().scaledToFill().frame(width: proxy.size.width, height: proxy.size.height).clipped()
                    } else {
                        Image(nsImage: loaded).resizable().scaledToFit().frame(width: proxy.size.width, height: proxy.size.height)
                    }
                } else if phase == .loading {
                    VStack(spacing: 9) {
                        ProgressView().controlSize(.small)
                        Text("Loading image…").font(.system(size: 12, weight: .medium))
                    }.foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 9) {
                        Image(systemName: "photo").font(.system(size: 29, weight: .ultraLight))
                        Text(unavailableText ?? (url == nil ? "Add an image" : "Image unavailable on this Mac")).font(.system(size: 12, weight: .medium))
                        if phase == .failed {
                            Button("Retry") { result = nil; retry += 1 }.buttonStyle(.borderless)
                        }
                    }.foregroundStyle(.secondary)
                }
            }
        }.clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .accessibilityLabel(title)
            .task(id: AssetImageLoadRequest(url: url, retry: retry)) {
                guard !Task.isCancelled else { return }
                result = nil
                guard let url else { return }
                guard url.isFileURL else { result = AssetImageLoadResult(url: url, image: nil); return }
                let data = await Task.detached(priority: .utility) { try? Data(contentsOf: url, options: .mappedIfSafe) }.value
                guard !Task.isCancelled else { return }
                result = AssetImageLoadResult(url: url, image: data.flatMap { NSImage(data: $0) })
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
            .lineLimit(nil)
            // Honor the column width, but never compress authored text to a
            // truncated row. The measured full height also anchors the rails.
            .fixedSize(horizontal: false, vertical: true)
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
                Text(text).font(.system(size: 14)).italic().lineLimit(2).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity)
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

/// Choosing a version changes only this placement. Its image ID and existing
/// discussion stay intact. Selection is staged until the explicit Use action.
struct ImageVersionsPopover: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    let cueID: String
    let imageID: String
    @State private var selectedImageID: String?
    @State private var navigationContext: Int?
    private var versions: [ImageAsset] { ProjectEditing.imageVersions(in: store.project, imageId: imageID) }
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Image versions").font(.system(size: 21, weight: .semibold))
            Text("Choose a version for this placement.").font(.system(size: 12)).foregroundStyle(.secondary)
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                    ForEach(versions) { image in
                        Button { selectedImageID = image.id } label: { ImageChoiceTile(image: image, selected: selectedImageID == image.id) }.buttonStyle(.plain)
                    }
                }.padding(2)
            }.frame(maxHeight: 390)
            Text("Other uses and discussions stay with their original image version.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(ScrivSecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Use version") {
                    guard navigationContext == store.navigationContext, let selectedImageID, versions.contains(where: { $0.id == selectedImageID }) else { return }
                    store.setCueImage(cueID, imageId: selectedImageID)
                    if store.project.cues.first(where: { $0.id == cueID })?.imageId == selectedImageID { dismiss() }
                }.buttonStyle(ScrivPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(selectedImageID == nil || store.lockedByOther(cueID) != nil || !store.project.cues.contains(where: { $0.id == cueID }))
            }
        }.padding(20).frame(width: 550).background(ScrivTheme.sheetBackground)
            .onAppear { selectedImageID = store.project.cues.first(where: { $0.id == cueID })?.imageId; navigationContext = store.navigationContext }
            .onChange(of: store.navigationContext) { _, context in if let navigationContext, context != navigationContext { dismiss() } }
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
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.project.images.filter { image in
            query.isEmpty || image.prompt.localizedCaseInsensitiveContains(query)
                || ImageInspectorContext.title(imageID: image.id, project: store.project).localizedCaseInsensitiveContains(query)
                || store.project.characters.contains { image.characterIds.contains($0.id) && ([$0.name] + $0.aliases).contains { $0.localizedCaseInsensitiveContains(query) } }
        }.sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
    }
    private var cue: ImageCue? { store.project.cues.first { $0.id == cueID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Choose an image").font(.system(size: 25, weight: .semibold))
                Text("For " + (cue.map { $0.label.isEmpty ? "this picture placement" : $0.label } ?? "this picture placement"))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Character, alias or image direction", text: $search).textFieldStyle(.plain)
                    .accessibilityLabel("Find an image by character, alias or image direction")
            }.padding(11).background(ScrivTheme.panel, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(ScrivTheme.hairline))
            if images.isEmpty {
                EmptyPanel(symbol: "photo.on.rectangle", title: search.isEmpty ? "No project images yet" : "No matching images", message: search.isEmpty ? "Import or generate an image first, then reuse it in any placement." : "Try another character name or a word from the image direction.")
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 15) {
                        ForEach(images) { image in
                            Button { selectedImageID = image.id } label: { ImageChoiceTile(image: image, selected: selectedImageID == image.id) }.buttonStyle(.plain)
                        }
                    }.padding(2)
                }
            }
            Divider()
            HStack(alignment: .center, spacing: 14) {
                Label("Only this placement changes. Other uses and discussions stay intact.", systemImage: "info.circle")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Cancel") { dismiss() }.buttonStyle(ScrivSecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Use image") {
                    guard store.navigationContext == navigationContext, let selectedImageID, store.project.asset(selectedImageID) != nil else { return }
                    store.setCueImage(cueID, imageId: selectedImageID)
                    if store.project.cues.first(where: { $0.id == cueID })?.imageId == selectedImageID { dismiss() }
                }.buttonStyle(ScrivPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(selectedImageID == nil || store.lockedByOther(cueID) != nil || cue == nil)
            }
        }.padding(24).frame(width: 710, height: 720).background(ScrivTheme.sheetBackground)
            .onAppear { selectedImageID = cue?.imageId }
            .onChange(of: store.navigationContext) { _, context in if context != navigationContext { dismiss() } }
    }
}
