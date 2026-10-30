import XCTest
@testable import ScrivUIKit

final class ScrivPlaybackKeyboardPolicyTests: XCTestCase {
    func testOnlyUnmodifiedSpaceOutsideTextStartsPlayback() {
        XCTAssertEqual(action(" "), .togglePlayback)
        for modifier: ScrivKeyboardModifiers in [.shift, .control, .alternate, .command, .alphaShift, .numericPad, .other] {
            XCTAssertNil(action(" ", modifiers: modifier))
        }
        XCTAssertNil(action(" ", modifiers: [.command, .shift]))
        XCTAssertNil(action(" ", editing: true))
        XCTAssertNil(action(" ", marked: true))
        XCTAssertNil(action(" ", editing: true, marked: true))
    }
    func testUnrelatedKeysNeverBecomePlaybackCommands() {
        for value in ["", "a", "\t", "\r", "\n", "\u{3}", "\u{1b}", "🙂", "　"] {
            XCTAssertNil(action(value), value)
        }
    }
    func testZoomAcceptsPlusEqualsAndShiftedKeyboardVariantsWhileEditing() {
        for editing in [false, true] {
            for modifiers: ScrivKeyboardModifiers in [.command, [.command, .shift]] {
                for value in ["+", "="] {
                    XCTAssertEqual(action(value, modifiers: modifiers, editing: editing), .zoomIn)
                }
            }
            XCTAssertEqual(ScrivKeyboardPolicy.action(characters: "+", ignoringModifiers: "=", modifiers: [.command, .shift], editingText: editing), .zoomIn)
            XCTAssertEqual(action("-", modifiers: .command, editing: editing), .zoomOut)
        }
    }
    func testZoomRejectsPlainKeysAndOtherModifierCombinations() {
        for value in ["+", "=", "-"] {
            for modifiers: ScrivKeyboardModifiers in [[], .shift, .alternate, .control, [.command, .alternate], [.command, .control], [.command, .other]] {
                XCTAssertNil(action(value, modifiers: modifiers))
            }
        }
        XCTAssertNil(action("-", modifiers: [.command, .shift]))
    }
    func testCompositionRetainsAllShortcutKeys() {
        for value in [" ", "+", "=", "-", "\r", "\n", "\u{3}"] {
            for modifiers: ScrivKeyboardModifiers in [[], .command, [.command, .shift]] {
                XCTAssertNil(action(value, modifiers: modifiers, editing: true, marked: true, script: true))
            }
        }
    }
    func testCommandEnterRequiresEligibleScriptAndNeverClaimsPlainReturn() {
        for value in ["\r", "\n", "\u{3}"] {
            XCTAssertEqual(action(value, modifiers: .command, script: true), .toggleScriptEditing)
            XCTAssertEqual(action(value, modifiers: .command, editing: true, script: true), .toggleScriptEditing)
            XCTAssertNil(action(value, modifiers: .command))
            XCTAssertNil(action(value, modifiers: .command, editing: true))
            XCTAssertNil(action(value, script: true))
            XCTAssertNil(action(value, modifiers: [.command, .shift], script: true))
            XCTAssertNil(action(value, modifiers: [.command, .alternate], script: true))
        }
    }
    func testRepeatAndDuplicateCommandDeliveryToggleOnlyOncePerPress() {
        var gate = ScrivKeyboardPressGate()
        gate.began(keyCode: 44, action: .togglePlayback)
        XCTAssertTrue(gate.consume(.togglePlayback))
        for _ in 0..<100 {
            gate.began(keyCode: 44, action: .togglePlayback)
            XCTAssertFalse(gate.consume(.togglePlayback))
        }
        gate.ended(keyCode: 44)
        XCTAssertFalse(gate.consume(.togglePlayback))
        gate.began(keyCode: 44, action: .togglePlayback)
        XCTAssertTrue(gate.consume(.togglePlayback))
    }
    func testHeldSpaceThatStartedInTextCannotActivateAfterFocusMoves() {
        var gate = ScrivKeyboardPressGate()
        gate.began(keyCode: 44, action: action(" ", editing: true))
        gate.began(keyCode: 44, action: action(" "))
        XCTAssertFalse(gate.consume(.togglePlayback))
        gate.ended(keyCode: 44)
        gate.began(keyCode: 44, action: action(" "))
        XCTAssertTrue(gate.consume(.togglePlayback))
    }
    func testHeldModifiedSpaceCannotActivateWhenModifierIsReleasedFirst() {
        var gate = ScrivKeyboardPressGate()
        gate.began(keyCode: 44, action: action(" ", modifiers: .alternate))
        gate.began(keyCode: 44, action: action(" "))
        XCTAssertFalse(gate.consume(.togglePlayback))
        gate.ended(keyCode: 44)
        gate.began(keyCode: 44, action: action(" "))
        XCTAssertTrue(gate.consume(.togglePlayback))
    }
    func testCompositionStartCannotBeReclassifiedDuringHeldZoomPress() {
        var gate = ScrivKeyboardPressGate()
        gate.began(keyCode: 46, action: action("=", modifiers: .command, editing: true, marked: true))
        gate.began(keyCode: 46, action: action("=", modifiers: .command, editing: true))
        XCTAssertFalse(gate.consume(.zoomIn))
    }
    func testResetAndCancellationReleaseFenceWithoutFiringAnything() {
        var gate = ScrivKeyboardPressGate()
        gate.began(keyCode: 44, action: .togglePlayback)
        gate.ended(keyCode: 44) // ended and cancelled physical presses use this path
        XCTAssertFalse(gate.consume(.togglePlayback))
        gate.began(keyCode: 44, action: .togglePlayback)
        gate.reset()
        XCTAssertFalse(gate.consume(.togglePlayback))
        gate.began(keyCode: 44, action: .togglePlayback)
        XCTAssertTrue(gate.consume(.togglePlayback))
    }
    func testDifferentPhysicalKeysAndActionsDoNotClearEachOthersFence() {
        var gate = ScrivKeyboardPressGate()
        gate.began(keyCode: 46, action: .zoomIn)
        gate.began(keyCode: 87, action: .zoomIn)
        gate.began(keyCode: 45, action: .zoomOut)
        gate.began(keyCode: 40, action: .toggleScriptEditing)
        XCTAssertFalse(gate.consume(.togglePlayback))
        XCTAssertTrue(gate.consume(.zoomIn)); XCTAssertTrue(gate.consume(.zoomIn))
        XCTAssertFalse(gate.consume(.zoomIn))
        gate.ended(keyCode: 46)
        XCTAssertTrue(gate.consume(.zoomOut)); XCTAssertTrue(gate.consume(.toggleScriptEditing))
        XCTAssertFalse(gate.consume(.toggleScriptEditing))
        XCTAssertFalse(gate.consume(.zoomOut))
    }
    func testACommandWithoutAnObservedPhysicalDownCannotToggle() {
        var gate = ScrivKeyboardPressGate()
        for action: ScrivKeyboardAction in [.togglePlayback, .zoomIn, .zoomOut, .toggleScriptEditing] {
            XCTAssertFalse(gate.consume(action))
        }
    }
    private func action(_ characters: String, modifiers: ScrivKeyboardModifiers = [], editing: Bool = false,
                        marked: Bool = false, script: Bool = false) -> ScrivKeyboardAction? {
        ScrivKeyboardPolicy.action(characters: characters, ignoringModifiers: characters, modifiers: modifiers,
            editingText: editing, markedText: marked, canToggleScriptEditing: script)
    }
}
