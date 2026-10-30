import SwiftUI
import ScrivCore

/// Review is deliberately separate from the live editor. Closing it retains the
/// journal; only the explicit discard action deletes a pending recovery record.
struct RecoveredDraftView: View {
    let record: LocalEditorDraft
    let currentEntry: ScriptEntry
    let lineLabel: String
    let recovered: Bool
    let needsRebase: Bool
    let issue: String?
    let applying: Bool
    let onKeep: () -> Void
    let onRebase: () -> Void
    let onApply: () -> Void
    let onDiscard: () -> Void
    @State private var confirmingDiscard = false
    private var matchesCurrent: Bool { record.text == currentEntry.text }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "doc.badge.clock").font(.system(size: 25, weight: .light)).foregroundStyle(ScrivTheme.accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text(recovered ? "Recovered draft" : "Review local draft").font(.system(size: 23, weight: .semibold))
                    Text(lineLabel).font(.system(size: 14)).foregroundStyle(ScrivTheme.secondary)
                }
                Spacer()
            }.padding(.horizontal, 26).frame(height: 86).background(ScrivTheme.chrome.opacity(0.12))
            Divider().opacity(0.45)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ScrivNotice(tone: .warning, title: matchesCurrent ? "Recovery copy saved on this Mac" : "Saved on this Mac · Not uploaded",
                                message: matchesCurrent ? "This recovery copy matches the current saved line. It does not undo an autosaved edit." : "This draft copy is only on your Mac until you apply it.")
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Current saved line").font(.system(size: 16, weight: .semibold))
                        textBox(Text(currentEntry.text.isEmpty ? "Empty line" : currentEntry.text))
                        Text("Your local draft").font(.system(size: 16, weight: .semibold)).padding(.top, 8)
                        textBox(Text(highlightedDraft))
                        Text("Review the current line before applying. Its owned timing stays unchanged.").font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                        if needsRebase {
                            ScrivNotice(tone: .warning, title: "The saved line or timing changed", message: "Use the current saved line as the base before applying this draft. Current timing is kept; character links in replaced text will need review.")
                            Button("Use current saved line as base", action: onRebase).buttonStyle(ScrivSecondaryButtonStyle()).disabled(applying)
                        }
                    }.padding(18).background(ScrivTheme.panel, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ScrivTheme.hairline))
                    if let issue {
                        ScrivNotice(tone: .error, title: "Draft not applied", message: issue)
                        Text("Keep it for later to return to the saved script, or revise the draft in the line editor before trying again.").font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    DisclosureGroup("Why am I seeing this?") {
                        Text("Scriv keeps a separate local recovery copy when editing is interrupted or a change cannot be applied. This draft began at revision \(record.sourceRevision). Keeping it for later does not apply it; reopen this line to review it again.")
                            .font(.system(size: 13)).foregroundStyle(.secondary).textSelection(.enabled).lineSpacing(3).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
                    }.font(.system(size: 14)).foregroundStyle(ScrivTheme.secondary)
                }.padding(26)
            }
            Divider().opacity(0.45)
            HStack(spacing: 16) {
                Button("Keep for later", action: onKeep).buttonStyle(ScrivSecondaryButtonStyle()).keyboardShortcut(.cancelAction).disabled(applying)
                Spacer()
                if applying { ProgressView().controlSize(.small) }
                Button("Apply reviewed draft", action: onApply).buttonStyle(ScrivPrimaryButtonStyle()).disabled(applying || needsRebase).keyboardShortcut(.defaultAction)
            }.padding(.horizontal, 26).padding(.vertical, 20)
            Divider().opacity(0.45)
            HStack {
                Button("Discard draft…", role: .destructive) { confirmingDiscard = true }.buttonStyle(.plain).foregroundStyle(.red).font(.system(size: 13)).disabled(applying)
                Spacer()
            }.padding(.horizontal, 26).frame(height: 52).background(ScrivTheme.chrome.opacity(0.12))
        }.frame(width: 560, height: 740).background(ScrivTheme.panel)
            .confirmationDialog("Discard this local draft?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("Discard local draft", role: .destructive, action: onDiscard)
            } message: { Text("Only this pending recovery copy is removed. The saved script will not change, and valid autosaved edits are not undone.") }
            .interactiveDismissDisabled(applying)
    }
    private func textBox(_ text: Text) -> some View {
        text.font(.system(size: 17)).lineSpacing(4).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading).padding(14)
            .background(ScrivTheme.panel, in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(ScrivTheme.hairline))
    }
    private var highlightedDraft: AttributedString {
        guard !record.text.isEmpty else { return AttributedString("Empty line") }
        var value = AttributedString(record.text)
        if let changed = RecoveredDraftComparison.changedRange(in: record.text, comparedTo: currentEntry.text),
           let range = Range(changed, in: record.text),
           let lower = AttributedString.Index(range.lowerBound, within: value), let upper = AttributedString.Index(range.upperBound, within: value) {
            value[lower..<upper].backgroundColor = ScrivTheme.accent.opacity(0.17)
        }
        return value
    }
}
