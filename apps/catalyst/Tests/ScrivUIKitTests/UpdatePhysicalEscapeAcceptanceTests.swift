import UIKit
import XCTest
@testable import ScrivUIKit

/// Opt-in OS-input acceptance, never an unattended CI test. The operator sends
/// real Escape key events to the isolated test host; this code does not invoke
/// the keyboard selector, synthesize presses, or connect to Sparkle.
@MainActor
final class UpdatePhysicalEscapeAcceptanceTests: XCTestCase {
    func testPhysicalEscapeTraversesResponderRoute() async throws {
        guard ProcessInfo.processInfo.environment["SCRIV_PHYSICAL_ESCAPE_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Interactive acceptance requires explicit opt-in and an operator sending eight Escape presses.")
        }
        guard ProcessInfo.processInfo.arguments.contains("--screenshots") else {
            throw FixtureFailure("Physical Escape acceptance requires isolated --screenshots storage.")
        }
        guard UIApplication.shared is ScrivUIKitApplication,
              ScrivUIKitApplication.onVerificationEscapeEnded == nil else {
            throw FixtureFailure("The isolated keyboard observer is unavailable or another fixture owns it.")
        }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let previous = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
        let scene = try XCTUnwrap(previous?.windowScene ?? scenes.first)
        let token = UUID().uuidString
        let fixtureTitle = "Scriv Escape Fixture \(token.prefix(8)) · PID \(ProcessInfo.processInfo.processIdentifier)"
        let previousSceneTitle = scene.title
#if targetEnvironment(macCatalyst)
        let titlebar = scene.titlebar
        let previousTitleVisibility = titlebar?.titleVisibility
#endif
        // A scene title is verification after app selection, not an app selector.
        // Report only this test host's own identity; never inspect other processes.
        let identity: [String: Any] = [
            "fixtureToken": token, "sceneTitle": fixtureTitle,
            "processIdentifier": ProcessInfo.processInfo.processIdentifier,
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "unknown",
            "bundlePath": Bundle.main.bundleURL.resolvingSymlinksInPath().path
        ]
        let identityJSON = String(decoding: try JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys]), as: UTF8.self)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1000, height: 900)
        window.accessibilityIdentifier = "scriv.synthetic-update-escape"
        let root = UIViewController()
        root.title = fixtureTitle
        window.rootViewController = root
        var escapeEnds = 0, replies: [String] = [], closeCount = 0
        var report = ["Synthetic updater. Operator-supplied OS Escape events; no live update service.", identityJSON]
        ScrivUIKitApplication.onVerificationEscapeEnded = { if window.isKeyWindow { escapeEnds += 1 } }
        defer {
            ScrivUIKitApplication.onVerificationEscapeEnded = nil
            root.dismiss(animated: false); window.isHidden = true
            scene.title = previousSceneTitle
#if targetEnvironment(macCatalyst)
            if let previousTitleVisibility { titlebar?.titleVisibility = previousTitleVisibility }
#endif
            previous?.makeKey()
            report.append("Observed Escape releases: \(escapeEnds). Replies: \(replies). Close callbacks: \(closeCount).")
            let attachment = XCTAttachment(string: report.joined(separator: "\n"))
            attachment.name = "Synthetic physical Escape acceptance"
            attachment.lifetime = .keepAlways; add(attachment)
        }
        scene.title = fixtureTitle
#if targetEnvironment(macCatalyst)
        titlebar?.titleVisibility = .visible
