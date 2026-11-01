import UIKit
import XCTest
import ScrivCore
@testable import ScrivUIKit

/// Executes real UIKit controls using synthetic data. A source-contract pass
/// does not establish native rendering or parity with the proposed reference.
@MainActor
final class ImagePickerSelectionAppearanceTests: XCTestCase {
    func testDisabledAndEnabledAppearanceRoundTripWithoutChangingActionOrGeometry() async throws {
        var actions = 0
        let button = ImageUI.button("Use image", primary: true) { actions += 1 }
        ImagePickerSelectionAppearance.install(on: button)
        let identity = ObjectIdentifier(button)
        let originalInsets = try XCTUnwrap(button.configuration).contentInsets
        button.frame = CGRect(x: 0, y: 0, width: 112, height: 36)
        for enabled in [false, true, false, true] {
            button.isEnabled = enabled
            await settle(button)
            try assertAppearance(button, enabled: enabled)
            XCTAssertEqual(ObjectIdentifier(button), identity)
            XCTAssertEqual(button.configuration?.title, "Use image")
            XCTAssertEqual(button.accessibilityLabel, "Use image")
            XCTAssertEqual(button.configuration?.contentInsets, originalInsets)
            XCTAssertEqual(button.configuration?.background.cornerRadius, 8)
            XCTAssertEqual(button.titleLabel?.numberOfLines, 1)
        }
        XCTAssertEqual(actions, 0, "Appearance changes may never execute the action.")
        button.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(actions, 1, "Installing appearance must retain the original action.")
    }

