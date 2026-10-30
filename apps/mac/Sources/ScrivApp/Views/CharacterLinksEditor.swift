import SwiftUI
import AppKit
import ScrivCore

/// A focused correction surface: accepting a suggestion changes metadata only.
/// The entry and navigation context are one immutable presentation snapshot.
struct CharacterLinksEditor: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    let entry: ScriptEntry
    let navigationContext: Int
    @State private var links: [CharacterTextLink] = []
    @State private var choices: [String: String] = [:]
    @State private var phrase = ""
    @State private var otherWordingExpanded = true
    @State private var hasLease = false
    @State private var opening = false
    @State private var ready = false
    @State private var reviewIssue: String?
    @State private var requiresReopening = false
    @State private var isVisible = true

    init(entry: ScriptEntry, navigationContext: Int) {
        self.entry = entry
        self.navigationContext = navigationContext
    }

    private var suggestions: [CharacterTextLink] { links.filter { !$0.isConfirmed } }
    private var confirmed: [CharacterTextLink] { links.filter(\.isConfirmed) }
    private var occurrences: [NSRange] { CharacterLinkReviewPresentation.occurrences(of: phrase, in: entry.text) }
    private var sceneDescription: String {
        let index = store.project.orderedScenes.firstIndex { $0.id == entry.sceneId }
        return "\(index.map { "Scene \($0 + 1)" } ?? "Scene") · \(entry.kind == .direction ? "Direction" : "Dialogue")"
    }
    private var sheetHeight: CGFloat { min(844, max(560, (NSScreen.main?.visibleFrame.height ?? 954) - 110)) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Review character links").font(.system(size: 25, weight: .semibold))
                    Text(sceneDescription).font(.system(size: 18, weight: .medium)).foregroundStyle(ScrivTheme.secondary)
                }
                Spacer()
                IconButton(symbol: "xmark", label: "Close character links review") { dismiss() }
            }.padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(CharacterLinkReviewPresentation.highlightedSource(entry.text, links: links, characters: store.project.characters))
                        .font(.system(size: 20)).lineSpacing(5).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                        .padding(20).background(ScrivTheme.panel, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ScrivTheme.hairline))
                    reviewSections
                    Divider()
                    otherWording
                    CharacterFormNotice(message: "Suggestions are guesses. Confirm only the right character.", prominent: true)
                    if let reviewIssue {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(reviewIssue).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                            if !hasLease && !requiresReopening { Button("Try opening again") { Task { await openReview() } }.disabled(opening) }
                        }
                    }
                    if !choices.isEmpty {
                        Text("Confirm your selected character changes before saving, or choose the original character to leave a link unchanged.")
                            .font(.callout).foregroundStyle(ScrivTheme.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(.horizontal, 28).padding(.bottom, 20)
            }
            Divider()
            HStack(spacing: 15) {
                if opening { ProgressView().controlSize(.small); Text("Opening line…").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(ScrivSecondaryButtonStyle(fontSize: 16))
                Button("Save links", action: save).keyboardShortcut(.defaultAction).buttonStyle(ScrivPrimaryButtonStyle(fontSize: 16))
                    .disabled(!hasLease || !choices.isEmpty)
            }.padding(.horizontal, 28).padding(.vertical, 13)
        }.frame(width: 710, height: sheetHeight).background(ScrivTheme.panel)
            .task { isVisible = true; await openReview() }
            .onDisappear {
                isVisible = false
                if hasLease { store.endEdit(entry.id, context: navigationContext); hasLease = false }
            }
            .onChange(of: store.navigationContext) { _, value in if value != navigationContext { dismiss() } }
    }

    private var reviewSections: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !suggestions.isEmpty {
                Text("Suggested links").font(.system(size: 17, weight: .semibold)).foregroundStyle(ScrivTheme.secondary)
                ForEach(suggestions) { link in linkRow(link) }
            }
            if !confirmed.isEmpty {
                Text("Reviewed links").font(.system(size: 17, weight: .semibold)).foregroundStyle(ScrivTheme.secondary)
                ForEach(confirmed) { link in linkRow(link) }
            }
            if links.isEmpty {
                Text("No character links in this line yet.").font(.system(size: 16)).foregroundStyle(ScrivTheme.secondary)
            }
            Button("Find more name suggestions") {
                links += CharacterMentions.suggestions(in: entry.text, characters: store.project.characters, excluding: links)
                links.sort { $0.location < $1.location }
            }.buttonStyle(.borderless).font(.system(size: 14))
        }.disabled(!hasLease)
    }

    private func linkRow(_ link: CharacterTextLink) -> some View {
        let selectedID = choices[link.id] ?? link.characterId
        let character = selectedID.flatMap { store.project.character($0) }
        return VStack(alignment: .trailing, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("“\(link.text)”").font(.system(size: 18, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    Text(link.isConfirmed ? (link.characterId == nil ? "Kept unlinked" : "Confirmed link") : "Suggested match")
                        .font(.system(size: 15)).foregroundStyle(ScrivTheme.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.right").font(.system(size: 20)).foregroundStyle(ScrivTheme.secondary)
                if let character {
                    CharacterPortrait(character: character).frame(width: 56, height: 58).clipShape(RoundedRectangle(cornerRadius: 9))
                }
                characterMenu(link: link, character: character)
                if !link.isConfirmed || choices[link.id] != nil {
                    Button(link.isConfirmed ? "Correct" : "Confirm") {
                        if let selectedID { assign(link.range, characterId: selectedID) }
                    }.buttonStyle(ScrivPrimaryButtonStyle(fontSize: 16)).disabled(character == nil)
                } else {
                    Image(systemName: link.characterId == nil ? "link.badge.plus" : "checkmark.circle.fill")
                        .font(.system(size: 20)).foregroundStyle(link.characterId == nil ? ScrivTheme.secondary : ScrivTheme.accent)
                        .accessibilityLabel(link.characterId == nil ? "Unlinked" : "Confirmed")
                }
            }
            if link.characterId != nil || choices[link.id] != nil {
                Button(link.isConfirmed ? "Unlink" : "Keep unlinked") { assign(link.range, characterId: nil) }
                    .buttonStyle(ScrivSecondaryButtonStyle(fontSize: 16))
            }
        }.padding(20).background(ScrivTheme.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ScrivTheme.hairline))
    }

    private func characterMenu(link: CharacterTextLink, character: ScriptCharacter?) -> some View {
        Menu {
            ForEach(store.project.characters) { person in
                Button(person.name) {
                    if person.id == link.characterId { choices.removeValue(forKey: link.id) }
                    else { choices[link.id] = person.id }
                }
            }
        } label: {
            HStack(spacing: 9) {
                if let character { Circle().fill(ScrivTheme.color(character.color)).frame(width: 16, height: 16) }
                Text(character?.name ?? (link.characterId == nil ? "Choose character" : "Missing character"))
                    .font(.system(size: 16)).lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .medium)).foregroundStyle(ScrivTheme.secondary)
            }.frame(width: 188, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 12)
                .background(ScrivTheme.panel, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(ScrivTheme.hairline))
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Character for \(link.text)")
            .disabled(store.project.characters.isEmpty)
    }

    private var otherWording: some View {
        DisclosureGroup(isExpanded: $otherWordingExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    CharacterFormLabel(title: "Exact words from this line")
                    TextField("Enter wording to review", text: $phrase).textFieldStyle(.plain).font(.system(size: 18))
                        .modifier(CharacterFormField()).accessibilityLabel("Exact words from this line")
                }
                if !phrase.isEmpty && occurrences.isEmpty {
                    Text("Those exact words are not in this line.").font(.callout).foregroundStyle(ScrivTheme.secondary)
                }
                ForEach(Array(occurrences.enumerated()), id: \.offset) { index, range in occurrenceCard(range, index: index) }
            }.padding(.top, 20).padding(.leading, 12)
        } label: {
            Text("Link other wording").font(.system(size: 17, weight: .semibold))
        }.disabled(!hasLease)
    }

    private func occurrenceCard(_ range: NSRange, index: Int) -> some View {
        let existing = links.first { $0.range == range && $0.isConfirmed }
        return VStack(alignment: .leading, spacing: 10) {
            Text(occurrences.count == 1 ? "Occurrence in scene" : "Occurrence \(index + 1) in scene")
                .font(.system(size: 14)).foregroundStyle(ScrivTheme.secondary)
            Text(CharacterLinkReviewPresentation.highlightedSource(entry.text, focusedRange: range))
                .font(.system(size: 16)).lineSpacing(4).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Text("Choose a character for these words, or keep unlinked.")
                .font(.system(size: 14)).foregroundStyle(ScrivTheme.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Menu {
                    ForEach(store.project.characters) { person in
                        Button("Link to \(person.name)") { assign(range, characterId: person.id) }
                    }
                } label: {
                    Label(existing?.characterId.flatMap { store.project.character($0)?.name } ?? "Choose character", systemImage: "person.crop.circle")
                }.disabled(store.project.characters.isEmpty)
                Spacer()
                if existing?.characterId == nil, existing != nil {
                    Label("Kept unlinked", systemImage: "checkmark").font(.caption).foregroundStyle(ScrivTheme.secondary)
                } else {
                    Button("Keep unlinked") { assign(range, characterId: nil) }.buttonStyle(.borderless)
                }
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(ScrivTheme.inset.opacity(0.8), in: RoundedRectangle(cornerRadius: 9))
    }

    @MainActor private func openReview() async {
        guard isVisible, !opening, !hasLease, !requiresReopening else { return }
        guard store.navigationContext == navigationContext else { dismiss(); return }
        if !ready { links = entry.characterLinks ?? CharacterMentions.suggestions(in: entry.text, characters: store.project.characters) }
        opening = true; reviewIssue = nil
        let allowed = await store.beginEdit(entry.id)
        guard isVisible, !Task.isCancelled, store.navigationContext == navigationContext else {
            if allowed { store.endEdit(entry.id, context: navigationContext) }
            opening = false
            return
        }
        opening = false; ready = true
        guard allowed else {
            reviewIssue = store.errorMessage ?? "This line could not be opened for editing. Try again when it is available."
            return
        }
        guard let current = store.project.entries.first(where: { $0.id == entry.id }),
              current.text.utf16.elementsEqual(entry.text.utf16), current.characterLinks == entry.characterLinks else {
            store.endEdit(entry.id, context: navigationContext)
            requiresReopening = true
            reviewIssue = "This line changed before the review opened. Close this sheet and reopen the review to use its current wording and links."
            return
        }
        hasLease = true
    }

    private func save() {
        guard store.navigationContext == navigationContext else { dismiss(); return }
        guard hasLease, choices.isEmpty else { return }
        if store.saveCharacterLinks(entry.id, expectedText: entry.text, links: links) { dismiss() }
        else { reviewIssue = store.errorMessage ?? "These links could not be saved. Your review is still here." }
    }

    private func assign(_ range: NSRange, characterId: String?) {
        guard hasLease else { return }
        var copy = entry; copy.characterLinks = links
        do {
            try CharacterMentions.assign(&copy, range: range, characterId: characterId, characters: store.project.characters)
            let replacedIDs = Set(links.filter { NSIntersectionRange($0.range, range).length > 0 }.map(\.id))
            choices = choices.filter { !replacedIDs.contains($0.key) }
            links = copy.characterLinks ?? []
            reviewIssue = nil
        } catch { reviewIssue = error.localizedDescription }
    }
}

/// Source offsets remain UTF-16 throughout review, including emoji and repeated
/// wording. Display highlights do not infer identities or modify authored text.
enum CharacterLinkReviewPresentation {
    static func occurrences(of phrase: String, in text: String) -> [NSRange] {
        guard !phrase.isEmpty else { return [] }
        let source = text as NSString
        var found: [NSRange] = [], cursor = 0
        while cursor < source.length {
            let range = source.range(of: phrase, options: .literal, range: NSRange(location: cursor, length: source.length - cursor))
            guard range.location != NSNotFound, range.length > 0 else { break }
            if Range(range, in: text) != nil { found.append(range) }
            cursor = range.location + range.length
        }
        return found
    }

    static func highlightedSource(_ text: String, links: [CharacterTextLink] = [], characters: [ScriptCharacter] = [], focusedRange: NSRange? = nil) -> AttributedString {
        var result = AttributedString(text)
        result.foregroundColor = ScrivTheme.ink
        for link in links where CharacterMentions.matchesSource(link, in: text) {
            guard let character = link.characterId.flatMap({ id in characters.first { $0.id == id } }) else { continue }
            highlight(link.range, in: text, value: &result, color: ScrivTheme.color(character.color).opacity(0.24))
        }
        if let focusedRange { highlight(focusedRange, in: text, value: &result, color: ScrivTheme.accent.opacity(0.22)) }
        return result
    }

    private static func highlight(_ range: NSRange, in text: String, value: inout AttributedString, color: Color) {
        guard let sourceRange = Range(range, in: text),
              let lower = AttributedString.Index(sourceRange.lowerBound, within: value),
              let upper = AttributedString.Index(sourceRange.upperBound, within: value) else { return }
        value[lower..<upper].backgroundColor = color
    }
}
