import Foundation

/// These pure value-only decisions are also executable without UIKit. The
/// application delegates transport/editing and changes zoom through the shared
/// local preference; it never reconstructs script text, IDs or selections.
struct ScrivKeyboardModifiers: OptionSet, Sendable {
    let rawValue: Int
    static let shift = Self(rawValue: 1 << 0)
    static let control = Self(rawValue: 1 << 1)
    static let alternate = Self(rawValue: 1 << 2)
    static let command = Self(rawValue: 1 << 3)
    static let alphaShift = Self(rawValue: 1 << 4)
    static let numericPad = Self(rawValue: 1 << 5)
    static let other = Self(rawValue: 1 << 6)
}

enum ScrivKeyboardAction: Equatable, Sendable { case togglePlayback, zoomIn, zoomOut, toggleScriptEditing }

enum ScrivKeyboardPolicy {
    static func action(characters: String, ignoringModifiers: String, modifiers: ScrivKeyboardModifiers,
                       editingText: Bool, markedText: Bool = false, canToggleScriptEditing: Bool = false) -> ScrivKeyboardAction? {
        // Composition belongs to the input method, including its modifier keys.
        guard !markedText else { return nil }
        if characters == " " || ignoringModifiers == " " {
            return modifiers.isEmpty && !editingText && !markedText ? .togglePlayback : nil
        }
        if modifiers == .command || modifiers == [.command, .shift] {
            if characters == "+" || ignoringModifiers == "+" || ignoringModifiers == "=" || characters == "=" { return .zoomIn }
        }
        if modifiers == .command {
            if characters == "-" || ignoringModifiers == "-" { return .zoomOut }
            if ["\r", "\n", "\u{3}"].contains(characters) || ["\r", "\n", "\u{3}"].contains(ignoringModifiers) {
                return canToggleScriptEditing && !markedText ? .toggleScriptEditing : nil
            }
        }
        return nil
    }
}

/// One command per physical down/up cycle. Remember declined downs too: a held
/// Space that began in a text field must not start playback after focus changes.
struct ScrivKeyboardPressGate {
    private struct Press { let action: ScrivKeyboardAction?; let sequence: UInt64; var fired = false }
    private var down: [Int: Press] = [:]
    private var sequence: UInt64 = 0
    mutating func began(keyCode: Int, action: ScrivKeyboardAction?) {
        guard down[keyCode] == nil else { return }
        sequence &+= 1; down[keyCode] = Press(action: action, sequence: sequence)
    }
    mutating func ended(keyCode: Int) { down.removeValue(forKey: keyCode) }
    mutating func reset() { down.removeAll(); sequence = 0 }
    mutating func consume(_ action: ScrivKeyboardAction) -> Bool {
        guard let key = down.filter({ $0.value.action == action && !$0.value.fired }).min(by: { $0.value.sequence < $1.value.sequence })?.key else { return false }
        down[key]?.fired = true; return true
    }
}

#if canImport(UIKit)
import UIKit

@MainActor
private final class ScrivFirstResponderProbe: NSObject { weak var responder: UIResponder? }

private extension UIResponder {
    @objc func scrivCaptureKeyboardFirstResponder(_ probe: ScrivFirstResponderProbe) { probe.responder = self }
}

