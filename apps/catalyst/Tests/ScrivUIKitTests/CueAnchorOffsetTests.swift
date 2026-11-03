import XCTest
import UIKit
import ScrivCore
@testable import ScrivUIKit

/// Real UIKit control events in isolated storage. These are not OS mouse/keyboard
/// tests; native compilation and execution are required for a behavioral pass.
@MainActor final class CueAnchorOffsetTests: XCTestCase {
    func testTypedOffsetBecomesTheBaseForRepeatedStepperChanges() async throws {
        try await withFixture { store, _, field, stepper in
            let original = store.project
            XCTAssertEqual(stepper.value, 0.125, accuracy: 0.000_001)
            field.text = "0.750"; field.sendActions(for: .editingChanged)
            XCTAssertEqual(stepper.value, 0.750, accuracy: 0.000_001,
                           "Typing must update the stepper without waiting for a store publish")
            for (delta, expected) in [(1.0, "0.751"), (1.0, "0.752"), (-1.0, "0.751")] {
                stepper.value += delta * stepper.stepValue
                stepper.sendActions(for: .valueChanged)
                XCTAssertEqual(field.text, expected)
            }
            XCTAssertEqual(store.project, original, "Draft controls must not save or retime the project")
        }
    }

    func testInvalidAndNonfiniteDraftsDoNotReplaceTheTextOrPoisonTheStepper() async throws {
        try await withFixture { store, editor, field, stepper in
            let original = store.project
            field.text = "0.750"; field.sendActions(for: .editingChanged)
            for text in ["", "not a time", "nan", "inf", "-inf"] {
                field.text = text; field.sendActions(for: .editingChanged)
                XCTAssertEqual(field.text, text)
                XCTAssertEqual(stepper.value, 0.750, accuracy: 0.000_001)
                editor.storeDidChange()
                XCTAssertEqual(field.text, text, "Store refresh must preserve an unfinished draft")
                XCTAssertTrue(stepper.value.isFinite)
                XCTAssertEqual(stepper.value, 0.750, accuracy: 0.000_001)
            }
            field.text = "1.250"; field.sendActions(for: .editingChanged)
            XCTAssertEqual(stepper.value, 1.250, accuracy: 0.000_001)
            XCTAssertEqual(store.project, original)
        }
    }

    func testStepperBoundsDoNotSilentlyRewriteAnOutOfRangeDraft() async throws {
        try await withFixture { store, _, field, stepper in
            let original = store.project
            XCTAssertEqual(stepper.maximumValue, 1.999, accuracy: 0.000_001)
            field.text = "9.000"; field.sendActions(for: .editingChanged)
            XCTAssertEqual(stepper.value, 1.999, accuracy: 0.000_001)
            XCTAssertEqual(field.text, "9.000", "Save validation owns the typed out-of-range value")
            stepper.value -= stepper.stepValue; stepper.sendActions(for: .valueChanged)
            XCTAssertEqual(field.text, "1.998")
            field.text = "-1.000"; field.sendActions(for: .editingChanged)
            XCTAssertEqual(stepper.value, 0, accuracy: 0.000_001)
            XCTAssertEqual(field.text, "-1.000")
            stepper.value += stepper.stepValue; stepper.sendActions(for: .valueChanged)
            XCTAssertEqual(field.text, "0.001")
            XCTAssertEqual(store.project, original)
        }
    }

