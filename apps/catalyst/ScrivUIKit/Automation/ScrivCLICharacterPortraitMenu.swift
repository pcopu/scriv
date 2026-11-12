#if SCRIV_CLI_AUTOMATION
import UIKit
import ScrivCore

/// Only the selected Characters profile's existing tagged-image portrait actions.
/// Menu observation is not native menu input; dispatch never rebuilds a menu,
/// extracts a handler, invokes a selector, or writes the model directly.
@MainActor
enum ScrivCLICharacterPortraitMenu {
    private struct Failure: LocalizedError {
        var errorDescription: String? { "Character portrait action is outside the supported isolated scope" }
    }
    private static let scope = "character-portrait-options"

    static func canHandle(_ request: [String: Any]) -> Bool {
        request["scope"] as? String == scope
    }

    static func dispatch(view: UIView, window: UIWindow, windows: [UIWindow],
                         request: [String: Any]) throws -> [String: Any] {
        guard Set(request.keys) == Set(["id", "command", "target", "action", "scope", "characterID", "imageID"]),
              request["command"] as? String == "menu-action", canHandle(request),
              request["target"] as? String == scope,
              let title = request["action"] as? String,
              let characterID = request["characterID"] as? String, !characterID.isEmpty,
              let imageID = request["imageID"] as? String, !imageID.isEmpty,
              let button = view as? UIButton,
              let workspace = window.rootViewController as? ScrivWorkspaceController,
              let originalMenu = button.menu else { throw Failure() }
        // The nearest controller must own the actual control. A matching title
        // in an inspector, review sheet, or another character cannot authorize it.
        var responder: UIResponder? = button
        var characters: CharactersController?
        for _ in 0..<64 {
            guard let current = responder else { break }
            if let controller = current as? UIViewController {
                characters = controller as? CharactersController
                break
            }
            responder = current.next
        }
        guard let characters else { throw Failure() }
        let store = workspace.store, project = store.project, navigation = store.navigationContext
        guard let character = project.character(characterID),
              let requestedImage = project.asset(imageID),
              Set(project.characters.map(\.id)).count == project.characters.count,
              Set(project.images.map(\.id)).count == project.images.count else { throw Failure() }
        let tagged = project.images.filter { $0.characterIds.contains(characterID) }
        let choiceTitles = tagged.map { "Use \(UIKitImageContext.title(imageID: $0.id, project: project)) · v\($0.version)" }
        let removing = title == "Remove portrait"
        guard !tagged.isEmpty, tagged.contains(requestedImage),
              Set(choiceTitles).count == choiceTitles.count,
              !choiceTitles.contains("Remove portrait"),
              tagged.allSatisfy({ Set($0.characterIds).count == $0.characterIds.count }),
              character.portraitImageId == nil || tagged.contains(where: { $0.id == character.portraitImageId }),
              let requestedIndex = tagged.firstIndex(where: { $0.id == imageID }),
              (removing ? character.portraitImageId == imageID : title == choiceTitles[requestedIndex])
        else { throw Failure() }
        // imageID means the requested tagged image for Use, and the expected
        // current stored portrait pointer for Remove. Removal never accepts nil.
        let sourceURLs = tagged.map { store.assetURL($0) }
        guard sourceURLs.allSatisfy({ $0 != nil }) else { throw Failure() }
        let originalSections = originalMenu.children.compactMap { $0 as? UIMenu }

        func descendants(_ root: UIView) -> [UIView] {
            var result = [root]
            for child in root.subviews { result.append(contentsOf: descendants(child)) }
            return result
        }
        func validate() throws -> [UIAction] {
            guard window.rootViewController === workspace,
                  workspace.viewIfLoaded?.window === window,
                  windows.contains(where: { $0 === window }),
                  !window.isHidden, window.alpha > 0.01,
                  workspace.presentedViewController == nil,
                  workspace.presentingViewController == nil,
                  !workspace.isBeingPresented, !workspace.isBeingDismissed,
                  workspace.transitionCoordinator == nil,
                  store.project == project, store.navigationContext == navigation,
                  store.tab == .characters, store.selectedCharacterID == characterID,
                  !store.showDiscussion, !store.showAccountSignIn,
                  store.account == nil, store.cloud.account == nil,
                  store.project.cloudProjectId == nil, store.cloud.projectId == nil,
                  store.errorMessage == nil, !store.isPlaying, !store.isBootstrapping,
                  !store.isSyncing, !store.hasConflicts, !store.codex.isGenerating,
                  store.codex.jobs.isEmpty, store.codex.sharedJobs.isEmpty,
                  !store.characterAnalysis.isScanning,
                  store.characterAnalysis.availability == "Image analysis is disabled in verification mode.",
                  store.requestedEntryEditingID == nil, store.characterCreationRequest == nil,
                  store.lockedByOther(characterID) == nil,
                  characters.parent === workspace, characters.store === store,
                  characters.contextIsCurrent, !characters.scopeToProject,
                  characters.presentedViewController == nil, characters.presentingViewController == nil,
                  !characters.isBeingPresented, !characters.isBeingDismissed,
                  characters.transitionCoordinator == nil,
                  workspace.children.count == 2,
                  workspace.children.filter({ $0 === characters }).count == 1,
                  let script = workspace.children.first(where: { $0 is ScriptScreenController }) as? ScriptScreenController,
                  script.parent === workspace, script.store === store, script.contextIsCurrent,
                  script.cliAllowsCatalogMutation(),
                  script.presentedViewController == nil, script.presentingViewController == nil,
                  !script.isBeingPresented, !script.isBeingDismissed, script.transitionCoordinator == nil,
                  let workspaceView = workspace.viewIfLoaded,
                  let content = characters.viewIfLoaded, let scriptView = script.viewIfLoaded,
                  content.window === window, scriptView.window === window,
                  content.isDescendant(of: workspaceView), scriptView.isDescendant(of: workspaceView),
                  button.window === window, button.isDescendant(of: content),
                  button.isEnabled, button.showsMenuAsPrimaryAction,
                  button.accessibilityIdentifier == scope, button.accessibilityLabel == "Portrait options",
                  (button.configuration?.title ?? button.currentTitle) == "Portrait options",
                  ScrivSecondaryMenu.menu(of: button) == nil,
                  button.menu === originalMenu, originalMenu.title.isEmpty, originalMenu.options.isEmpty,
                  tagged.enumerated().allSatisfy({ store.assetURL($0.element) == sourceURLs[$0.offset] })
            else { throw Failure() }
            // Reject another app surface or editing responder, including hidden
            // descendants. No finishing, committing, or discarding someone else's draft.
            let allViews = windows.flatMap { descendants($0) }
            guard !allViews.contains(where: { $0.isFirstResponder }),
                  allViews.filter({ $0.accessibilityIdentifier == scope }).count == 1,
                  !allViews.contains(where: { view in
                      guard let text = view as? ScriptTextView else { return false }
                      return text.isEditable && !text.isHidden
                  }),
                  windows.allSatisfy({ candidate in
                      guard let root = candidate.rootViewController as? ScrivScreenController,
                            root.store === store else { return true }
                      return candidate === window && root === workspace
                  }) else { throw Failure() }
            var ancestor: UIView? = button
            while let current = ancestor {
                guard !current.isHidden, current.alpha > 0.01, current.isUserInteractionEnabled else { throw Failure() }
                ancestor = current.superview
            }
            // The normal empty-search ribbon and the exact profile hierarchy
            // witness which character was rendered, without accessing private
            // snapshots or reconstructing production menus and captured handlers.
            let contentViews = descendants(content)
            let searches = contentViews.compactMap { $0 as? UISearchBar }
            let cards = contentViews.compactMap { $0 as? UIButton }
                .filter { $0.accessibilityIdentifier?.hasPrefix("character-ribbon-") == true }
            guard searches.count == 1, (searches.first?.text ?? "").isEmpty,
                  cards.count == project.characters.count,
                  cards.enumerated().allSatisfy({ index, card in
                      let person = project.characters[index]
                      return card.accessibilityIdentifier == "character-ribbon-" + person.id &&
                          card.accessibilityLabel == person.name &&
                          card.accessibilityTraits == (person.id == characterID ? [.button, .selected] : [.button])
                  }),
                  let details = button.superview as? UIStackView, details.arrangedSubviews.count == 5,
                  details.arrangedSubviews[4] === button,
                  let heading = details.arrangedSubviews[0] as? UIStackView,
                  heading.arrangedSubviews.count == 4,
                  (heading.arrangedSubviews[0] as? UILabel)?.text == character.name,
                  let source = details.arrangedSubviews[1] as? UILabel,
                  let header = details.superview as? UIStackView, header.arrangedSubviews.count == 2,
                  header.arrangedSubviews[1] === details,
                  header.arrangedSubviews[0].accessibilityLabel == "Portrait of \(character.name.isEmpty ? "new character" : character.name)"
            else { throw Failure() }
            let portraitAsset = project.asset(character.portraitImageId)
            let portraitCue = project.cues.first { $0.imageId == portraitAsset?.id }
            let portraitName = portraitCue.flatMap { $0.label.isEmpty ? nil : $0.label } ?? "image"
            let portraitSource = portraitAsset.map {
                "Portrait \(character.portraitRegion != nil ? "cropped from" : "from") \(portraitName) · v\($0.version)"
            } ?? "No portrait yet"
            guard source.text == portraitSource else { throw Failure() }

            // Exactly the current production sections, order, titles, checkmarks
            // and attributes. No placeholder, provider, command, or extra action.
            let sectionCount = character.portraitImageId == nil ? 1 : 2
            let sections = originalMenu.children.compactMap { $0 as? UIMenu }
            guard originalMenu.children.count == sectionCount, sections.count == sectionCount,
                  originalSections.count == sections.count,
                  zip(originalSections, sections).allSatisfy({ $0 === $1 }),
                  sections.allSatisfy({ $0.title.isEmpty && $0.options == .displayInline }) else { throw Failure() }
            let choices = sections[0].children.compactMap { $0 as? UIAction }
            guard sections[0].children.count == tagged.count, choices.count == tagged.count,
                  choices.map(\.title) == choiceTitles,
                  choices.enumerated().allSatisfy({ index, action in
                      action.attributes.isEmpty &&
                          action.state == (tagged[index].id == character.portraitImageId ? .on : .off)
                  }) else { throw Failure() }
            var actions = choices
            if sectionCount == 2 {
                guard sections[1].children.count == 1,
                      let remove = sections[1].children.first as? UIAction,
                      remove.title == "Remove portrait", remove.attributes == [.destructive], remove.state == .off
                else { throw Failure() }
                actions.append(remove)
            }
            return actions
        }
        let run = try ScrivCLIRunCapability.requirePrepared()
        guard run.approvedOrigin == nil else { throw Failure() }
        let originalActions = try validate()
        // These existing read-only observers prove the owned local package and
        // exact allowlisted synthetic PNG bytes. Do not widen either observer.
        _ = try ScrivCLILoadedProject.observe(workspace: workspace)
        _ = try ScrivCLILocalImageEvidence.observe(workspace: workspace, windows: windows)
        try run.validate()
        let currentActions = try validate()
        guard originalActions.count == currentActions.count,
              zip(originalActions, currentActions).allSatisfy({ $0 === $1 }) else { throw Failure() }
        let action = originalActions[removing ? tagged.count : requestedIndex]
        guard action.title == title else { throw Failure() }
        // One public dispatch on its original owning UIButton. Selecting the
        // current image deliberately reaches production's no-op guard. Removing
        // its stored pointer does not suppress the UI's tagged-image fallback.
        button.sendAction(action)
        return ["dispatched": true, "coverage": "semantic-menu-action"]
    }
}
#endif
