import UIKit
import XCTest
@testable import ScrivUIKit

/// Synthetic state and UIKit construction only. Never opens, pairs or starts a
/// real runtime, signs in, installs a command, or uses the owner's account.
@MainActor
final class CodexSetupUIKitTests: XCTestCase {
    func testVerificationControllerDoesNotLoadSavedPairing() {
        XCTAssertTrue(ProcessInfo.processInfo.arguments.contains("--screenshots"))
        let controller = CodexController()
        XCTAssertFalse(controller.bridgePaired)
        XCTAssertFalse(controller.isConnected)
        XCTAssertFalse(controller.accountChecked)
    }

    func testSavedPairingDoesNotClaimConnectionOrAccountSignIn() {
        var state = ScrivCodexSetupPresentation()
        XCTAssertEqual(state.connectionText, "Not connected")
        XCTAssertEqual(state.accountText, "Not checked yet")
        XCTAssertFalse(state.canStart)
        state.paired = true
        XCTAssertTrue(state.canStart)
        state.accountChecked = true; state.accountLabel = "Synthetic account"
        XCTAssertEqual(state.connectionText, "Not connected")
        XCTAssertEqual(state.accountText, "Not checked yet")
        XCTAssertFalse(state.canUseAccount)
    }

    func testUncheckedAndReportedSignedOutAccountsStayDistinct() {
        var state = ScrivCodexSetupPresentation(connected: true)
        XCTAssertEqual(state.phase, .checking)
        XCTAssertEqual(state.accountText, "Checking existing account…")
        XCTAssertFalse(state.canUseAccount)
        state.accountChecked = true
        XCTAssertEqual(state.phase, .signInRequired)
        XCTAssertEqual(state.accountText, "Not signed in")
        XCTAssertTrue(state.canUseAccount)
        state.pendingLogin = true
        XCTAssertEqual(state.connectionText, "Connected · waiting for sign-in")
        XCTAssertEqual(state.accountActionTitle, "Cancel sign-in")
        state.pendingLogin = false; state.requiresAuthentication = false
        XCTAssertEqual(state.phase, .ready)
        XCTAssertEqual(state.accountText, "Not required by this provider")
    }

    func testOwnedAndExternalRuntimeStopAndPairingGates() {
        var external = ScrivCodexSetupPresentation(connected: true)
        XCTAssertEqual(external.stopTitle, "Disconnect")
        XCTAssertTrue(external.canStop)
        external.generating = true
        XCTAssertFalse(external.canStop)
        external.managed = true
        XCTAssertEqual(external.stopTitle, "Stop")
        XCTAssertTrue(external.canStop)
        XCTAssertTrue(ScrivCodexSetupPresentation(paired: true).canManagePairing)
        XCTAssertFalse(ScrivCodexSetupPresentation(paired: true, connecting: true).canManagePairing)
        XCTAssertFalse(ScrivCodexSetupPresentation(paired: true, working: true).canManagePairing)
    }

    func testPopupHasOneConnectAndNoManualSetup() throws {
        let setup = makeView()
        XCTAssertEqual(setup.surface, .popup)
        XCTAssertEqual(setup.accessibilityIdentifier, "codex-connection-popup")
        XCTAssertFalse(try button("check", in: setup).isHidden)
        XCTAssertEqual(try button("check", in: setup).configuration?.title, "Connect")
        XCTAssertTrue(descendants(setup).compactMap { $0 as? UITextField }.isEmpty)
        for id in ["connect", "pair", "start", "installation-help", "copy-install", "copy-server", "history"] {
            XCTAssertFalse(descendants(setup).contains { $0.accessibilityIdentifier == "codex-" + id })
        }
        XCTAssertFalse(try button("advanced", in: setup).isHidden)
    }

    func testAdvancedOnlyDispatchesNavigation() throws {
        let setup = makeView(); var navigation = 0, connections = 0, starts = 0, pairs = 0, accounts = 0
        setup.onAdvanced = { navigation += 1 }; setup.onCheck = { connections += 1 }
        setup.onStart = { starts += 1 }; setup.onPair = { pairs += 1 }; setup.onAccount = { accounts += 1 }
        for _ in 0..<4 {
            setup.update(.init(), error: nil, journalError: nil, log: "")
            layout(setup, size: ScrivCodexSetupView.preferredPopupSize)
            try button("advanced", in: setup).sendActions(for: .primaryActionTriggered)
        }
        XCTAssertEqual(navigation, 4)
        XCTAssertEqual(connections, 0); XCTAssertEqual(starts, 0); XCTAssertEqual(pairs, 0); XCTAssertEqual(accounts, 0)
    }