@MainActor
enum ScrivKeyboardTextContext {
    struct State: Equatable { var editingText = false; var markedText = false }
    /// nil-target public responder dispatch reaches text fields inside native
    /// alerts, search bars and presented navigation/form controllers as well.
    static func firstResponder(application: UIApplication = .shared) -> UIResponder? {
        let probe = ScrivFirstResponderProbe()
        application.sendAction(#selector(UIResponder.scrivCaptureKeyboardFirstResponder(_:)), to: nil, from: probe, for: nil)
        return probe.responder
    }
    static func state(for responder: UIResponder?) -> State {
        var cursor = responder, visited = Set<ObjectIdentifier>()
        while let current = cursor, visited.insert(ObjectIdentifier(current)).inserted {
            if let input = current as? UITextInput, input.markedTextRange != nil { return State(editingText: true, markedText: true) }
            if let text = current as? UITextView {
                if text.isEditable { return State(editingText: true) }
                // Read-only script/source text can be selected without entering
                // edit mode. Do not classify it by UITextView's protocol alone.
            } else if current is UITextField || current is UITextInput || current is UIKeyInput {
                return State(editingText: true)
            }
            cursor = current.next
        }
        return State()
    }
    static func chainContainsScriptEditor(_ responder: UIResponder?) -> Bool {
        var cursor = responder, visited = Set<ObjectIdentifier>()
        while let current = cursor, visited.insert(ObjectIdentifier(current)).inserted {
            if current is ScriptTextView { return true }
            cursor = current.next
        }
        return false
    }
}

/// UIApplication sits above every modal's responder chain. Its key commands
/// handle global shortcuts without stealing first responder from an editor.
/// Raw events are observed only for the repeat fence, then ALWAYS forwarded.
/// Apple requires super.sendEvent; actual consumption belongs to UIKeyCommand.
/// https://developer.apple.com/documentation/uikit/uiapplication/sendevent(_:)
/// https://developer.apple.com/documentation/uikit/uikeycommand/wantspriorityoversystembehavior
@objc(ScrivUIKitApplication)
@MainActor
final class ScrivUIKitApplication: UIApplication {
    private var pressGate = ScrivKeyboardPressGate()
    private let toggleEditingSelector = NSSelectorFromString("scrivToggleScriptEditing:")
    private var currentStore: WorkspaceStore? { (UIKitPresentation.window?.rootViewController as? ScrivWorkspaceController)?.store }

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(resetKeyboardFence), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resetKeyboardFence), name: UIScene.willDeactivateNotification, object: nil)
    }
    override var keyCommands: [UIKeyCommand]? {
        guard currentStore != nil else { return super.keyCommands }
        let responder = ScrivKeyboardTextContext.firstResponder(application: self)
        let context = ScrivKeyboardTextContext.state(for: responder)
        var commands: [UIKeyCommand] = context.markedText ? [] : [
            command("Increase script text size", input: "=", modifiers: .command, action: #selector(increaseScriptZoom(_:))),
            command("Increase script text size", input: "+", modifiers: .command, action: #selector(increaseScriptZoom(_:))),
            command("Increase script text size", input: "=", modifiers: [.command, .shift], action: #selector(increaseScriptZoom(_:))),
            command("Increase script text size", input: "+", modifiers: [.command, .shift], action: #selector(increaseScriptZoom(_:))),
            command("Decrease script text size", input: "-", modifiers: .command, action: #selector(decreaseScriptZoom(_:)))
        ]
        if !context.editingText && !context.markedText {
            commands.append(command("Play or pause", input: " ", modifiers: [], action: #selector(togglePlaybackFromKeyboard(_:))))
        }
        if scriptEditingTarget(responder: responder, context: context) != nil {
            for input in ["\r", "\n", "\u{3}"] { commands.append(command("Toggle script editing", input: input, modifiers: .command, action: #selector(toggleScriptEditingFromKeyboard(_:)))) }
        }
        return commands + (super.keyCommands ?? [])
    }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(togglePlaybackFromKeyboard(_:)) {
            let context = ScrivKeyboardTextContext.state(for: ScrivKeyboardTextContext.firstResponder(application: self))
            return currentStore != nil && !context.editingText && !context.markedText
        }
        if action == #selector(increaseScriptZoom(_:)) || action == #selector(decreaseScriptZoom(_:)) {
            let context = ScrivKeyboardTextContext.state(for: ScrivKeyboardTextContext.firstResponder(application: self))
            return currentStore != nil && !context.markedText
        }
        if action == #selector(toggleScriptEditingFromKeyboard(_:)) {
            let responder = ScrivKeyboardTextContext.firstResponder(application: self)
            return currentStore != nil && scriptEditingTarget(responder: responder, context: ScrivKeyboardTextContext.state(for: responder)) != nil
        }
        return super.canPerformAction(action, withSender: sender)
    }
    override func sendEvent(_ event: UIEvent) {
        let presses = (event as? UIPressesEvent)?.allPresses ?? []
        if !presses.isEmpty {
            let responder = ScrivKeyboardTextContext.firstResponder(application: self)
            let context = ScrivKeyboardTextContext.state(for: responder)
            let mayToggleEditing = scriptEditingTarget(responder: responder, context: context) != nil
            for press in presses {
                guard let key = press.key, press.phase == .began else { continue }
                let action = currentStore == nil ? nil : ScrivKeyboardPolicy.action(characters: key.characters, ignoringModifiers: key.charactersIgnoringModifiers,
                    modifiers: Self.modifiers(key.modifierFlags), editingText: context.editingText, markedText: context.markedText, canToggleScriptEditing: mayToggleEditing)
                pressGate.began(keyCode: Int(key.keyCode.rawValue), action: action)
            }
        }
        // Never swallow a UIEvent or manufacture/filter its private press set.
        // UIKit routes the eligible priority key command, or normal text input.
        super.sendEvent(event)
        for press in presses where press.phase == .ended || press.phase == .cancelled {
            if let key = press.key { pressGate.ended(keyCode: Int(key.keyCode.rawValue)) }
        }
    }
    @objc private func togglePlaybackFromKeyboard(_ command: UIKeyCommand) {
        guard canPerformAction(#selector(togglePlaybackFromKeyboard(_:)), withSender: command), pressGate.consume(.togglePlayback) else { return }
        currentStore?.togglePlayback()
    }
    @objc private func increaseScriptZoom(_ command: UIKeyCommand) {
        guard canPerformAction(#selector(increaseScriptZoom(_:)), withSender: command), pressGate.consume(.zoomIn) else { return }
        currentStore?.adjustScriptZoom(by: 0.1)
    }
    @objc private func decreaseScriptZoom(_ command: UIKeyCommand) {
        guard canPerformAction(#selector(decreaseScriptZoom(_:)), withSender: command), pressGate.consume(.zoomOut) else { return }
        currentStore?.adjustScriptZoom(by: -0.1)
    }
    @objc private func toggleScriptEditingFromKeyboard(_ command: UIKeyCommand) {
        let responder = ScrivKeyboardTextContext.firstResponder(application: self)
        guard let target = scriptEditingTarget(responder: responder, context: ScrivKeyboardTextContext.state(for: responder)), pressGate.consume(.toggleScriptEditing) else { return }
        sendAction(toggleEditingSelector, to: target, from: command, for: nil)
    }
    @objc private func resetKeyboardFence() { pressGate.reset() }
    private func command(_ title: String, input: String, modifiers: UIKeyModifierFlags, action: Selector) -> UIKeyCommand {
        let value = UIKeyCommand(title: title, action: action, input: input, modifierFlags: modifiers)
        value.wantsPriorityOverSystemBehavior = true
        // Native prevention on current systems plus the down/up fence above for
        // deployment 17 and duplicate delivery across keyboard aliases.
        // https://developer.apple.com/videos/play/wwdc2025/243/?time=421
        if #available(iOS 26.0, macCatalyst 26.0, *) { value.repeatBehavior = .nonRepeatable }
        return value
    }
    private func scriptEditingTarget(responder: UIResponder?, context: ScrivKeyboardTextContext.State) -> Any? {
        // A workspace script may still be first responder underneath a sheet.
        // Never begin or finish that obscured editor from a modal's shortcut.
        guard !context.markedText, let root = UIKitPresentation.window?.rootViewController,
              root.presentedViewController == nil else { return nil }
        // Cmd-Enter may finish a script editor, never an auth/search/comment or
        // numeric field. Those controls retain their own native return behavior.
        if context.editingText && !ScrivKeyboardTextContext.chainContainsScriptEditor(responder) { return nil }
        if let target = responder?.target(forAction: toggleEditingSelector, withSender: self) { return target }
        guard !context.editingText else { return nil }
        return visibleScript(in: root)
    }
    private func visibleScript(in controller: UIViewController) -> ScriptScreenController? {
        guard controller.isViewLoaded, controller.view.window != nil, !controller.view.isHidden else { return nil }
        if let script = controller as? ScriptScreenController, script.canPerformAction(toggleEditingSelector, withSender: self) { return script }
        for child in controller.children { if let script = visibleScript(in: child) { return script } }
        return nil
    }
    private static func modifiers(_ flags: UIKeyModifierFlags) -> ScrivKeyboardModifiers {
        var result: ScrivKeyboardModifiers = []
        for (native, logical) in [(UIKeyModifierFlags.shift, ScrivKeyboardModifiers.shift), (.control, .control), (.alternate, .alternate), (.command, .command), (.alphaShift, .alphaShift), (.numericPad, .numericPad)] {
            if flags.contains(native) { result.insert(logical) }
        }
        let known: UIKeyModifierFlags = [.shift, .control, .alternate, .command, .alphaShift, .numericPad]
        if !flags.subtracting(known).isEmpty { result.insert(.other) }
        return result
    }
}
#endif