    func testActualPickerSelectionEnablesActionWithoutMutatingTheProject() async throws {
        let store = try await makeStore()
        let before = store.project
        let controller = ImagePickerViewController(store: store, cueID: "target")
        controller.loadViewIfNeeded(); controller.view.frame = CGRect(x: 0, y: 0, width: 720, height: 720)
        let button = try useButton(in: controller)
        await settle(controller.view); try assertAppearance(button, enabled: false)
        let collection = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UICollectionView }.first)
        XCTAssertEqual(controller.collectionView(collection, numberOfItemsInSection: 0), 1)
        for _ in 0..<3 {
            controller.collectionView(collection, didSelectItemAt: IndexPath(item: 0, section: 0))
            controller.storeDidChange(); await settle(controller.view)
            try assertAppearance(button, enabled: true)
            XCTAssertEqual(store.project, before, "Choosing a card is a draft, not a project write.")
            XCTAssertEqual(controller.collectionView(collection, numberOfItemsInSection: 0), 1)
        }
        let card = controller.collectionView(collection, cellForItemAt: IndexPath(item: 0, section: 0))
        XCTAssertTrue(card.accessibilityTraits.contains(.selected))
        let buttonRect = button.convert(button.bounds, to: controller.view)
        XCTAssertLessThanOrEqual(buttonRect.maxX, controller.view.bounds.maxX)
        XCTAssertLessThanOrEqual(buttonRect.maxY, controller.view.bounds.maxY)
        XCTAssertEqual(button.configuration?.title, "Use image")
    }

    func testDeletedSelectedAssetDisablesActionAndPreservesRemainingData() async throws {
        let store = try await makeStore()
        let controller = ImagePickerViewController(store: store, cueID: "target")
        controller.loadViewIfNeeded(); controller.view.frame = CGRect(x: 0, y: 0, width: 720, height: 720)
        let collection = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UICollectionView }.first)
        controller.collectionView(collection, didSelectItemAt: IndexPath(item: 0, section: 0))
        let button = try useButton(in: controller); await settle(controller.view)
        try assertAppearance(button, enabled: true)
        // This is an in-memory isolated fixture edit, never a user asset delete.
        store.project.images.removeAll()
        let withoutAsset = store.project
        controller.storeDidChange(); await settle(controller.view)
        try assertAppearance(button, enabled: false)
        XCTAssertEqual(controller.collectionView(collection, numberOfItemsInSection: 0), 0)
        XCTAssertEqual(store.project, withoutAsset)
        XCTAssertEqual(store.project.cues.count, 2)
        XCTAssertEqual(store.project.entries.first?.text, "Exact synthetic source. 🙂")
    }

    func testVersionPickerUsesTheSameStateAppearanceAndKeepsVersionTitle() async throws {
        let store = try await makeStore()
        let before = store.project
        let controller = ImagePickerViewController(store: store, cueID: "existing", versionsOf: "v1")
        controller.loadViewIfNeeded(); controller.view.frame = CGRect(x: 0, y: 0, width: 720, height: 720)
        let button = try useButton(in: controller); await settle(controller.view)
        XCTAssertEqual(button.configuration?.title, "Use version")
        try assertAppearance(button, enabled: true)
        controller.searchBar(UISearchBar(), textDidChange: "no matching synthetic title")
        controller.storeDidChange(); await settle(controller.view)
        XCTAssertEqual(button.configuration?.title, "Use version")
        try assertAppearance(button, enabled: true)
        XCTAssertEqual(store.project, before, "Search must not lose the existing selected version or mutate it.")
    }

    private func makeStore() async throws -> WorkspaceStore {
        guard ProcessInfo.processInfo.arguments.contains("--screenshots") else {
            XCTFail("Run only with the scheme's isolated --screenshots verification argument.")
            throw FixtureError.requiresIsolatedVerification
        }
        let store = WorkspaceStore()
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while store.isBootstrapping, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard !store.isBootstrapping else {
            XCTFail("Isolated verification store did not finish bootstrapping.")
            throw FixtureError.bootstrapTimeout
        }
        store.project = ScrivProject(id: UUID().uuidString,
            scenes: [ScriptScene(id: "scene")],
            entries: [ScriptEntry(id: "line", sceneId: "scene", order: 0, text: "Exact synthetic source. 🙂", ownedDurationMs: 1000)],
            images: [ImageAsset(id: "v1", version: 1, fileName: "synthetic-not-present.png", sha256: "synthetic", byteCount: 1)],
            cues: [ImageCue(id: "target", sceneId: "scene", label: "01A 2", startMs: 0, endMs: 500), ImageCue(id: "existing", sceneId: "scene", imageId: "v1", label: "01A", startMs: 500, endMs: 1000)])
        return store
    }
    private enum FixtureError: Error { case requiresIsolatedVerification, bootstrapTimeout }
    private func settle(_ view: UIView) async {
        for _ in 0..<6 { view.setNeedsLayout(); view.layoutIfNeeded(); try? await Task.sleep(for: .milliseconds(10)) }
    }
    private func assertAppearance(_ button: UIButton, enabled: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(button.isEnabled, enabled, file: file, line: line)
        let config = try XCTUnwrap(button.configuration, file: file, line: line)
        let background = enabled ? ImageUI.accent : ScrivUIKitTheme.inset
        let foreground = enabled ? UIColor.white : ScrivUIKitTheme.secondary
        XCTAssertEqual(config.baseBackgroundColor?.resolvedColor(with: button.traitCollection), background.resolvedColor(with: button.traitCollection), file: file, line: line)
        XCTAssertEqual(config.background.backgroundColor?.resolvedColor(with: button.traitCollection), background.resolvedColor(with: button.traitCollection), file: file, line: line)
        XCTAssertEqual(config.baseForegroundColor?.resolvedColor(with: button.traitCollection), foreground.resolvedColor(with: button.traitCollection), file: file, line: line)
        XCTAssertNotNil(config.titleTextAttributesTransformer, file: file, line: line)
        if enabled { XCTAssertNil(config.background.backgroundColorTransformer, file: file, line: line) }
        else { XCTAssertNotNil(config.background.backgroundColorTransformer, file: file, line: line) }
    }
    private func useButton(in controller: UIViewController) throws -> UIButton {
        try XCTUnwrap(descendants(controller.view).first { $0.accessibilityIdentifier == "image-picker-use-selection" } as? UIButton)
    }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap { descendants($0) } }
}