    func testPopupResizingKeepsAdvancedReachable() throws {
        let setup = makeView()
        for size in [CGSize(width: 360, height: 360), CGSize(width: 320, height: 280), CGSize(width: 360, height: 480)] {
            for state in [ScrivCodexSetupPresentation(), .init(checkPhase: .checking), .init(checkPhase: .notFound), .init(connected: true, accountChecked: true), .init(connected: true, accountChecked: true, accountLabel: "Synthetic account", availableModels: ["reported-model"])] {
                setup.update(state, error: state.phase == .notFound ? "Synthetic unavailable runtime" : nil, journalError: nil, log: "")
                layout(setup, size: size)
                let advanced = try button("advanced", in: setup), rect = advanced.convert(advanced.bounds, to: setup)
                XCTAssertGreaterThan(rect.width, 0); XCTAssertGreaterThan(rect.height, 0)
                XCTAssertGreaterThanOrEqual(rect.minY, setup.scroll.frame.maxY - 0.5)
                XCTAssertLessThanOrEqual(rect.maxY, setup.bounds.maxY)
                XCTAssertLessThanOrEqual(setup.header.frame.maxY, setup.scroll.frame.minY + 0.5)
                XCTAssertLessThanOrEqual(setup.scroll.frame.maxY, setup.footer.frame.minY + 0.5)
                XCTAssertGreaterThan(setup.scroll.bounds.height, 0)
                XCTAssertFalse(advanced.isDescendant(of: setup.scroll))
            }
        }
        XCTAssertEqual(ScrivCodexSetupView.preferredSize(available: CGSize(width: 320, height: 300)), CGSize(width: 288, height: 268))
    }

    func testSettingsRefreshRetainsFieldIdentityAndDraft() throws {
        let executable = AccountUI.field("automatic", height: 32), endpoint = AccountUI.field("endpoint", height: 32)
        executable.text = "/synthetic/bin/codex"; endpoint.text = "ws://127.0.0.1:9999"
        let setup = ScrivCodexSetupView(executable: executable, endpoint: endpoint, progress: UIView(), surface: .settings)
        layout(setup, size: CGSize(width: 520, height: 520))
        let before = descendants(setup).compactMap { $0 as? UITextField }
        setup.scroll.setContentOffset(CGPoint(x: 0, y: 120), animated: false)
        for _ in 0..<4 {
            setup.update(.init(paired: true), error: "Synthetic error", journalError: nil, log: "")
            layout(setup, size: CGSize(width: 520, height: 520))
            XCTAssertEqual(descendants(setup).compactMap { $0 as? UITextField }, before)
            XCTAssertEqual(executable.text, "/synthetic/bin/codex")
            XCTAssertEqual(endpoint.text, "ws://127.0.0.1:9999")
            XCTAssertEqual(setup.scroll.contentOffset.y, 120, accuracy: 1)
        }
        XCTAssertTrue(setup.header.isDescendant(of: setup.scroll), "Settings uses one scrolling pane, not a clipping modal header.")
        XCTAssertNil(setup.footer.superview)
        XCTAssertFalse(descendants(setup).contains { $0.accessibilityIdentifier == "codex-advanced" })
    }

    func testSettingsRetainsInstallationPairingHistoryAndExplicitManualConnect() throws {
        let setup = makeView(surface: .settings); var starts = 0, pairs = 0, connects = 0, histories = 0
        setup.onStart = { starts += 1 }; setup.onPair = { pairs += 1 }; setup.onConnect = { connects += 1 }; setup.onHistory = { histories += 1 }
        try button("installation-help", in: setup).sendActions(for: .primaryActionTriggered)
        try button("pairing-controls", in: setup).sendActions(for: .primaryActionTriggered)
        let labels = descendants(setup).compactMap { ($0 as? UILabel)?.text }
        XCTAssertTrue(labels.contains("curl -fsSL https://chatgpt.com/codex/install.sh | sh"))
        XCTAssertTrue(labels.contains("codex"))
        XCTAssertTrue(labels.contains("codex app-server --listen ws://127.0.0.1:4500"))
        XCTAssertEqual(starts, 0); XCTAssertEqual(pairs, 0); XCTAssertEqual(connects, 0)
        try button("connect", in: setup).sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(connects, 1)
        try button("pair", in: setup).sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(pairs, 1)
        setup.update(.init(paired: true), error: nil, journalError: nil, log: "")
        try button("start", in: setup).sendActions(for: .primaryActionTriggered)
        try button("history", in: setup).sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(starts, 1); XCTAssertEqual(histories, 1)
        setup.update(.init(paired: true, connecting: true, checkPhase: .checking), error: nil, journalError: nil, log: "")
        for id in ["connect", "pair", "start", "choose-executable", "rotate", "forget"] { XCTAssertFalse(try button(id, in: setup).isEnabled) }
    }

