import SwiftUI
import AppKit
import ScrivCore

struct AssetImageView: View {
    var url: URL?
    var title: String = "Storyboard image"
    var cornerRadius: CGFloat = 12
    var fill = true
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
                        Text(url == nil ? "Add an image" : "Image unavailable on this Mac").font(.system(size: 12, weight: .medium))
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
    var size: CGFloat = 17
    var direction = false
    var color: Color = ScrivTheme.ink
    var onCharacter: (String) -> Void
    var body: some View {
        Text(attributedText).font(direction ? Font.system(size: size).italic() : Font.system(size: size))
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "scriv-character", let id = url.host else { return .systemAction }
                onCharacter(id); return .handled
            })
    }
    private var attributedText: AttributedString {
        var value = AttributedString(text)
        value.foregroundColor = color
        let candidates = characters.flatMap { character in ([character.name] + character.aliases).filter { !$0.isEmpty }.map { ($0, character) } }.sorted { $0.0.count > $1.0.count }
        var matched: [Range<String.Index>] = []
        for (name, character) in candidates {
            let pattern = "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: name) + "(?![\\p{L}\\p{N}_])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range, in: text), !matched.contains(where: { $0.overlaps(range) }),
                      let start = AttributedString.Index(range.lowerBound, within: value),
                      let end = AttributedString.Index(range.upperBound, within: value),
                      let url = URL(string: "scriv-character://" + character.id) else { continue }
                value[start..<end].link = url
                value[start..<end].backgroundColor = ScrivTheme.color(character.color).opacity(0.13)
                value[start..<end].foregroundColor = ScrivTheme.accent
                matched.append(range)
            }
        }
        return value
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
            Text(text).font(.system(size: small ? 10 : 15, weight: selected || active ? .medium : .regular))
                .foregroundStyle(selected || active ? Color.white : ScrivTheme.ink)
                .padding(.horizontal, small ? 7 : 11).padding(.vertical, small ? 5 : 7)
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
                Text(text).font(.system(size: 12)).italic().lineLimit(2).frame(maxWidth: .infinity)
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
