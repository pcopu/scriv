import XCTest
import UIKit
@testable import ScrivUIKit

/// These exercise actual native responders. Physical held-key delivery through
/// UIApplication/UIKeyCommand still requires the Catalyst keyboard acceptance
/// pass; programmatic insertText is not claimed as that event-routing proof.
@MainActor
final class ScrivPlaybackKeyboardResponderTests: XCTestCase {
    func testHostedAppUsesGlobalKeyboardApplication() {
        XCTAssertTrue(UIApplication.shared is ScrivUIKitApplication)
    }
    func testFieldsSearchAuthAndNumericInputRemainTextContexts() {
        let ordinary = UITextField(), secure = UITextField(), numeric = UITextField()
        secure.isSecureTextEntry = true; numeric.keyboardType = .decimalPad
        let search = UISearchBar()
        for field in [ordinary, secure, numeric, search.searchTextField] {
            let container: UIView = field === search.searchTextField ? search : field
            withWindow(containing: container) { _ in
                XCTAssertTrue(field.becomeFirstResponder())
                XCTAssertTrue(ScrivKeyboardTextContext.state(for: ScrivKeyboardTextContext.firstResponder()).editingText)
                field.text = "before"
                field.selectedTextRange = field.textRange(from: field.endOfDocument, to: field.endOfDocument)
                field.insertText(" ")
                XCTAssertEqual(field.text, "before ")
                XCTAssertEqual(field.selectedTextRange.map { field.offset(from: field.beginningOfDocument, to: $0.start) }, 7)
            }
        }
    }
    func testEditableTextViewKeepsSpacesAndNativeUTF16Selection() {
        let view = UITextView()
        withWindow(containing: view) { _ in
            XCTAssertTrue(view.becomeFirstResponder())
            view.text = "🙂words"; view.selectedRange = NSRange(location: 2, length: 0)
            XCTAssertTrue(ScrivKeyboardTextContext.state(for: ScrivKeyboardTextContext.firstResponder()).editingText)
            view.insertText(" ")
            XCTAssertEqual(view.text, "🙂 words")
            XCTAssertEqual(view.selectedRange, NSRange(location: 3, length: 0))
        }
    }
    func testInputMethodCompositionBlocksShortcuts() {
        let view = UITextView()
        withWindow(containing: view) { _ in
            XCTAssertTrue(view.becomeFirstResponder())
            view.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0))
            XCTAssertNotNil(view.markedTextRange)
            XCTAssertEqual(ScrivKeyboardTextContext.state(for: ScrivKeyboardTextContext.firstResponder()), .init(editingText: true, markedText: true))
            view.unmarkText()
            XCTAssertEqual(ScrivKeyboardTextContext.state(for: view), .init(editingText: true, markedText: false))
        }
    }
    func testReadOnlyScriptSelectionIsNotAnEditSession() {
        let view = UITextView(); view.isEditable = false; view.isSelectable = true
        view.text = "Selected script text"; view.selectedRange = NSRange(location: 0, length: 8)
        XCTAssertEqual(ScrivKeyboardTextContext.state(for: view), .init())
        XCTAssertEqual(view.selectedRange, NSRange(location: 0, length: 8))
    }
    func testCustomKeyInputAndResponderWrappersAreProtected() {
        let input = KeyboardTestInput(), field = UITextField()
        XCTAssertTrue(ScrivKeyboardTextContext.state(for: input).editingText)
        XCTAssertTrue(ScrivKeyboardTextContext.state(for: KeyboardTestResponder(next: field)).editingText)
        XCTAssertFalse(ScrivKeyboardTextContext.state(for: UIButton()).editingText)
        XCTAssertFalse(ScrivKeyboardTextContext.state(for: UIViewController()).editingText)
        XCTAssertFalse(ScrivKeyboardTextContext.state(for: nil).editingText)
    }
    func testScriptCommandEligibilityDoesNotMistakeAnotherTextInputForScript() {
        let script = ScriptTextView(), field = UITextField(), plain = UITextView()
        XCTAssertTrue(ScrivKeyboardTextContext.chainContainsScriptEditor(script))
        XCTAssertTrue(ScrivKeyboardTextContext.chainContainsScriptEditor(KeyboardTestResponder(next: script)))
        XCTAssertFalse(ScrivKeyboardTextContext.chainContainsScriptEditor(field))
        XCTAssertFalse(ScrivKeyboardTextContext.chainContainsScriptEditor(plain))
    }
    func testFirstResponderProbeWorksThroughPresentedNavigationController() {
        withWindow(containing: UIView()) { root in
            let modal = UIViewController(), field = UITextField()
            modal.view.addSubview(field); field.frame = CGRect(x: 30, y: 30, width: 250, height: 50)
            let navigation = UINavigationController(rootViewController: modal)
            navigation.modalPresentationStyle = .fullScreen
            root.present(navigation, animated: false)
            defer { root.dismiss(animated: false) }
            XCTAssertTrue(field.becomeFirstResponder())
            XCTAssertTrue(ScrivKeyboardTextContext.state(for: ScrivKeyboardTextContext.firstResponder()).editingText)
            field.text = "modal"; field.insertText(" ")
            XCTAssertEqual(field.text, "modal ")
        }
    }
    private func withWindow(containing content: UIView, body: (UIViewController) -> Void) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let previous = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
        let window: UIWindow
        if let scene = previous?.windowScene ?? scenes.first { window = UIWindow(windowScene: scene) }
        else { window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600)) }
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(content); content.frame = CGRect(x: 20, y: 20, width: 500, height: 200)
        window.makeKeyAndVisible(); controller.view.layoutIfNeeded()
        defer { window.endEditing(true); window.isHidden = true; previous?.makeKey() }
        body(controller)
    }
}

@MainActor
private final class KeyboardTestResponder: UIResponder {
    private let following: UIResponder
    init(next: UIResponder) { following = next; super.init() }
    override var next: UIResponder? { following }
}

@MainActor
private final class KeyboardTestInput: UIView, UIKeyInput {
    var hasText = false
    override var canBecomeFirstResponder: Bool { true }
    func insertText(_ text: String) { hasText = !text.isEmpty }
    func deleteBackward() { hasText = false }
}