#endif
        window.makeKeyAndVisible()
        print("SCRIV_PHYSICAL_ESCAPE_IDENTITY \(identityJSON)")
        guard await settled({ root.viewIfLoaded?.window != nil && window.isKeyWindow }) else {
            throw FixtureFailure("The synthetic fixture did not attach to its key window.")
        }
        // First establish a visible, deliberate operator handshake. Do not send
        // Escape to an app selected only by an ambiguous bundle ID or old path.
        // This bounded setup wait is separate from each 90-second key step.
        let heading = UILabel()
        heading.text = fixtureTitle; heading.font = .boldSystemFont(ofSize: 24)
        let instructions = UILabel()
        instructions.text = "Match this token to SCRIV_PHYSICAL_ESCAPE_IDENTITY in the current test log.\n\nThis is a synthetic test host. Nothing can download or install.\n\nClick Begin only after verifying this exact window. Do not press Escape yet."
        for label in [heading, instructions] { label.numberOfLines = 0; label.textAlignment = .center }
        let begin = UIButton(type: .system)
        begin.setTitle("Begin eight Escape checks", for: .normal)
        begin.accessibilityIdentifier = "scriv.synthetic-update-escape.begin"
        var armed = false
        begin.addAction(UIAction { [weak begin, weak window, weak scene] _ in
            guard let window, let scene, window.isKeyWindow && scene.activationState == .foregroundActive else { return }
            armed = true; begin?.isEnabled = false
        }, for: .touchUpInside)
        let readiness = UIStackView(arrangedSubviews: [heading, instructions, begin])
        readiness.axis = .vertical; readiness.spacing = 24; readiness.translatesAutoresizingMaskIntoConstraints = false
        root.view.backgroundColor = .systemBackground; root.view.addSubview(readiness)
        let preferredWidth = readiness.widthAnchor.constraint(equalTo: root.view.widthAnchor, multiplier: 0.8)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            readiness.centerXAnchor.constraint(equalTo: root.view.centerXAnchor),
            readiness.centerYAnchor.constraint(equalTo: root.view.centerYAnchor),
            preferredWidth,
            readiness.widthAnchor.constraint(lessThanOrEqualToConstant: 800)
        ])
        print("SCRIV_PHYSICAL_ESCAPE_AWAITING_OPERATOR token=\(token)")
        guard await settled(timeout: 300, { armed }) else {
            throw FixtureFailure("The operator did not verify and arm the uniquely identified fixture window. No physical Escape acceptance was attempted.")
        }
        guard escapeEnds == 0 else {
            throw FixtureFailure("Escape arrived before the fixture was armed; restart with no key input until Begin.")
        }
        readiness.removeFromSuperview()
        report.append("Operator armed the matching fixture before any Escape input.")
        print("SCRIV_PHYSICAL_ESCAPE_ARMED token=\(token)")
        let update = ScrivUpdateController()
        update.onClose = { closeCount += 1 }
        root.present(update, animated: false)
        guard await settled({ update.viewIfLoaded?.window != nil && !update.isBeingPresented && update.isFirstResponder }) else {
            throw FixtureFailure("The synthetic update sheet did not become ready for keyboard input.")
        }

        func prompt(_ step: Int, _ instruction: String) -> String {
            "Physical Escape check \(step)/8: \(instruction)\n\(fixtureTitle)\nSynthetic fixture only. Nothing can download or install."
        }
        func remainsPresented(_ step: String) {
            XCTAssertTrue(root.presentedViewController === update, step)
            XCTAssertFalse(update.isBeingDismissed, step)
            XCTAssertEqual(closeCount, 0, step)
        }
        func waitForEscape(_ step: String) async throws {
            guard window.isKeyWindow else { throw FixtureFailure("The synthetic window lost key focus before \(step).") }
            let before = escapeEnds
            print("SCRIV_PHYSICAL_ESCAPE_WAIT \(step)")
            guard await settled(timeout: 90, { escapeEnds > before }) else {
                throw FixtureFailure("No OS Escape release reached the application during \(step). Do not count this step as passed.")
            }
            // Observe after UIApplication forwarded the real event and UIKit
            // completed its command/dismissal work, not inside sendEvent.
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertTrue(window.isKeyWindow, "The OS key must target the synthetic fixture window.")
            XCTAssertEqual(escapeEnds, before + 1, "Send one Escape press per displayed step.")
            report.append("\(step): OS Escape observed; replies=\(replies.count), close=\(closeCount).")
        }

        update.render(["phase": "ready", "message": prompt(1, "Press Escape once to choose Later.")], reply: { replies.append($0) })
        try await waitForEscape("1 ready cancellation")
        XCTAssertEqual(replies, ["cancel"]); remainsPresented("ready cancellation waits for the synthetic plugin")

        let instruction = try XCTUnwrap(descendants(update.view).compactMap { $0 as? UILabel }.first {
            $0.text?.hasPrefix("Physical Escape check") == true
        })
        instruction.text = prompt(2, "Press Escape again. The consumed reply must not fire twice.")
        try await waitForEscape("2 repeated Escape")
        XCTAssertEqual(replies, ["cancel"]); remainsPresented("repeated Escape")

        update.render(["phase": "downloading", "message": prompt(3, "Press Escape to cancel after a progress event.")], reply: { replies.append($0) })
        update.render(["phase": "progress", "progress": 0.5], reply: nil)
        try await waitForEscape("3 downloading after progress")
        XCTAssertEqual(replies, ["cancel", "cancel"]); remainsPresented("downloading")

        for (step, phase) in [(4, "verifying"), (5, "saving"), (6, "installing")] {
            update.render(["phase": phase, "message": prompt(step, "Press Escape. This protected phase must stay open.")], reply: { replies.append($0) })
            try await waitForEscape("\(step) protected \(phase)")
            XCTAssertEqual(replies, ["cancel", "cancel"], phase); remainsPresented(phase)
        }

        update.render(["phase": "ready", "message": prompt(7, "A child alert owns Escape. The updater must not receive it.")], reply: { replies.append($0) })
        var alertCancels = 0
        let alert = UIAlertController(title: "Synthetic child alert \(token.prefix(8))", message: prompt(7, "Press Escape to cancel this alert only."), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel alert", style: .cancel) { _ in alertCancels += 1 })
        update.present(alert, animated: false)
        guard await settled({ alert.viewIfLoaded?.window != nil && !alert.isBeingPresented }) else {
            throw FixtureFailure("The synthetic child alert did not finish presenting.")
        }
        try await waitForEscape("7 child alert")
        guard await settled({ update.presentedViewController == nil }) else {
            throw FixtureFailure("Escape did not dismiss the synthetic child alert.")
        }
        XCTAssertEqual(alertCancels, 1)
        XCTAssertEqual(replies, ["cancel", "cancel"]); remainsPresented("child alert")

        // Do not manufacture focus restoration with becomeFirstResponder here:
        // the final OS key must use the responder state left by the real alert.
        let resumedInstruction = try XCTUnwrap(descendants(update.view).compactMap { $0 as? UILabel }.first {
            $0.text?.hasPrefix("Physical Escape check") == true
        })
        resumedInstruction.text = prompt(8, "Press Escape once more. The update sheet must receive it again.")
        try await waitForEscape("8 after child alert")
        XCTAssertEqual(replies, ["cancel", "cancel", "cancel"])
        remainsPresented("after child alert")
        XCTAssertEqual(escapeEnds, 8)
        report.append("All eight OS-input steps completed; XCTest assertions determine acceptance.")
        print("SCRIV_PHYSICAL_ESCAPE_COMPLETE releases=\(escapeEnds) cancelReplies=\(replies.count)")
    }

    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    private func settled(timeout: TimeInterval = 5, _ predicate: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }
    private struct FixtureFailure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