    func testModelsAndAccountStayTruthful() throws {
        let setup = makeView()
        setup.update(.init(connected: true, accountChecked: true, accountLabel: "Synthetic"), error: nil, journalError: nil, log: "")
        XCTAssertEqual(setup.modelButton.configuration?.title, "No available models reported")
        XCTAssertFalse(setup.modelButton.isEnabled)
        XCTAssertTrue(try button("account", in: setup).isEnabled)
        var state = ScrivCodexSetupPresentation(connected: true, accountChecked: true, accountLabel: "Synthetic", availableModels: ["reported-model"], selectedModel: "stale-model")
        setup.update(state, error: nil, journalError: nil, log: "")
        XCTAssertEqual(setup.modelButton.configuration?.title, "Choose available model")
        state.selectedModel = "reported-model"; setup.update(state, error: nil, journalError: nil, log: "")
        XCTAssertEqual(setup.modelButton.configuration?.title, "reported-model")
        state.generating = true; setup.update(state, error: nil, journalError: nil, log: "")
        XCTAssertFalse(setup.modelButton.isEnabled); XCTAssertFalse(try button("account", in: setup).isEnabled)
    }

    func testCancelAndRetryAreExplicitActions() throws {
        let setup = makeView(); var cancelled = 0, checked = 0
        setup.onCancelCheck = { cancelled += 1 }; setup.onCheck = { checked += 1 }
        setup.update(.init(checkPhase: .checking), error: nil, journalError: nil, log: "")
        XCTAssertFalse(try button("cancel-check", in: setup).isHidden)
        try button("cancel-check", in: setup).sendActions(for: .primaryActionTriggered)
        setup.update(.init(checkPhase: .notFound), error: "Synthetic absent runtime", journalError: nil, log: "")
        let failure = try XCTUnwrap(descendants(setup).first { $0.accessibilityIdentifier == "codex-setup-error" } as? UILabel)
        XCTAssertEqual(failure.text, "Synthetic absent runtime")
        XCTAssertFalse(failure.isHidden, "A connection error must remain visible in the popup")
        XCTAssertEqual(try button("check", in: setup).configuration?.title, "Try again")
        XCTAssertEqual(checked, 0)
        try button("check", in: setup).sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(cancelled, 1); XCTAssertEqual(checked, 1)
    }

    func testConnectionFailureDoesNotExpandInstallationHelp() throws {
        let setup = makeView(surface: .settings)
        setup.update(.init(checkPhase: .notFound), error: "Synthetic connection failure", journalError: nil, log: "")
        XCTAssertEqual(try button("installation-help", in: setup).accessibilityValue, "Collapsed")
        try button("installation-help", in: setup).sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(try button("installation-help", in: setup).accessibilityValue, "Expanded")
    }

    func testBothSurfacesFollowLightAndDarkAppearance() {
        for surface in [ScrivCodexSetupView.Surface.popup, .settings] {
            let setup = makeView(surface: surface)
            XCTAssertEqual(setup.overrideUserInterfaceStyle, .unspecified)
            for style in [UIUserInterfaceStyle.light, .dark] {
                setup.overrideUserInterfaceStyle = style
                let size = surface == .popup ? ScrivCodexSetupView.preferredPopupSize : CGSize(width: 560, height: 660)
                layout(setup, size: size)
                let image = UIGraphicsImageRenderer(size: size).image { context in setup.layer.render(in: context.cgContext) }
                let attachment = XCTAttachment(image: image)
                attachment.name = "Codex-\(surface == .popup ? "popup" : "settings")-\(style == .dark ? "dark" : "light")"
                attachment.lifetime = .keepAlways; add(attachment)
            }
        }
    }

    private func makeView(surface: ScrivCodexSetupView.Surface = .popup) -> ScrivCodexSetupView {
        let progress = UIView(); progress.isHidden = true
        return ScrivCodexSetupView(executable: AccountUI.field("automatic", height: 32), endpoint: AccountUI.field("endpoint", height: 32), progress: progress, surface: surface)
    }
    private func layout(_ setup: ScrivCodexSetupView, size: CGSize) {
        setup.frame = CGRect(origin: .zero, size: size)
        for _ in 0..<5 { setup.setNeedsLayout(); setup.layoutIfNeeded(); setup.scroll.layoutIfNeeded(); setup.body.layoutIfNeeded() }
    }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    private func button(_ id: String, in view: UIView, file: StaticString = #filePath, line: UInt = #line) throws -> UIButton {
        try XCTUnwrap(descendants(view).first { $0.accessibilityIdentifier == "codex-" + id } as? UIButton, "Missing button: \(id)", file: file, line: line)
    }
}
