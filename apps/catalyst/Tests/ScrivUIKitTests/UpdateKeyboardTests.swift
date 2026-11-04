import UIKit
import XCTest
@testable import ScrivUIKit

/// Executes the UIKit command and button handlers with synthetic updater
/// callbacks. Physical Escape delivery and Sparkle installation remain separate
/// native acceptance gates; this suite never downloads or installs an update.
@MainActor
final class UpdateKeyboardTests: XCTestCase {
    func testEscapeUsesTheVisibleSecondaryActionOnceAndWaitsForThePlugin() async throws {
        try await withUpdate { root, update in
            XCTAssertTrue(update.isFirstResponder, "The update sheet must receive keyboard commands")
            let command = try self.escapeCommand(in: update)
            let action = try XCTUnwrap(command.action)
            XCTAssertTrue(command.wantsPriorityOverSystemBehavior)
            XCTAssertEqual(command.modifierFlags, [])
            XCTAssertTrue(update.isModalInPresentation, "Keyboard support must not permit uncoordinated dismissal")
            var closed = 0
            update.onClose = { closed += 1 }
            for phase in ["checking", "available", "downloading", "ready", "retryQuit", "waitingToQuit"] {
                var replies: [String] = []
                update.render(["phase": phase], reply: { replies.append($0) })
                XCTAssertTrue(update.canPerformAction(action, withSender: command), phase)
                update.perform(action, with: command)
                XCTAssertEqual(replies, ["cancel"], phase)
                XCTAssertFalse(update.canPerformAction(action, withSender: command), phase)
                update.perform(action, with: command)
                XCTAssertEqual(replies, ["cancel"], "Repeated Escape cannot repeat the updater reply: \(phase)")
                XCTAssertTrue(root.presentedViewController === update, "Only the plugin may confirm cancellation: \(phase)")
                XCTAssertEqual(closed, 0)
            }
        }
    }

    func testEscapeCannotCancelHiddenActionsOrPhasesWithoutAReply() async throws {
        try await withUpdate { root, update in
            let command = try self.escapeCommand(in: update)
            let action = try XCTUnwrap(command.action)
            var replies: [String] = []
            for phase in ["verifying", "saving", "installing", "current", "complete", "blocked", "error", "retryBlocked"] {
                update.render(["phase": phase], reply: { replies.append($0) })
                XCTAssertFalse(update.canPerformAction(action, withSender: command), phase)
                update.perform(action, with: command)
                XCTAssertTrue(replies.isEmpty, phase)
                XCTAssertTrue(root.presentedViewController === update, phase)
            }
            for phase in ["checking", "available", "downloading", "ready", "retryQuit"] {
                update.render(["phase": phase], reply: nil)
                XCTAssertFalse(update.canPerformAction(action, withSender: command), phase)
                update.perform(action, with: command)
                XCTAssertTrue(root.presentedViewController === update, phase)
            }
        }
    }

    func testEscapeRechecksTheLatestPhaseRatherThanUsingAStaleCommand() async throws {
        try await withUpdate { _, update in
            var obsoleteReplies: [String] = [], currentReplies: [String] = []
            update.render(["phase": "available"], reply: { obsoleteReplies.append($0) })
            let command = try self.escapeCommand(in: update)
            let action = try XCTUnwrap(command.action)
            XCTAssertTrue(update.canPerformAction(action, withSender: command))
            update.render(["phase": "saving"], reply: nil)
            update.perform(action, with: command)
            XCTAssertTrue(obsoleteReplies.isEmpty)
            update.render(["phase": "ready"], reply: { currentReplies.append($0) })
            update.perform(action, with: command)
            XCTAssertTrue(obsoleteReplies.isEmpty)
            XCTAssertEqual(currentReplies, ["cancel"])
        }
    }

    func testSynchronousCancellationErrorStaysVisible() async throws {
        try await withUpdate { root, update in
            let command = try self.escapeCommand(in: update)
            let action = try XCTUnwrap(command.action)
            var closed = 0, replies: [String] = []
            update.onClose = { closed += 1 }
            for phase in ["error", "blocked"] {
                update.render(["phase": "ready"], reply: { choice in
                    replies.append(choice)
                    update.render(["phase": phase, "message": "Synthetic cancellation notice"], reply: nil)
                })
                update.perform(action, with: command)
                XCTAssertEqual(closed, 0, "A synchronous callback must not hide the new \(phase) notice")
                XCTAssertTrue(root.presentedViewController === update)
                XCTAssertFalse(update.isBeingDismissed)
                XCTAssertFalse(update.canPerformAction(action, withSender: command))
            }
            XCTAssertEqual(replies, ["cancel", "cancel"])
        }
    }

