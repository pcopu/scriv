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
    func testFieldsSearchAuthAndNumericInputRemainTextContexts() async {
        let ordinary = UITextField(), numeric = UITextField()
        numeric.keyboardType = .decimalPad
        let search = UISearchBar()
        for (name, field) in [("ordinary", ordinary), ("numeric", numeric), ("search", search.searchTextField)] {
            let container: UIView = field === search.searchTextField ? search : field
            await withWindow(containing: container) { _ in
                XCTAssertTrue(field.becomeFirstResponder(), name)
                self.assertTypingContext(name)
                field.text = "before"
                self.placeCaretAtEnd(field, expectedOffset: 6, name: name)
                field.insertText(" ")
                XCTAssertEqual(field.text, "before ", name)
                XCTAssertEqual(field.selectedTextRange.map { field.offset(from: field.beginningOfDocument, to: $0.start) }, 7, name)
            }
        }
    }
    func testSecureFieldKeepsNormallyTypedSpacesWithoutPlaybackInterception() async {
        let field = UITextField(); field.isSecureTextEntry = true
        await withWindow(containing: field) { _ in
            XCTAssertTrue(field.becomeFirstResponder())
            self.assertTypingContext("secure")
            // Native secure fields may replace programmatically prefilled text
            // on their first insertion. Type the prefix through UIKeyInput so
            // this test measures continuing input, not secure-prefill policy.
            field.insertText("before")
            XCTAssertEqual(field.text, "before")
            self.placeCaretAtEnd(field, expectedOffset: 6, name: "secure")
            field.insertText(" ")
            XCTAssertEqual(field.text, "before ")
            XCTAssertEqual(field.selectedTextRange.map { field.offset(from: field.beginningOfDocument, to: $0.start) }, 7)
        }
    }
    func testEditableTextViewKeepsSpacesAndNativeUTF16Selection() async {
        let view = UITextView()
        await withWindow(containing: view) { _ in
            XCTAssertTrue(view.becomeFirstResponder())
            view.text = "🙂words"; view.selectedRange = NSRange(location: 2, length: 0)
            XCTAssertTrue(ScrivKeyboardTextContext.state(for: ScrivKeyboardTextContext.firstResponder()).editingText)
            view.insertText(" ")
            XCTAssertEqual(view.text, "🙂 words")
            XCTAssertEqual(view.selectedRange, NSRange(location: 3, length: 0))
        }
    }
    func testInputMethodCompositionBlocksShortcuts() async {
        let view = UITextView()
        await withWindow(containing: view) { _ in
            XCTAssertTrue(view.becomeFirstResponder())
            view.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0))
            XCTAssertNotNil(view.markedTextRange)
            XCTAssertEqual(ScrivKeyboardTextContext.state(for: ScrivKeyboardTextContext.firstResponder()), .init(editingText: true, markedText: true))
            view.unmarkText()
            XCTAssertEqual(ScrivKeyboardTextContext.state(for: view), .init(editingText: true, markedText: false))
        }
    }
    func testScriptMarkedTextNeverTriggersBoundaryMergeOrPlayback() async {
        let view = ScriptTextView(); view.setScriptStyle(size: 20, direction: false)
        var merged = 0; view.mergeAtStart = { merged += 1 }
        await withWindow(containing: view) { _ in
            XCTAssertTrue(view.becomeFirstResponder())
            view.setMarkedText("かな", selectedRange: NSRange(location: 0, length: 0))
            XCTAssertNotNil(view.markedTextRange)
            XCTAssertEqual(ScrivKeyboardTextContext.state(for: ScrivKeyboardTextContext.firstResponder()), .init(editingText: true, markedText: true))
            self.assertTypingContext("script composition")
            view.deleteBackward()
            XCTAssertEqual(merged, 0, "The input method, not line-boundary editing, owns composition deletion")
            view.unmarkText()
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
    func testFirstResponderProbeWorksThroughPresentedNavigationController() async {
        await withWindow(containing: UIView()) { root in
            let modal = UIViewController(), field = UITextField()
            modal.view.addSubview(field); field.frame = CGRect(x: 30, y: 30, width: 250, height: 50)
            field.text = "modal"
            let navigation = UINavigationController(rootViewController: modal)
            navigation.modalPresentationStyle = .fullScreen
            let appeared = self.expectation(description: "Presented navigation controller finished appearing")
            root.present(navigation, animated: false) { appeared.fulfill() }
            await self.fulfillment(of: [appeared], timeout: 5)
            defer { root.dismiss(animated: false) }
            // animated:false does not make presentation completion synchronous.
            // A detached view cannot successfully become first responder.
            XCTAssertNotNil(field.window)
            guard let window = field.window, await self.waitForKeyWindow(window) else { return }
            XCTAssertTrue(field.becomeFirstResponder())
            self.assertTypingContext("presented navigation field")
            self.placeCaretAtEnd(field, expectedOffset: 5, name: "presented navigation field")
            field.insertText(" ")
            XCTAssertEqual(field.text, "modal ")
            XCTAssertEqual(field.selectedTextRange.map { field.offset(from: field.beginningOfDocument, to: $0.start) }, 6)
        }
    }
    private func assertTypingContext(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let context = ScrivKeyboardTextContext.state(for: ScrivKeyboardTextContext.firstResponder())
        XCTAssertTrue(context.editingText, name, file: file, line: line)
        XCTAssertFalse(UIApplication.shared.canPerformAction(NSSelectorFromString("togglePlaybackFromKeyboard:"), withSender: nil), "Space must not be a playback action in \(name)", file: file, line: line)
    }
    private func placeCaretAtEnd(_ field: UITextField, expectedOffset: Int, name: String, file: StaticString = #filePath, line: UInt = #line) {
        field.selectedTextRange = field.textRange(from: field.endOfDocument, to: field.endOfDocument)
        XCTAssertNotNil(field.selectedTextRange, name, file: file, line: line)
        XCTAssertEqual(field.selectedTextRange.map { field.offset(from: field.beginningOfDocument, to: $0.start) }, expectedOffset, name, file: file, line: line)
        XCTAssertTrue(field.selectedTextRange?.isEmpty == true, name, file: file, line: line)
    }
    private func withWindow(containing content: UIView, body: (UIViewController) async -> Void) async {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let previous = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
        let window: UIWindow
        if let scene = previous?.windowScene ?? scenes.first { window = UIWindow(windowScene: scene) }
        else { window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600)) }
        let controller = KeyboardTestHostController()
        let appeared = expectation(description: "Keyboard fixture window finished appearing")
        controller.didAppear = { appeared.fulfill() }
        window.rootViewController = controller
        controller.view.addSubview(content); content.frame = CGRect(x: 20, y: 20, width: 500, height: 200)
        window.makeKeyAndVisible(); controller.view.layoutIfNeeded()
        defer { window.endEditing(true); window.isHidden = true; previous?.makeKey() }
        await fulfillment(of: [appeared], timeout: 5)
        controller.didAppear = nil
        guard await waitForKeyWindow(window) else { return }
        XCTAssertNotNil(content.window)
        await body(controller)
    }
    private func waitForKeyWindow(_ window: UIWindow, file: StaticString = #filePath, line: UInt = #line) async -> Bool {
        // Appearing and becoming key are separate on Catalyst. Another fixture
        // or an app activation can change focus while presentation completes.
        window.makeKey()
        let deadline = Date().addingTimeInterval(5)
        while !window.isKeyWindow, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard window.isKeyWindow else {
            XCTFail("Keyboard fixture could not become key; responder assertions require key focus", file: file, line: line)
            return false
        }
        return true
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

@MainActor
private final class KeyboardTestHostController: UIViewController {
    var didAppear: (() -> Void)?
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let completion = didAppear; didAppear = nil; completion?()
    }
}
