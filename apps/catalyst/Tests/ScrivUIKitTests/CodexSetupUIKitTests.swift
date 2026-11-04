import UIKit
import XCTest
@testable import ScrivUIKit

/// Synthetic state and real UIKit construction. The route-wrapper case uses the
/// app's --screenshots verification store; no test opens/pairs/starts a runtime.
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
        XCTAssertEqual(state.accountText, "Not checked yet")
        state.accountChecked = true; state.accountLabel = "Synthetic account"
        XCTAssertEqual(state.connectionText, "Not connected")
        XCTAssertEqual(state.accountText, "Not checked yet")
        XCTAssertFalse(state.canUseAccount)
    }
    func testUncheckedAndReportedSignedOutAccountsStayDistinct() {
        var state = ScrivCodexSetupPresentation(connected: true)
        XCTAssertEqual(state.accountText, "Checking existing account…")
        XCTAssertFalse(state.canUseAccount)
        state.accountChecked = true
        XCTAssertEqual(state.accountText, "Not signed in"); XCTAssertTrue(state.canUseAccount)
        state.pendingLogin = true
        XCTAssertEqual(state.accountText, "Complete sign-in in your browser")
        XCTAssertEqual(state.accountActionTitle, "Cancel sign-in")
        state.pendingLogin = false; state.accountLabel = "Synthetic account"
        XCTAssertEqual(state.accountText, "Synthetic account"); XCTAssertEqual(state.accountActionTitle, "Manage…")
        state.connected = false
        XCTAssertEqual(state.accountText, "Not checked yet")
    }
    func testManagedStopAndExternalDisconnectRetainDistinctOwnership() {
        var external = ScrivCodexSetupPresentation(connected: true)
        XCTAssertEqual(external.stopTitle, "Disconnect"); XCTAssertTrue(external.canStop)
        external.generating = true
        XCTAssertFalse(external.canStop, "Cancel generation before leaving an external runtime.")
        var managed = external; managed.managed = true
        XCTAssertEqual(managed.stopTitle, "Stop"); XCTAssertTrue(managed.canStop)
        XCTAssertFalse(managed.canManagePairing); XCTAssertFalse(managed.canStart); XCTAssertFalse(managed.canEditConnection)
        XCTAssertTrue(ScrivCodexSetupPresentation(paired: true).canManagePairing)
        XCTAssertFalse(ScrivCodexSetupPresentation(paired: true, connecting: true).canManagePairing)
        XCTAssertFalse(ScrivCodexSetupPresentation(paired: true, working: true).canManagePairing)
    }
    func testInitialViewHasOneCheckAndCollapsedOptionalDetails() throws {
        let setup = makeView()
        XCTAssertNil(setup.advancedContent.superview); XCTAssertNil(setup.pairingContent.superview)
        XCTAssertEqual(try button("advanced", in: setup).accessibilityValue, "Collapsed")
        XCTAssertTrue(try button("check", in: setup).isEnabled)
        XCTAssertFalse(descendants(of: setup).contains { $0.accessibilityIdentifier == "codex-pair" })
        let labels = descendants(of: setup).compactMap { ($0 as? UILabel)?.text }
        XCTAssertTrue(labels.contains("Connect Codex in one click")); XCTAssertFalse(labels.contains("Use the Runtime Companion"))
        XCTAssertTrue(labels.contains("Scriv finds and starts Codex on this Mac. No server address is needed."))
    }

    func testLoadResizeAndExpandedDetailsKeepHeaderAndFooterOutsideScroll() throws {
        let setup = makeView()
        for (width, height) in [(CGFloat(740), CGFloat(840)), (640, 760), (420, 600)] {
            setup.frame = CGRect(x: 0, y: 0, width: width, height: height)
            for expanded in [false, true, false] {
                if (setup.advancedContent.superview != nil) != expanded {
                    if expanded {
                        try button("advanced", in: setup).sendActions(for: .primaryActionTriggered)
                        try button("pairing-controls", in: setup).sendActions(for: .primaryActionTriggered)
                    } else {
                        try button("pairing-controls", in: setup).sendActions(for: .primaryActionTriggered)
                        try button("advanced", in: setup).sendActions(for: .primaryActionTriggered)
                    }
                }
                setup.setNeedsLayout(); setup.layoutIfNeeded(); setup.body.layoutIfNeeded()
                XCTAssertGreaterThan(setup.scroll.bounds.height, 100)
                XCTAssertLessThanOrEqual(setup.header.frame.maxY, setup.scroll.frame.minY)
                XCTAssertLessThanOrEqual(setup.scroll.frame.maxY, setup.footer.frame.minY)
                XCTAssertLessThanOrEqual(setup.footer.frame.maxY, height)
                XCTAssertFalse(setup.header.isDescendant(of: setup.scroll)); XCTAssertFalse(setup.footer.isDescendant(of: setup.scroll))
                XCTAssertTrue(try button("done", in: setup).isDescendant(of: setup.header))
                if expanded {
                    XCTAssertGreaterThan(setup.scroll.contentSize.height, setup.scroll.bounds.height)
                    XCTAssertNotNil(setup.advancedContent.superview); XCTAssertNotNil(setup.pairingContent.superview)
                }
            }
        }
    }
    func testRepeatedDisclosureAndStateUpdatesRetainConnectionFieldDrafts() throws {
        let executable = AccountUI.field("executable", height: 32), endpoint = AccountUI.field("endpoint", height: 32)
        executable.text = "/synthetic/unsaved codex"; endpoint.text = "ws://127.0.0.1:9999"
        let setup = ScrivCodexSetupView(executable: executable, endpoint: endpoint, progress: UIView())
        let executableID = ObjectIdentifier(executable), endpointID = ObjectIdentifier(endpoint)
        for _ in 0..<3 {
            try button("advanced", in: setup).sendActions(for: .primaryActionTriggered)
            XCTAssertTrue(executable.isDescendant(of: setup))
            setup.update(ScrivCodexSetupPresentation(paired: true), error: "Synthetic connection error", journalError: "Synthetic retained history error", log: "Synthetic response")
            XCTAssertEqual(ObjectIdentifier(executable), executableID); XCTAssertEqual(ObjectIdentifier(endpoint), endpointID)
            XCTAssertEqual(executable.text, "/synthetic/unsaved codex"); XCTAssertEqual(endpoint.text, "ws://127.0.0.1:9999")
            XCTAssertTrue(try button("start", in: setup).isEnabled, "A connection error must not forget valid pairing.")
            try button("advanced", in: setup).sendActions(for: .primaryActionTriggered)
            XCTAssertFalse(executable.isDescendant(of: setup))
        }
    }
    func testOpeningPairingDisclosuresAndDoneNeverStartRuntime() throws {
        let setup = makeView(); var starts = 0, connects = 0, checks = 0, closes = 0
        setup.onStart = { starts += 1 }; setup.onConnect = { connects += 1 }
        setup.onCheck = { checks += 1 }; setup.onDone = { closes += 1 }
        try button("advanced", in: setup).sendActions(for: .primaryActionTriggered)
        try button("pairing-controls", in: setup).sendActions(for: .primaryActionTriggered)
        try button("start", in: setup).sendActions(for: .primaryActionTriggered)
        try button("done", in: setup).sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(starts, 0); XCTAssertEqual(connects, 0); XCTAssertEqual(checks, 0); XCTAssertEqual(closes, 1)
        try button("check", in: setup).sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(checks, 1)
        setup.update(ScrivCodexSetupPresentation(paired: true, connecting: true, checkPhase: .checking), error: nil, journalError: nil, log: "")
        try button("check", in: setup).sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(checks, 1, "Repeated click cannot dispatch while checking")
    }

    func testModelDisplayUsesOnlyActuallyReportedModels() throws {
        let setup = makeView(); XCTAssertFalse(setup.modelButton.isDescendant(of: setup))
        setup.update(ScrivCodexSetupPresentation(connected: true, accountChecked: true, accountLabel: "Synthetic"), error: nil, journalError: nil, log: "")
        XCTAssertTrue(setup.modelButton.isDescendant(of: setup)); XCTAssertEqual(setup.modelButton.configuration?.title, "No available models reported")
        XCTAssertFalse(setup.modelButton.isEnabled)
        var state = ScrivCodexSetupPresentation(connected: true, accountChecked: true, accountLabel: "Synthetic", availableModels: ["reported-model"], selectedModel: "stale-model")
        setup.update(state, error: nil, journalError: nil, log: "")
        XCTAssertEqual(setup.modelButton.configuration?.title, "Choose available model")
        state.selectedModel = "reported-model"; setup.update(state, error: nil, journalError: nil, log: "")
        XCTAssertEqual(setup.modelButton.configuration?.title, "reported-model")
        state.generating = true; setup.update(state, error: nil, journalError: nil, log: ""); XCTAssertFalse(setup.modelButton.isEnabled)
    }

    func testLongActualAccountAndRuntimeStatusRemainReadable() throws {
        let setup = makeView(), account = String(repeating: "Synthetic long identity ", count: 4), status = String(repeating: "Synthetic running stage ", count: 4)
        setup.update(ScrivCodexSetupPresentation(connected: true, generating: true, accountChecked: true, accountLabel: account, runtimeStatus: status), error: nil, journalError: nil, log: "")
        setup.frame = CGRect(x: 0, y: 0, width: 420, height: 900)
        for _ in 0..<5 { setup.setNeedsLayout(); setup.layoutIfNeeded() }
        for (id, text) in [("codex-connection-status", status), ("codex-account-status", account)] {
            let label = try XCTUnwrap(descendants(of: setup).first { $0.accessibilityIdentifier == id } as? UILabel)
            XCTAssertEqual(label.text, text); XCTAssertEqual(label.numberOfLines, 0); XCTAssertGreaterThan(label.bounds.height, 30)
        }
    }

    func testWideSheetPinsDoneAndUsesFullWidthPrimaryAction() throws {
        XCTAssertEqual(ScrivCodexSetupView.preferredSheetSize, CGSize(width: 584, height: 614))
        XCTAssertEqual(ScrivCodexSetupView.preferredSize(for: .ready), CGSize(width: 584, height: 614))
        XCTAssertEqual(ScrivCodexSetupView.preferredSize(for: .signInRequired), CGSize(width: 584, height: 614))
        XCTAssertEqual(ScrivCodexSetupView.preferredSize(for: .idle, available: CGSize(width: 420, height: 600)), CGSize(width: 388, height: 568))
        let setup = makeView(); setup.frame = CGRect(origin: .zero, size: ScrivCodexSetupView.preferredSheetSize)
        for _ in 0..<5 { setup.setNeedsLayout(); setup.layoutIfNeeded() }
        let done = try button("done", in: setup), check = try button("check", in: setup)
        XCTAssertEqual(done.convert(done.bounds, to: setup).maxX, setup.header.frame.maxX, accuracy: 1)
        XCTAssertGreaterThan(done.convert(done.bounds, to: setup).minX, setup.bounds.width * 0.85)
        XCTAssertEqual(check.bounds.width, setup.body.bounds.width, accuracy: 1)
        XCTAssertLessThanOrEqual(setup.scroll.frame.maxY, setup.footer.frame.minY)
    }

    func testMissingAndAuthenticationActionsFitCompactSheet() throws {
        let setup = makeView(); setup.frame = CGRect(x: 0, y: 0, width: 420, height: 600)
        for state in [ScrivCodexSetupPresentation(checkPhase: .notFound), ScrivCodexSetupPresentation(connected: true, accountChecked: true)] {
            setup.update(state, error: nil, journalError: nil, log: "")
            for _ in 0..<5 { setup.setNeedsLayout(); setup.layoutIfNeeded() }
            for action in descendants(of: setup).compactMap({ $0 as? UIButton }).filter({ !$0.isHidden && $0.bounds.width > 0 }) {
                let frame = action.convert(action.bounds, to: setup)
                XCTAssertGreaterThanOrEqual(frame.minX, -0.5); XCTAssertLessThanOrEqual(frame.maxX, setup.bounds.width + 0.5)
                XCTAssertEqual(action.configuration?.titleLineBreakMode, .byWordWrapping)
            }
            XCTAssertLessThanOrEqual(setup.scroll.frame.maxY, setup.footer.frame.minY); XCTAssertLessThanOrEqual(setup.footer.frame.maxY, setup.bounds.height)
        }
    }

    func testCancelRetryAndMissingCommandsDoNotDispatchAnInstall() throws {
        let setup = makeView(); var cancelled = 0, checked = 0
        setup.onCancelCheck = { cancelled += 1 }; setup.onCheck = { checked += 1 }
        setup.update(ScrivCodexSetupPresentation(checkPhase: .checking), error: nil, journalError: nil, log: "")
        XCTAssertFalse(try button("cancel-check", in: setup).isHidden)
        try button("cancel-check", in: setup).sendActions(for: .primaryActionTriggered); XCTAssertEqual(cancelled, 1)
        setup.update(ScrivCodexSetupPresentation(checkPhase: .notFound), error: "Synthetic absent server", journalError: nil, log: "")
        let failedLabels = descendants(of: setup).compactMap { ($0 as? UILabel)?.text }
        XCTAssertFalse(failedLabels.contains("curl -fsSL https://chatgpt.com/codex/install.sh | sh"), "A connection failure does not prove Codex is missing")
        XCTAssertTrue(failedLabels.contains("Synthetic absent server"), "The error must be visible without expanding Advanced")
        try button("installation-help", in: setup).sendActions(for: .primaryActionTriggered)
        let labels = descendants(of: setup).compactMap { ($0 as? UILabel)?.text }
        XCTAssertTrue(labels.contains("curl -fsSL https://chatgpt.com/codex/install.sh | sh"))
        XCTAssertFalse(labels.contains("codex app-server --listen ws://127.0.0.1:4500"), "Manual server setup belongs in Advanced")
        try button("advanced", in: setup).sendActions(for: .primaryActionTriggered)
        let advancedLabels = descendants(of: setup).compactMap { ($0 as? UILabel)?.text }
        XCTAssertTrue(advancedLabels.contains("codex app-server --listen ws://127.0.0.1:4500"))
        XCTAssertEqual(try button("check", in: setup).configuration?.title, "Check again")
        try button("check", in: setup).sendActions(for: .primaryActionTriggered); XCTAssertEqual(checked, 1)
    }

    func testGeneratedReferenceStatesRenderAtMeasuredViewports() {
        let fixtures: [(String, ScrivCodexSetupPresentation)] = [
            ("initial", .init()), ("missing", .init(checkPhase: .notFound)),
            ("connected", .init(connected: true, accountChecked: true, accountLabel: "Signed in", availableModels: ["synthetic-model"])),
            ("sign-in-required", .init(connected: true, accountChecked: true))
        ]
        for (name, state) in fixtures {
            let setup = makeView(); setup.update(state, error: nil, journalError: nil, log: "")
            setup.frame = CGRect(origin: .zero, size: ScrivCodexSetupView.preferredSize(for: state.phase))
            for _ in 0..<6 { setup.setNeedsLayout(); setup.layoutIfNeeded(); setup.body.layoutIfNeeded() }
            XCTAssertLessThanOrEqual(setup.scroll.contentSize.height, setup.scroll.bounds.height + 1, "The desktop \(name) reference shows every action without scrolling.")
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let rendered = UIGraphicsImageRenderer(size: setup.bounds.size, format: format).image { context in setup.layer.render(in: context.cgContext) }
            let attachment = XCTAttachment(image: rendered); attachment.name = "Codex-reference-" + name; attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    func testActualCodexRouteHidesChromeBeforeSizingAndPreservesSettings() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--screenshots") else {
            XCTFail("Run with the scheme's isolated --screenshots verification argument.")
            return
        }
        let store = WorkspaceStore(), router = ScrivUIKitRouter()
        ScrivUIKitFeatures.registerAccount(in: router)
        let navigation = try XCTUnwrap(router.controller(for: .codex, store: store) as? UINavigationController)
        let settings = try XCTUnwrap(router.controller(for: .settings, store: store) as? ScrivSettingsPanelController)
        let settingsDetail = try XCTUnwrap(settings.viewController(for: .secondary) as? UINavigationController)
        XCTAssertEqual(settings.preferredContentSize, CGSize(width: 880, height: 660))
        XCTAssertFalse(settingsDetail.isNavigationBarHidden)
        XCTAssertTrue(navigation.isNavigationBarHidden, "The wrapper must not initially measure a system navigation bar.")
        XCTAssertEqual(navigation.preferredContentSize, ScrivCodexSetupView.preferredSheetSize)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let previous = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
        let window: UIWindow
        if let scene = previous?.windowScene ?? scenes.first { window = UIWindow(windowScene: scene) }
        else { window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1200, height: 1000)) }
        let host = CodexSheetTestHostController()
        let hostAppeared = expectation(description: "Codex fixture host appeared")
        host.didAppear = { hostAppeared.fulfill() }; window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        await fulfillment(of: [hostAppeared], timeout: 5)
        // Revision 6 observed an attached form sheet but no nonanimated
        // presentation completion within five seconds. Assert the actual
        // route/window/settled transition rather than callback delivery alone.
        host.present(navigation, animated: false)
        defer { if host.presentedViewController != nil { host.dismiss(animated: false) } }
        let presented = await waitForPresentationState {
            host.presentedViewController === navigation &&
            navigation.presentingViewController === host &&
            navigation.viewIfLoaded?.window != nil &&
            // The wrapper can reach its window before it installs its child's view.
            navigation.topViewController?.viewIfLoaded?.window != nil &&
            navigation.view.bounds.width > 0 && navigation.view.bounds.height > 0 &&
            !navigation.isBeingPresented && navigation.transitionCoordinator == nil
        }
        XCTAssertTrue(presented, "Actual Codex form sheet must attach and finish transitioning within five seconds")
        XCTAssertTrue(navigation.isNavigationBarHidden)
        let controller = try XCTUnwrap(navigation.topViewController)
        let setup = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? ScrivCodexSetupView }.first)
        for _ in 0..<3 { setup.setNeedsLayout(); setup.layoutIfNeeded() }
        XCTAssertNotNil(setup.window)
        XCTAssertEqual(controller.preferredContentSize, ScrivCodexSetupView.preferredSheetSize)
        XCTAssertLessThanOrEqual(setup.bounds.height, 850, "The actual wrapper must not add revision4's roughly55-point hidden navigation-bar space.")
        XCTAssertLessThanOrEqual(setup.scroll.frame.maxY, setup.footer.frame.minY)
        XCTAssertLessThanOrEqual(setup.footer.frame.maxY, setup.bounds.height)
        let measurement = XCTAttachment(string: "Codex native wrapper: navigation=\(navigation.view.bounds), content=\(setup.bounds), preferred=\(controller.preferredContentSize)")
        measurement.lifetime = .keepAlways; add(measurement)
        host.dismiss(animated: false)
        let dismissed = await waitForPresentationState {
            host.presentedViewController == nil && navigation.viewIfLoaded?.window == nil
        }
        XCTAssertTrue(dismissed, "Dismiss the real sheet before tearing down its host window")
    }
    func testInstalledFooterLinksKeepOpticalGapAndStackWithoutLosingTitlesOrActions() throws {
        let setup = makeView()
        var histories = 0, jobsOpened = 0, starts = 0, pairs = 0
        setup.onHistory = { histories += 1 }; setup.onJobs = { jobsOpened += 1 }
        setup.onStart = { starts += 1 }; setup.onPair = { pairs += 1 }
        let history = try button("jobs", in: setup), jobs = try button("history", in: setup)
        var firstWideGap: CGFloat?
        for size in [CGSize(width: 740, height: 840), CGSize(width: 420, height: 600), CGSize(width: 740, height: 840)] {
            setup.frame = CGRect(origin: .zero, size: size)
            // The installed footer switches axis during layout; repeat the
            // enclosing pass before inspecting actual labels, not just spacing.
            for _ in 0..<5 { setup.setNeedsLayout(); setup.layoutIfNeeded() }
            let historyLabel = try XCTUnwrap(history.titleLabel), jobsLabel = try XCTUnwrap(jobs.titleLabel)
            for (button, title) in [(history, "Generation jobs"), (jobs, "Existing history…")] {
                let label = try XCTUnwrap(button.titleLabel)
                let rendered = label.attributedText ?? NSAttributedString(string: label.text ?? "")
                let attributedFont = rendered.length > 0 ? rendered.attribute(.font, at: 0, effectiveRange: nil) as? UIFont : nil
                let font = try XCTUnwrap(attributedFont ?? label.font)
                XCTAssertEqual(rendered.string, title)
                XCTAssertEqual(font.pointSize, 14, accuracy: 0.1)
                XCTAssertFalse(label.adjustsFontSizeToFitWidth)
                let measured = NSMutableAttributedString(attributedString: rendered)
                measured.enumerateAttribute(.font, in: NSRange(location: 0, length: measured.length), options: []) { value, range, _ in
                    if value == nil { measured.addAttribute(.font, value: font, range: range) }
                }
                let fullTitle = measured.boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                XCTAssertGreaterThan(label.bounds.width, 0)
                XCTAssertGreaterThan(label.bounds.height, 0)
                XCTAssertLessThanOrEqual(fullTitle.width, label.bounds.width + 0.5, "The full footer title must remain readable on one line")
                if button === history {
                    XCTAssertLessThanOrEqual(label.bounds.width, ceil(fullTitle.width) + 1, "History's measured edge must hug visible text, not include a stretched blank tail")
                }
                XCTAssertGreaterThanOrEqual(label.bounds.height + 0.5, label.sizeThatFits(CGSize(width: label.bounds.width, height: CGFloat.greatestFiniteMagnitude)).height)
                let titleFrame = label.convert(label.bounds, to: button)
                XCTAssertGreaterThanOrEqual(titleFrame.minX, -0.5)
                XCTAssertLessThanOrEqual(titleFrame.maxX, button.bounds.width + 0.5)
                XCTAssertGreaterThanOrEqual(titleFrame.minY, -0.5)
                XCTAssertLessThanOrEqual(titleFrame.maxY, button.bounds.height + 0.5)
                XCTAssertTrue(button.point(inside: CGPoint(x: button.bounds.midX, y: button.bounds.midY), with: nil))
                let hitFrame = button.convert(button.bounds, to: setup)
                XCTAssertGreaterThanOrEqual(hitFrame.minX, setup.footer.frame.minX - 0.5)
                XCTAssertLessThanOrEqual(hitFrame.maxX, setup.footer.frame.maxX + 0.5)
                XCTAssertGreaterThanOrEqual(hitFrame.minY, setup.footer.frame.minY - 0.5)
                XCTAssertLessThanOrEqual(hitFrame.maxY, setup.footer.frame.maxY + 0.5)
                XCTAssertFalse(button.isDescendant(of: setup.scroll))
                button.sendActions(for: .primaryActionTriggered)
                button.sendActions(for: .primaryActionTriggered)
            }
            let historyText = historyLabel.convert(historyLabel.bounds, to: setup)
            let jobsText = jobsLabel.convert(jobsLabel.bounds, to: setup)
            let historyHit = history.convert(history.bounds, to: setup), jobsHit = jobs.convert(jobs.bounds, to: setup)
            print("SCRIV_CODEX_FOOTER sheet=\(size) historyHit=\(historyHit) historyText=\(historyText) historyIntrinsic=\(history.intrinsicContentSize) historyInsets=\(String(describing: history.configuration?.contentInsets)) jobsHit=\(jobsHit) jobsText=\(jobsText) jobsIntrinsic=\(jobs.intrinsicContentSize) jobsInsets=\(String(describing: jobs.configuration?.contentInsets))")
            print("SCRIV_CODEX_FOOTER_INTERNAL historyTitle=\(historyLabel.convert(historyLabel.bounds, to: history)) historyAlignmentInsets=\(history.alignmentRectInsets) historyHugging=\(history.contentHuggingPriority(for: .horizontal).rawValue) jobsTitle=\(jobsLabel.convert(jobsLabel.bounds, to: jobs)) jobsAlignmentInsets=\(jobs.alignmentRectInsets) jobsHugging=\(jobs.contentHuggingPriority(for: .horizontal).rawValue) axis=\(String(describing: (history.superview as? UIStackView)?.axis)) spacing=\(String(describing: (history.superview as? UIStackView)?.spacing)) visibleGap=\(jobsText.minX - historyText.maxX)")
            XCTAssertFalse(historyText.intersects(jobsText))
            XCTAssertFalse(historyHit.intersects(jobsHit))
            XCTAssertEqual(historyText.minX, setup.footer.frame.minX + 2, accuracy: 0.5, "History must stay aligned to the leading footer edge")
            if size.width == 740 {
                let visibleGap = jobsText.minX - historyText.maxX
                XCTAssertGreaterThanOrEqual(visibleGap / size.width, 0.06, "The visible titles need the approved breathing room, not just a nominal stack gap")
                XCTAssertLessThanOrEqual(visibleGap / size.width, 0.09, "Jobs must remain grouped with History instead of drifting to the far edge")
                XCTAssertEqual(historyText.midY, jobsText.midY, accuracy: 0.5)
                XCTAssertLessThanOrEqual(history.bounds.width, history.intrinsicContentSize.width + 0.5, "History must not absorb trailing space")
                XCTAssertLessThanOrEqual(jobs.bounds.width, jobs.intrinsicContentSize.width + 0.5, "Jobs must not absorb trailing space")
                if let firstWideGap { XCTAssertEqual(visibleGap, firstWideGap, accuracy: 0.5) }
                else { firstWideGap = visibleGap }
            } else {
                XCTAssertEqual(jobsText.minX, historyText.minX, accuracy: 0.5)
                XCTAssertEqual(jobsHit.minY - historyHit.maxY, 18, accuracy: 0.5, "Compact footer links must stack in order with their full hit targets separated")
            }
            XCTAssertGreaterThanOrEqual(setup.footer.frame.minY, setup.scroll.frame.maxY)
            XCTAssertLessThanOrEqual(setup.footer.frame.maxY, setup.bounds.height)
        }
        XCTAssertEqual(histories, 6); XCTAssertEqual(jobsOpened, 6)
        XCTAssertEqual(starts, 0); XCTAssertEqual(pairs, 0)
    }

    private func waitForPresentationState(_ ready: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !ready(), ProcessInfo.processInfo.systemUptime < deadline {
            // Yield the main actor so UIKit can finish its actual transition.
            do { try await Task.sleep(nanoseconds: 10_000_000) }
            catch { return false }
        }
        return ready()
    }
    private func makeView() -> ScrivCodexSetupView {
        let progress = UIView(); progress.isHidden = true // Same disconnected state as the real progress view.
        return ScrivCodexSetupView(executable: AccountUI.field("executable", height: 32), endpoint: AccountUI.field("endpoint", height: 32), progress: progress)
    }
    private func descendants(of view: UIView) -> [UIView] { [view] + view.subviews.flatMap { descendants(of: $0) } }
    private func button(_ id: String, in view: UIView, file: StaticString = #filePath, line: UInt = #line) throws -> UIButton {
        try XCTUnwrap(descendants(of: view).first { $0.accessibilityIdentifier == "codex-" + id } as? UIButton, "Missing button: \(id)", file: file, line: line)
    }
}

@MainActor
private final class CodexSheetTestHostController: UIViewController {
    var didAppear: (() -> Void)?
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let callback = didAppear; didAppear = nil; callback?()
    }
}