    func testProgressDoesNotLoseOrReenableTheCancellationReply() async throws {
        try await withUpdate { _, update in
            var replies: [String] = []
            update.render(["phase": "downloading"], reply: { replies.append($0) })
            let command = try self.escapeCommand(in: update)
            let action = try XCTUnwrap(command.action)
            update.render(["phase": "progress", "progress": 0.5], reply: nil)
            XCTAssertTrue(update.canPerformAction(action, withSender: command))
            update.perform(action, with: command)
            update.render(["phase": "progress", "progress": 0.75], reply: nil)
            XCTAssertFalse(update.canPerformAction(action, withSender: command))
            update.perform(action, with: command)
            XCTAssertEqual(replies, ["cancel"])
        }
    }

    func testEscapeCannotActAfterThePrimaryChoice() async throws {
        try await withUpdate { _, update in
            var replies: [String] = []
            update.render(["phase": "ready"], reply: { replies.append($0) })
            let command = try self.escapeCommand(in: update)
            let action = try XCTUnwrap(command.action)
            let primary = try XCTUnwrap(self.descendants(update.view).compactMap { $0 as? UIButton }.first {
                $0.accessibilityIdentifier == "scriv.update.primary"
            })
            primary.sendActions(for: .touchUpInside)
            XCTAssertEqual(replies, ["install"])
            XCTAssertFalse(update.canPerformAction(action, withSender: command))
            update.perform(action, with: command)
            XCTAssertEqual(replies, ["install"])
        }
    }

    func testEscapeDoesNotAffectAnUpdateBehindAnotherModal() async throws {
        try await withUpdate { _, update in
            var replies: [String] = []
            update.render(["phase": "ready"], reply: { replies.append($0) })
            let command = try self.escapeCommand(in: update)
            let action = try XCTUnwrap(command.action)
            let descendant = UIViewController()
            update.present(descendant, animated: false)
            let appeared = await self.settled { descendant.viewIfLoaded?.window != nil && !descendant.isBeingPresented }
            XCTAssertTrue(appeared)
            XCTAssertFalse(update.canPerformAction(action, withSender: command))
            update.perform(action, with: command)
            XCTAssertTrue(replies.isEmpty)
            XCTAssertTrue(update.presentedViewController === descendant)
            descendant.dismiss(animated: false)
            let dismissed = await self.settled { update.presentedViewController == nil }
            XCTAssertTrue(dismissed)
            XCTAssertTrue(update.canPerformAction(action, withSender: command))
            update.perform(action, with: command)
            XCTAssertEqual(replies, ["cancel"])
        }
    }

    func testDetachedUpdateCannotReplyToEscape() throws {
        let update = ScrivUpdateController()
        var replies: [String] = []
        update.render(["phase": "ready"], reply: { replies.append($0) })
        let command = try escapeCommand(in: update)
        let action = try XCTUnwrap(command.action)
        XCTAssertFalse(update.canPerformAction(action, withSender: command))
        update.perform(action, with: command)
        XCTAssertTrue(replies.isEmpty)
    }

    private func escapeCommand(in update: ScrivUpdateController) throws -> UIKeyCommand {
        try XCTUnwrap(update.keyCommands?.first { $0.input == UIKeyCommand.inputEscape })
    }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    private func withUpdate(_ body: (UIViewController, ScrivUpdateController) async throws -> Void) async throws {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let previous = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
        let scene = try XCTUnwrap(previous?.windowScene ?? scenes.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1000, height: 900)
        let root = UIViewController()
        window.rootViewController = root; window.makeKeyAndVisible()
        defer { root.dismiss(animated: false); window.isHidden = true; previous?.makeKey() }
        let attached = await settled { root.viewIfLoaded?.window != nil && window.isKeyWindow }
        guard attached else { XCTFail("Update fixture did not attach to a key window"); return }
        let update = ScrivUpdateController()
        root.present(update, animated: false)
        let appeared = await settled { update.viewIfLoaded?.window != nil && !update.isBeingPresented && update.isFirstResponder }
        guard appeared else { XCTFail("Update fixture did not finish presentation with keyboard focus"); return }
        try await body(root, update)
    }
    private func settled(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }
}
