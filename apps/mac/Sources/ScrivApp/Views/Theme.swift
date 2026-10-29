import SwiftUI
import AppKit
import ScrivCore

/// Native adaptive materials and type; blue is reserved for interaction and playback.
enum ScrivTheme {
    static let accent = Color(red: 0.02, green: 0.36, blue: 0.98)
    static let ink = Color(nsColor: .labelColor)
    static let secondary = Color(nsColor: .secondaryLabelColor)
    static let canvas = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(red: 0.10, green: 0.13, blue: 0.18, alpha: 1)
        : NSColor(red: 0.91, green: 0.95, blue: 0.98, alpha: 1)
    })
    static let panel = Color(nsColor: .textBackgroundColor)
    static let inset = Color(nsColor: .controlBackgroundColor)
    static let hairline = Color(nsColor: .separatorColor).opacity(0.45)
    static let directionColors = ["#A350EA", "#F47A63", "#16B9B7", "#5A85D4", "#C89D31"]
    static func color(_ hex: String) -> Color {
        let names = ["blue": "1768E8", "purple": "A350EA", "coral": "F47A63", "teal": "16B9B7", "orange": "E6A33A", "green": "24A878", "pink": "DD6DB3"]
        let raw = (names[hex.lowercased()] ?? hex).trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard let value = UInt64(raw, radix: 16), raw.count == 6 else { return accent }
        return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}

struct Panel<Content: View>: View {
    var padding: CGFloat = 18
    let content: Content
    init(padding: CGFloat = 18, @ViewBuilder content: () -> Content) { self.padding = padding; self.content = content() }
    var body: some View {
        content.padding(padding).background(ScrivTheme.panel.opacity(0.96))
            .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(ScrivTheme.hairline.opacity(0.25)))
    }
}

struct IconButton: View {
    let symbol: String
    let label: String
    var prominent = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium))
                .frame(width: 32, height: 32)
                .background(prominent ? ScrivTheme.accent.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain).foregroundStyle(ScrivTheme.accent)
        .help(label).accessibilityLabel(label)
    }
}

struct EmptyPanel: View {
    let symbol: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 34, weight: .light)).foregroundStyle(ScrivTheme.secondary)
            Text(title).font(.title3.weight(.semibold))
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 320)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
    }
}

struct CharacterChip: View {
    let character: ScriptCharacter
    var compact = false
    var selected = false
    var action: (() -> Void)? = nil
    var body: some View {
        let color = ScrivTheme.color(character.color)
        Button { action?() } label: {
            HStack(spacing: compact ? 4 : 6) {
                Circle().fill(color).frame(width: compact ? 7 : 9, height: compact ? 7 : 9)
                Text(character.name).font(.system(size: compact ? 10 : 11, weight: .medium)).lineLimit(1)
            }.padding(.horizontal, compact ? 6 : 9).padding(.vertical, compact ? 4 : 6)
                .background(selected ? color.opacity(0.2) : ScrivTheme.inset.opacity(0.7), in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? color.opacity(0.55) : ScrivTheme.hairline.opacity(0.4)))
        }.buttonStyle(.plain).accessibilityLabel("Open character \(character.name)")
    }
}

struct InitialAvatar: View {
    let name: String
    var color: Color = ScrivTheme.accent
    var size: CGFloat = 28
    var body: some View {
        Text(String(name.prefix(1)).uppercased()).font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white).frame(width: size, height: size)
            .background(color.gradient, in: Circle()).overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1.5))
            .accessibilityLabel(name)
    }
}

struct StatusDot: View {
    var color: Color
    var body: some View { Circle().fill(color).frame(width: 8, height: 8) }
}

/// A wrapping layout used for word pills and character tags. Unlike a grid it preserves source order.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var rowSpacing: CGFloat = 7
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? 400, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, point) in result.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }
    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        let width = max(width, 1)
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, points: [CGPoint] = []
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + rowSpacing; rowHeight = 0 }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: width, height: y + rowHeight), points)
    }
}

struct DurationPill: View {
    let milliseconds: Int
    var dark = false
    var editable = true
    let onChange: (Int) -> Void
    @State private var editing = false
    @State private var seconds = ""
    var body: some View {
        Button {
            seconds = String(format: "%.2f", Double(milliseconds) / 1000)
            editing = true
        } label: {
            Text(ScrivFormat.duration(milliseconds)).font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(dark ? Color.white : ScrivTheme.ink)
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background(dark ? Color.black.opacity(0.55) : ScrivTheme.inset, in: Capsule())
                .overlay(Capsule().strokeBorder(dark ? .white.opacity(0.5) : ScrivTheme.hairline.opacity(0.4)))
        }.buttonStyle(.plain).disabled(!editable)
            .help("Edit owned duration")
            .popover(isPresented: $editing, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Duration").font(.headline)
                    HStack {
                        TextField("Seconds", text: $seconds).textFieldStyle(.roundedBorder).frame(width: 100)
                            .onSubmit(commit)
                        Text("seconds").foregroundStyle(.secondary)
                    }
                    Button("Apply", action: commit).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }.padding(18)
            }
    }
    private func commit() {
        guard let value = Double(seconds), value.isFinite, value >= 0, value <= 86400 else { NSSound.beep(); return }
        onChange(Int((value * 1000).rounded())); editing = false
    }
}

struct ViewFramePreference: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}

extension View {
    func measureFrame(_ id: String, in coordinateSpace: String) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: ViewFramePreference.self, value: [id: proxy.frame(in: .named(coordinateSpace))])
        })
    }
}