    func testChoosingAnotherSourceResetsBothControlsAndZeroOwnedDirectionStaysDisabled() async throws {
        try await withFixture { store, editor, field, stepper in
            let original = store.project
            field.text = "0.750"; field.sendActions(for: .editingChanged)
            let source = try XCTUnwrap(views(UIButton.self, in: editor.view).first { $0.menu != nil })
            let actions = try XCTUnwrap(source.menu).children.compactMap { $0 as? UIAction }
            let zeroOwned = try XCTUnwrap(actions.first { $0.title.contains("Zero-owned note") })
            try invoke(zeroOwned)
            XCTAssertEqual(field.text, "0.000")
            XCTAssertEqual(stepper.value, 0, accuracy: 0.000_001)
            XCTAssertFalse(field.isEnabled); XCTAssertFalse(stepper.isEnabled)
            let refreshed = try XCTUnwrap(source.menu).children.compactMap { $0 as? UIAction }
            try invoke(XCTUnwrap(refreshed.first { $0.title.contains("Owned source") }))
            XCTAssertTrue(field.isEnabled); XCTAssertTrue(stepper.isEnabled)
            XCTAssertEqual(field.text, "0.000")
            XCTAssertEqual(stepper.value, 0, accuracy: 0.000_001)
            XCTAssertEqual(store.project, original)
        }
    }

    private func withFixture(_ check: (WorkspaceStore, CueAnchorViewController, UITextField, UIStepper) throws -> Void) async throws {
        guard ProcessInfo.processInfo.arguments.contains("--screenshots") else {
            throw XCTSkip("Requires isolated verification storage; never construct a live user workspace.")
        }
        let store = WorkspaceStore()
        let scratch = try XCTUnwrap(store.projectURL).deletingLastPathComponent().deletingLastPathComponent()
        defer {
            // A supplied verification root may belong to other tests/captures.
            // Only remove this store's newly generated temporary directory.
            if ProcessInfo.processInfo.environment["SCRIV_VERIFICATION_ROOT"] == nil,
               scratch.lastPathComponent.hasPrefix("ScrivVerification-"),
               scratch.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL {
                try? FileManager.default.removeItem(at: scratch)
            }
        }
        for _ in 0..<500 where store.isBootstrapping { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.isBootstrapping)
        guard !store.isBootstrapping else { return }
        store.project = ScrivProject(id: "offset-fixture", scenes: [ScriptScene(id: "scene")], entries: [
            ScriptEntry(id: "owned", sceneId: "scene", order: 0, kind: .direction, text: "Owned source", ownedDurationMs: 2000, coverageDurationMs: 2000),
            ScriptEntry(id: "note", sceneId: "scene", order: 1, kind: .direction, text: "Zero-owned note", ownedDurationMs: 0, coverageDurationMs: 1000)
        ], cues: [ImageCue(id: "picture", sceneId: "scene", startMs: 125, endMs: 1125,
                          startAnchor: ScriptTimeAnchor(entryId: "owned", offsetMs: 125), authoredDurationMs: 1000)])
        store.selectedSceneID = "scene"
        let cue = try XCTUnwrap(store.project.cues.first)
        let editor = CueAnchorViewController(store: store, cue: cue); editor.loadViewIfNeeded()
        let save = try XCTUnwrap(views(UIButton.self, in: editor.view).first { $0.configuration?.title == "Save source" })
        for _ in 0..<100 where !save.isEnabled { try await Task.sleep(for: .milliseconds(10)) }
        defer { store.endEdit(cue.id, context: editor.initialNavigationContext) }
        XCTAssertTrue(save.isEnabled, "The isolated local editor should acquire its lease")
        let field = try XCTUnwrap(views(UITextField.self, in: editor.view).first { $0.accessibilityLabel == "Offset from entry, seconds" })
        let stepper = try XCTUnwrap(views(UIStepper.self, in: editor.view).first)
        try check(store, editor, field, stepper)
    }

    private func views<T: UIView>(_ type: T.Type, in root: UIView) -> [T] {
        var result: [T] = [], pending = [root]
        while let view = pending.popLast() {
            if let match = view as? T { result.append(match) }
            pending.append(contentsOf: view.subviews)
        }
        return result
    }

    private func invoke(_ action: UIAction) throws {
        typealias Handler = @convention(block) (UIAction) -> Void
        let handler = unsafeBitCast(try XCTUnwrap(action.value(forKey: "handler") as AnyObject?), to: Handler.self)
        handler(action)
    }
}
