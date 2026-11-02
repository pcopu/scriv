import UIKit
import XCTest
import ScrivCore
@testable import ScrivUIKit

/// A single word that wraps ("16:9" drawn as "1 / 6: / 9", "Previe / w") means its
/// row ran out of room. Lays the real workspace out at the supported window
/// sizes on every tab, with and without Discussion, and reports every visible
/// one-word label that was broken across lines.
@MainActor
final class LayoutWrapTests: XCTestCase {
    private func views<T: UIView>(_ type: T.Type, in root: UIView) -> [T] {
        var result: [T] = [], pending = [root]
        while let view = pending.popLast() { if let match = view as? T { result.append(match) }; pending.append(contentsOf: view.subviews) }
        return result
    }
    private func isVisible(_ view: UIView, in window: UIWindow) -> Bool {
        var current: UIView? = view
        while let node = current { if node.isHidden || node.alpha < 0.01 { return false }; current = node.superview }
        let frame = view.convert(view.bounds, to: window)
        return frame.width > 1 && frame.height > 1 && window.bounds.intersects(frame)
    }
    private func path(_ view: UIView) -> String {
        var names: [String] = [], current: UIView? = view.superview
        while let node = current, names.count < 4 { names.append(String(describing: type(of: node))); current = node.superview }
        return names.joined(separator: " < ")
    }

