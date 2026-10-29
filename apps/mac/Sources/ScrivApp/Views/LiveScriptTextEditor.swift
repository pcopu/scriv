import SwiftUI
import AppKit

/// NSTextView exposes UTF-16 caret/selection anchors on macOS 14, so presence is
/// the actual editing selection rather than an invented cursor position.
struct LiveScriptTextEditor: NSViewRepresentable {
    @Binding var text: String
    var pointSize: CGFloat
    var italic: Bool
    var onSelection: (NSRange) -> Void
    var onFinish: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> ScriptNativeTextView {
        let view = ScriptNativeTextView()
        view.isRichText = false
        view.isEditable = true
        view.isSelectable = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isContinuousSpellCheckingEnabled = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.heightTracksTextView = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.minSize = NSSize(width: 0, height: pointSize + 5)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.delegate = context.coordinator
        view.string = text
        view.textColor = .labelColor
        view.font = font
        view.finish = { context.coordinator.parent.onFinish() }
        view.setAccessibilityLabel(italic ? "Direction text" : "Dialogue text")
        return view
    }
    func updateNSView(_ view: ScriptNativeTextView, context: Context) {
        context.coordinator.parent = self
        if view.string != text {
            let selection = view.selectedRange()
            context.coordinator.updating = true
            view.string = text
            view.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
            context.coordinator.updating = false
            view.invalidateIntrinsicContentSize()
        }
        view.font = font
        if !context.coordinator.focused {
            DispatchQueue.main.async {
                guard let window = view.window, !context.coordinator.focused else { return }
                context.coordinator.focused = true
                window.makeFirstResponder(view)
                view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
            }
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ScriptNativeTextView, context: Context) -> CGSize? {
        let width = max(30, proposal.width ?? 400)
        nsView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        if let container = nsView.textContainer { nsView.layoutManager?.ensureLayout(for: container) }
        let used = nsView.textContainer.flatMap { nsView.layoutManager?.usedRect(for: $0).height } ?? pointSize + 5
        return CGSize(width: width, height: max(pointSize + 5, ceil(used) + 2))
    }
    private var font: NSFont {
        let base = NSFont.systemFont(ofSize: pointSize)
        return italic ? NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask) : base
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: LiveScriptTextEditor
        var updating = false
        var focused = false
        init(_ parent: LiveScriptTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard !updating, let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            view.invalidateIntrinsicContentSize()
            parent.onSelection(view.selectedRange())
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !updating, let view = notification.object as? NSTextView else { return }
            parent.onSelection(view.selectedRange())
        }
    }
}

final class ScriptNativeTextView: NSTextView {
    var finish: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 || (event.keyCode == 36 && !event.modifierFlags.contains(.shift) && !event.modifierFlags.contains(.option)) {
            finish?()
        } else { super.keyDown(with: event) }
    }
    override func resignFirstResponder() -> Bool {
        let success = super.resignFirstResponder()
        if success { DispatchQueue.main.async { [weak self] in self?.finish?() } }
        return success
    }
}