    func testNoSingleWordWrapsAtSupportedWindowSizes() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--screenshots") else { throw XCTSkip("Requires isolated verification storage.") }
        let store = WorkspaceStore()
        while store.isBootstrapping { await Task.yield() }
        let package = try XCTUnwrap(store.projectURL)
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent().deletingLastPathComponent()) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.overrideUserInterfaceStyle = .light
        let workspace = ScrivWorkspaceController(store: store)
        window.rootViewController = workspace; window.makeKeyAndVisible()
        defer { window.isHidden = true; store.showDiscussion = false }
        var offenders: Set<String> = []
        for size in [CGSize(width: 1080, height: 720), CGSize(width: 1440, height: 900)] {
            window.frame = CGRect(origin: .zero, size: size)
            for discussion in [false, true] {
                store.showDiscussion = discussion
                for tab in WorkspaceTab.allCases {
                    store.tab = tab
                    // Let queued store refreshes and layout settle.
                    for _ in 0..<6 { try await Task.sleep(for: .milliseconds(30)); window.layoutIfNeeded() }
                    for label in views(UILabel.self, in: window) where isVisible(label, in: window) {
                        guard let text = label.text?.trimmingCharacters(in: .whitespacesAndNewlines), text.count >= 2,
                              !text.contains(where: { $0.isWhitespace }), label.numberOfLines != 1 else { continue }
                        let lineHeight = label.font.lineHeight
                        if wrapped(label) {
                            offenders.insert("\(Int(size.width))x\(Int(size.height)) \(tab)\(discussion ? "+discussion" : ""): \"\(text)\" is \(Int(label.bounds.width))pt wide, \(Int(label.bounds.height / lineHeight)) lines — \(path(label))")
                        }
                    }
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty, "Single words wrapped:\n" + offenders.sorted().joined(separator: "\n"))
    }

    /// Every sheet, opened on the smallest window: no single word wraps and no
    /// control is cut off by the window or the sheet's own edges.
    func testSheetsFitTheSmallestWindow() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--screenshots") else { throw XCTSkip("Requires isolated verification storage.") }
        let store = WorkspaceStore()
        while store.isBootstrapping { await Task.yield() }
        let package = try XCTUnwrap(store.projectURL)
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent().deletingLastPathComponent()) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.overrideUserInterfaceStyle = .light
        window.frame = CGRect(x: 0, y: 0, width: 1080, height: 720)
        let workspace = ScrivWorkspaceController(store: store)
        window.rootViewController = workspace; window.makeKeyAndVisible()
        defer { if workspace.presentedViewController != nil { workspace.dismiss(animated: false) }; window.isHidden = true }
        let entry = try XCTUnwrap(store.sceneEntries.first { $0.kind == .dialogue && !$0.words.isEmpty })
        let cue = try XCTUnwrap(store.sceneCues.first)
        let routes: [(String, ScrivUIKitRoute?)] = [("projects", .projects), ("history", .history), ("audio", .audio), ("teams", .teams), ("signIn", .signIn), ("account", .account), ("settings", .settings), ("generationJobs", .generationJobs), ("codex", .codex), ("wordTiming", .wordTiming(entryID: entry.id, wordIDs: [entry.words[0].id])), ("characterEditor", .characterEditor(characterID: nil)), ("characterLinks", .characterLinks(entryID: entry.id)), ("cueAnchor", .cueAnchor(cueID: cue.id)), ("layers", nil)]
        var problems: [String] = []
        for (name, route) in routes {
            if let route { ScrivUIKitRouter.shared.present(route, from: workspace, store: store) }
            else { let layers = LayerTimelineViewController(store: store, expanded: true); ImageUI.closeButton(layers); ImageUI.present(layers, from: workspace, size: CGSize(width: 1100, height: 570)) }
            var sheet: UIViewController?
            for _ in 0..<150 { if let presented = workspace.presentedViewController, presented.viewIfLoaded?.window != nil, !presented.isBeingPresented { sheet = presented; break }; try await Task.sleep(for: .milliseconds(20)) }
            guard let sheet else { problems.append("\(name): did not open"); continue }
            for _ in 0..<5 { try await Task.sleep(for: .milliseconds(30)); window.layoutIfNeeded() }
            // The presentation container clips the sheet; a sheet laid out wider than it loses its edges.
            let clip = (sheet.view.superview ?? sheet.view).convert((sheet.view.superview ?? sheet.view).bounds, to: window).intersection(window.bounds)
            let sheetFrame = sheet.view.convert(sheet.view.bounds, to: window)
            if sheetFrame.width > clip.width + 1 || sheetFrame.height > clip.height + 1 { problems.append("\(name): sheet \(Int(sheetFrame.width))x\(Int(sheetFrame.height)) exceeds its visible area \(Int(clip.width))x\(Int(clip.height))") }
            for control in views(UIControl.self, in: sheet.view) where isVisible(control, in: window) && !(control.superview is UIScrollView) {
                if control is UISlider || control.bounds.width < 2 { continue }
                let frame = control.convert(control.bounds, to: window)
                if !clip.insetBy(dx: -1, dy: -1).contains(frame) && !isInsideScrollView(control) {
                    problems.append("\(name): \(type(of: control)) \"\((control as? UIButton)?.currentTitle ?? control.accessibilityLabel ?? "")\" at \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height)) is cut off (visible \(Int(clip.minX)),\(Int(clip.minY)) \(Int(clip.width))x\(Int(clip.height)))")
                }
            }
            for label in views(UILabel.self, in: sheet.view) where isVisible(label, in: window) {
                guard let text = label.text?.trimmingCharacters(in: .whitespacesAndNewlines), text.count >= 2, !text.contains(where: { $0.isWhitespace }), label.numberOfLines != 1 else { continue }
                if wrapped(label) { problems.append("\(name): \"\(text)\" wraps (\(Int(label.bounds.width))pt wide)") }
            }
            workspace.dismiss(animated: false)
            for _ in 0..<50 where workspace.presentedViewController != nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        XCTAssertTrue(problems.isEmpty, "Sheet layout problems at 1080x720:\n" + problems.joined(separator: "\n"))
    }
    /// VoiceOver reads an unlabelled icon button as just "button". Every visible
    /// button on every tab and sheet says what it does.
    func testEveryVisibleButtonHasALabel() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--screenshots") else { throw XCTSkip("Requires isolated verification storage.") }
        let store = WorkspaceStore()
        while store.isBootstrapping { await Task.yield() }
        let package = try XCTUnwrap(store.projectURL)
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent().deletingLastPathComponent()) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.overrideUserInterfaceStyle = .light
        window.frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let workspace = ScrivWorkspaceController(store: store)
        window.rootViewController = workspace; window.makeKeyAndVisible()
        defer { if workspace.presentedViewController != nil { workspace.dismiss(animated: false) }; window.isHidden = true; store.showDiscussion = false }
        var unlabelled: Set<String> = []
        func audit(_ root: UIView, _ place: String) {
            for button in views(UIButton.self, in: root) where isVisible(button, in: window) && button.isAccessibilityElement {
                let label = (button.accessibilityLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if label.isEmpty { unlabelled.insert("\(place): \(type(of: button)) image \(button.currentImage.map { String(describing: $0.description.prefix(60)) } ?? "none") — \(path(button))") }
            }
        }
        for discussion in [false, true] {
            store.showDiscussion = discussion
            for tab in WorkspaceTab.allCases {
                store.tab = tab
                for _ in 0..<6 { try await Task.sleep(for: .milliseconds(30)); window.layoutIfNeeded() }
                audit(window, "\(tab)\(discussion ? "+discussion" : "")")
            }
        }
        store.showDiscussion = false
        let routes: [(String, ScrivUIKitRoute)] = [("projects", .projects), ("history", .history), ("audio", .audio), ("teams", .teams), ("signIn", .signIn), ("account", .account), ("settings", .settings), ("generationJobs", .generationJobs), ("codex", .codex), ("characterEditor", .characterEditor(characterID: nil))]
        for (name, route) in routes {
            ScrivUIKitRouter.shared.present(route, from: workspace, store: store)
            var sheet: UIViewController?
            for _ in 0..<150 { if let presented = workspace.presentedViewController, presented.viewIfLoaded?.window != nil, !presented.isBeingPresented { sheet = presented; break }; try await Task.sleep(for: .milliseconds(20)) }
            guard let sheet else { unlabelled.insert("\(name): did not open"); continue }
            for _ in 0..<5 { try await Task.sleep(for: .milliseconds(30)); window.layoutIfNeeded() }
            audit(sheet.view, name)
            workspace.dismiss(animated: false)
            for _ in 0..<50 where workspace.presentedViewController != nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        XCTAssertTrue(unlabelled.isEmpty, "Buttons without an accessibility label:\n" + unlabelled.sorted().joined(separator: "\n"))
    }
    /// Lines the text actually takes at its current width (a fixed frame may be taller than its text).
    private func wrapped(_ label: UILabel) -> Bool {
        label.textRect(forBounds: CGRect(x: 0, y: 0, width: label.bounds.width, height: .greatestFiniteMagnitude), limitedToNumberOfLines: label.numberOfLines).height > label.font.lineHeight * 1.6
    }
    /// Controls scrolled out of a scroll view's viewport are reachable by scrolling.
    private func isInsideScrollView(_ view: UIView) -> Bool {
        var current = view.superview
        while let node = current { if let scroll = node as? UIScrollView, !(scroll is UITextView) { return true }; current = node.superview }
        return false
    }
}
