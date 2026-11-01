import XCTest
import UIKit
import ScrivCore
@testable import ScrivUIKit

/// These execute the real UIViewController and Auto Layout hierarchy on Catalyst.
/// The companion Node contracts are not a replacement for this native gate.
@MainActor final class GenerationBriefReviewTests: XCTestCase {
    func testControllerFirstLoadHasCommonAncestorsAndFixedChromeAcrossTabsAndSizes() throws {
        let controller = GenerationBriefReviewController(snapshot: try snapshotFixture())
        controller.loadViewIfNeeded()
        let review = try XCTUnwrap(controller.reviewView)
        XCTAssertEqual(controller.modalPresentationStyle, .formSheet)
        let preferred = controller.preferredContentSize
        XCTAssertEqual(preferred, GenerationReviewUI.preferredSize)
        XCTAssertTrue(review.superview === controller.view)
        XCTAssertTrue(review.body.superview === review.scroll)
        XCTAssertFalse(review.done.isDescendant(of: review.scroll))
        XCTAssertFalse(review.header.isDescendant(of: review.scroll))
        assertCommonAncestors(in: controller.view)

        for size in [CGSize(width: 720, height: 830), CGSize(width: 560, height: 650), CGSize(width: 360, height: 560)] {
            controller.view.frame = CGRect(origin: .zero, size: size)
            layout(controller.view)
            review.select(.source); layout(controller.view)
            let header = review.header.frame, footer = review.footer.frame, outer = review.frame
            let done = review.done.convert(review.done.bounds, to: review)
            XCTAssertGreaterThan(review.scroll.bounds.height, 0, "size=\(size)")
            XCTAssertGreaterThan(done.width, 100)
            XCTAssertGreaterThan(done.height, 30)
            XCTAssertGreaterThanOrEqual(done.minX, 0)
            XCTAssertLessThanOrEqual(done.maxX, review.bounds.width + 0.5)
            XCTAssertLessThanOrEqual(done.maxY, review.bounds.height + 0.5)
            XCTAssertLessThanOrEqual(review.scroll.frame.maxY, footer.minY + 0.5)
            XCTAssertGreaterThanOrEqual(review.scroll.frame.minY, header.maxY - 0.5)

            for tab in GenerationBriefReviewView.Tab.allCases {
                review.select(tab)
                if tab == .people { review.togglePerson("mara") }
                layout(controller.view)
                assertRect(review.frame, equals: outer)
                assertRect(review.header.frame, equals: header)
                assertRect(review.footer.frame, equals: footer)
                XCTAssertEqual(controller.preferredContentSize, preferred)
                XCTAssertTrue(review.done.isEnabled)
                assertCommonAncestors(in: controller.view)
                if tab == .exactRequest {
                    XCTAssertTrue(review.exactText.isScrollEnabled)
                    XCTAssertGreaterThan(review.exactText.bounds.height, 0, "Exact request must have a viewport at \(size)")
                } else {
                    let maximum = max(0, review.scroll.contentSize.height - review.scroll.bounds.height)
                    review.scroll.setContentOffset(CGPoint(x: 0, y: maximum), animated: false)
                    layout(controller.view)
                    assertRect(review.footer.frame, equals: footer)
                    assertRect(review.done.convert(review.done.bounds, to: review), equals: done)
                }
            }
        }
    }

    func testCompleteSourceProfileAndCanonicalRequestKeepExactUnicode() throws {
        let snapshot = try snapshotFixture()
        let controller = GenerationBriefReviewController(snapshot: snapshot)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 560, height: 650)
        let review = try XCTUnwrap(controller.reviewView)
        layout(controller.view)
        XCTAssertTrue(snapshot.exactBrief.utf16.elementsEqual(snapshot.context.prompt.utf16))
        XCTAssertTrue(snapshot.exactRequest.utf16.elementsEqual(GenerationPrompt.submitted(brief: snapshot.context.prompt).utf16))
        XCTAssertTrue(review.exactText.text.utf16.elementsEqual(snapshot.exactRequest.utf16))
        XCTAssertFalse(review.exactText.isEditable)
        XCTAssertTrue(review.exactText.isSelectable)
        XCTAssertTrue(review.exactText.isScrollEnabled)
        XCTAssertEqual(review.exactText.textContainer.maximumNumberOfLines, 0)

        let quote = try XCTUnwrap(descendants(review.body).compactMap { $0 as? UITextView }.first {
            $0.accessibilityIdentifier == "generation-source-direction"
        })
        XCTAssertTrue(quote.text.utf16.elementsEqual(sourceText.utf16))
        XCTAssertFalse(quote.isEditable)
        XCTAssertTrue(quote.isSelectable)
        XCTAssertEqual(quote.textContainer.maximumNumberOfLines, 0)
        review.select(.people)
        layout(controller.view)
        let person = try XCTUnwrap(snapshot.context.characters.first { $0.id == "mara" })
        let values = descendants(review.body).compactMap { ($0 as? UITextView)?.text }
        for expected in [person.appearance, person.biography, person.aliases.joined(separator: ", ")] {
            XCTAssertTrue(values.contains { $0.utf16.elementsEqual(expected.utf16) }, "Complete profile field must remain selectable below the fold")
        }
        XCTAssertGreaterThan(review.scroll.contentSize.height, review.scroll.bounds.height)
    }

    func testComposerPlaceholderNeverBecomesDirectionAndCommandsReflowInPlace() {
        let field = GenerationDirectionTextView(frame: CGRect(x: 0, y: 0, width: 320, height: 62), textContainer: nil)
        XCTAssertTrue(field.text.isEmpty)
        XCTAssertFalse(field.placeholderLabel.isHidden)
        field.text = "Keep the exact draft. 👩🏽‍🚀 cafe\u{301}"
        field.updatePlaceholder()
        XCTAssertTrue(field.placeholderLabel.isHidden)
        let review = GenerationReviewUI.button("Review brief…") {}, generate = GenerationReviewUI.button("Generate image", primary: true) {}
        let actions = GenerationComposerActionRow(review: review, generate: generate)
        for width in [CGFloat(312), 620, 312] {
            actions.frame = CGRect(x: 0, y: 0, width: width, height: width < 350 ? 110 : 48)
            layout(actions)
            XCTAssertEqual(actions.axis, width < 350 ? .vertical : .horizontal)
            XCTAssertTrue(actions.arrangedSubviews.first === review)
            XCTAssertTrue(actions.arrangedSubviews.last === generate)
            XCTAssertEqual(generate.titleLabel?.numberOfLines, 1)
            XCTAssertGreaterThanOrEqual(generate.frame.width + 0.5, generate.intrinsicContentSize.width)
            XCTAssertEqual(field.text, "Keep the exact draft. 👩🏽‍🚀 cafe\u{301}")
        }
        field.text = ""; field.updatePlaceholder()
        XCTAssertFalse(field.placeholderLabel.isHidden)
        XCTAssertTrue(field.text.isEmpty)
    }

    func testLayersDisclosureRemainsNamedAndReflectsRealExpandedState() {
        var activations = 0
        let disclosure = PreviewLayersDisclosureView { activations += 1 }
        disclosure.frame = CGRect(x: 0, y: 0, width: 320, height: 44)
        disclosure.update(expanded: false, duration: "8.0 s"); layout(disclosure)
        XCTAssertEqual(disclosure.button.configuration?.title, "Layers")
        XCTAssertEqual(disclosure.button.accessibilityValue, "Collapsed")
        disclosure.button.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(activations, 1)
        disclosure.update(expanded: true, duration: "8.0 s")
        XCTAssertEqual(disclosure.button.accessibilityValue, "Expanded")
        XCTAssertEqual(disclosure.button.accessibilityLabel, "Collapse Layers")
    }

    func testSelectedGenerationTargetIsExplicitWhenPlaybackShowsAnotherPicture() throws {
        let snapshot = try snapshotFixture()
        let playing = ImageCue(id: "other", sceneId: "scene", label: "02B", startMs: 8000, endMs: 16000)
        let mismatch = snapshot.composerTarget(isPlaying: true, playingCue: playing)
        XCTAssertTrue(mismatch.contains("Target: 01A"))
        XCTAssertTrue(mismatch.contains("Preview follows 02B"))
        XCTAssertTrue(mismatch.contains("Review and Generate still use 01A"))
        XCTAssertEqual(snapshot.context.cueID, "cue", "Presentation may not retarget the request to playback")
        XCTAssertEqual(snapshot.composerTarget(isPlaying: false, playingCue: playing), snapshot.summary)
    }

    func testPreloadedTimelineKeepsItsHeightAndIdentityAcrossRepeatedDisclosure() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--screenshots") else { throw XCTSkip("Requires isolated verification mode; never construct a live user workspace in this test.") }
        let store = WorkspaceStore()
        while store.isBootstrapping { await Task.yield() }
        let package = try XCTUnwrap(store.projectURL)
        let temporaryRoot = package.deletingLastPathComponent().deletingLastPathComponent()
        defer {
            // Never delete a caller-supplied verification root shared with other
            // tests or an interactive capture. Only clean this store's own temp root.
            if ProcessInfo.processInfo.environment["SCRIV_VERIFICATION_ROOT"] == nil,
               temporaryRoot.lastPathComponent.hasPrefix("ScrivVerification-"),
               temporaryRoot.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL {
                try? FileManager.default.removeItem(at: temporaryRoot)
            }
        }
        let project = store.project
        let controller = PreviewViewController(store: store); controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 620, height: 840)
        layout(controller.view)
        let inspect = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UIButton }.first { $0.accessibilityLabel == "Inspect original image" })
        try assertPreviewCommand(inspect, title: "Inspect")
        let timeline = try XCTUnwrap(controller.children.compactMap { $0 as? LayerTimelineViewController }.first)
        timeline.loadViewIfNeeded() // Loading is independent of expanding.
        let originalView = try XCTUnwrap(timeline.view)
        XCTAssertFalse(controller.layersExpanded)
        for _ in 0..<2 {
            controller.setLayersExpanded(true); layout(controller.view)
            XCTAssertTrue(timeline.view === originalView)
            XCTAssertTrue(originalView.isDescendant(of: controller.view))
            XCTAssertEqual(originalView.frame.height, 276, accuracy: 0.5)
            controller.setLayersExpanded(false); layout(controller.view)
            XCTAssertFalse(originalView.isDescendant(of: controller.view))
            XCTAssertTrue(timeline.parent === controller)
        }
        XCTAssertEqual(store.project, project, "Disclosure must not change source, timing, tags or image data")
    }

    func testCopyUsesCapturedCompleteRequestAndInvalidationCannotCopyOrReopenContent() throws {
        let snapshot = try snapshotFixture()
        var copies: [String] = [], closes = 0
        let review = GenerationBriefReviewView(snapshot: snapshot, onClose: { closes += 1 }, onCopy: { copies.append($0) })
        review.frame = CGRect(x: 0, y: 0, width: 720, height: 830)
        review.select(.exactRequest); review.layoutIfNeeded()
        let copy = try XCTUnwrap(descendants(review).compactMap { $0 as? UIButton }.first {
            $0.accessibilityIdentifier == "generation-copy-full-request"
        })
        copy.sendActions(for: .primaryActionTriggered)
        copy.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(copies.count, 2)
        XCTAssertTrue(copies.allSatisfy { $0.utf16.elementsEqual(snapshot.exactRequest.utf16) })
        review.invalidate()
        XCTAssertFalse(review.isValid)
        XCTAssertFalse(review.tabs.isEnabled)
        XCTAssertTrue(review.body.arrangedSubviews.isEmpty)
        XCTAssertTrue((review.exactText.text ?? "").isEmpty)
        XCTAssertTrue(isEffectivelyHidden(copy))
        copy.sendActions(for: .primaryActionTriggered)
        review.select(.people); review.togglePerson("mara")
        XCTAssertEqual(copies.count, 2, "Stale UI actions may not expose another request")
        XCTAssertTrue(review.body.arrangedSubviews.isEmpty)
        review.done.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(closes, 1)
        XCTAssertEqual(copies.count, 2, "Done only closes; it never copies or generates")
    }

    func testPortraitOrderUsesFilteredCoreSnapshotWithByteDeduplicationAndFiveInputLimit() throws {
        let people = [
            ScriptCharacter(id: "mara", name: "Mara", portraitImageId: "p1"),
            ScriptCharacter(id: "mae", name: "Mae", portraitImageId: "p2"),
            ScriptCharacter(id: "missing", name: "Missing", portraitImageId: "missing-portrait"),
            ScriptCharacter(id: "june", name: "June", portraitImageId: "p3"),
            ScriptCharacter(id: "four", name: "Four", portraitImageId: "p4"),
            ScriptCharacter(id: "five", name: "Five", portraitImageId: "p5"),
            ScriptCharacter(id: "six", name: "Six", portraitImageId: "p6"),
            ScriptCharacter(id: "overflow", name: "Overflow", portraitImageId: "p7")
        ]
        let ids = ["p1", "p2", "missing-portrait", "p3", "p4", "p5", "p6", "p7"]
        let portraits = ids.map { id in ImageAsset(id: id, fileName: id + ".png", sha256: id == "p2" ? "p1" : id, byteCount: 1) }
        let picture = ImageAsset(id: "picture", fileName: "picture.png", sha256: "picture", byteCount: 1, characterIds: people.map(\.id))
        let project = ScrivProject(scenes: [ScriptScene(id: "scene")], characters: people, images: portraits + [picture], cues: [ImageCue(id: "cue", sceneId: "scene", imageId: "picture", startMs: 0, endMs: 8000, prompt: "A quiet wide shot.")])
        let available = Set(ids.filter { $0 != "missing-portrait" })
        let context = try GenerationContext.build(project: project, cueID: "cue").selectingPortraits(availableAssetIDs: available)
        let urls = Dictionary(uniqueKeysWithValues: available.map { ($0, URL(fileURLWithPath: "/synthetic-test-only/" + $0 + ".png")) })
        let snapshot = GenerationBriefSnapshot(context: context, localPortraitURLs: urls)
        XCTAssertEqual(context.portraits.map(\.assetID), ["p1", "p3", "p4", "p5", "p6"])
        XCTAssertEqual(context.portraits.first?.characterIDs, ["mara", "mae"])
        XCTAssertEqual(snapshot.referenceNumber(for: "mara"), 1)
        XCTAssertEqual(snapshot.referenceNumber(for: "mae"), 1)
        XCTAssertEqual(snapshot.referenceNumber(for: "june"), 2)
        XCTAssertEqual(snapshot.attachedPortraitURL(for: "mae"), urls["p1"], "Deduped identity must use the actual shared first input, not its unused duplicate path")
        XCTAssertNil(snapshot.referenceNumber(for: "missing"))
        XCTAssertNil(snapshot.attachedPortraitURL(for: "missing"))
        XCTAssertTrue(snapshot.portraitStatus(for: people[2]).contains("no local portrait"))
        XCTAssertNil(snapshot.attachedPortraitURL(for: "overflow"))
        XCTAssertTrue(snapshot.portraitStatus(for: people[7]).contains("five-input limit"))
        XCTAssertEqual(snapshot.reasons(for: "june"), ["Tagged in the current picture"])
    }

    func testManualOnlyCueRemainsGeneratableAndExplicitBlankDoesNotFallBackToSavedDirection() throws {
        let cue = ImageCue(id: "cue", sceneId: "scene", startMs: 0, endMs: 8000, prompt: "Saved direction that must not leak into a cleared override.")
        let project = ScrivProject(scenes: [ScriptScene(id: "scene")], cues: [cue])
        let manual = try GenerationContext.build(project: project, cueID: "cue", userDirection: "Only a close-up of the blue gate.")
        XCTAssertTrue(manual.passages.isEmpty)
        XCTAssertTrue(manual.hasContent)
        let cleared = try GenerationContext.build(project: project, cueID: "cue", userDirection: "")
        XCTAssertTrue(cleared.userDirection.isEmpty)
        XCTAssertFalse(cleared.hasContent)
        XCTAssertFalse(cleared.prompt.contains(cue.prompt))
        XCTAssertEqual(GenerationBriefSnapshot(context: manual, localPortraitURLs: [:]).context, manual)
    }

    func testPersonHeaderKeepsPillAdjacentToShortNameAndReflowsLongUnicodeName() throws {
        let person = ScriptCharacter(id: "short-name", name: "Mara")
        let snapshot = try snapshotForPerson(person)
        let header = GenerationReviewUI.personHeader(person, snapshot: snapshot, symbol: "chevron.up") {}
        fitHeader(header, width: 560)
        let name = try XCTUnwrap(descendants(header).compactMap { $0 as? UILabel }.first {
            $0.accessibilityIdentifier == "generation-person-name-" + person.id
        })
        let reference = try XCTUnwrap(descendants(header).compactMap { $0 as? UILabel }.first {
            $0.accessibilityIdentifier == "generation-person-reference-" + person.id
        })
        let nameFrame = name.convert(name.bounds, to: header), badgeFrame = reference.convert(reference.bounds, to: header)
        XCTAssertEqual(name.text, person.name)
        XCTAssertLessThanOrEqual(nameFrame.width, name.intrinsicContentSize.width + 0.5, "The name must hug its text rather than stretch the pill to the far edge")
        XCTAssertGreaterThanOrEqual(badgeFrame.minX - nameFrame.maxX, 5)
        XCTAssertLessThanOrEqual(badgeFrame.minX - nameFrame.maxX, 24)
        XCTAssertFalse(nameFrame.intersects(badgeFrame))

        let long = ScriptCharacter(id: "long-name", name: "Mara cafe\u{301} 👩🏽‍🚀 — " + String(repeating: "Very long exact identity 日本語 ", count: 5))
        let longHeader = GenerationReviewUI.personHeader(long, snapshot: try snapshotForPerson(long), symbol: "chevron.down") {}
        for width in [CGFloat(180), 560, 180] {
            fitHeader(longHeader, width: width)
            let longName = try XCTUnwrap(descendants(longHeader).compactMap { $0 as? UILabel }.first {
                $0.accessibilityIdentifier == "generation-person-name-" + long.id
            })
            let marker = try XCTUnwrap(descendants(longHeader).compactMap { $0 as? UILabel }.first {
                $0.accessibilityIdentifier == "generation-person-reference-" + long.id
            })
            let frame = longName.convert(longName.bounds, to: longHeader), markerFrame = marker.convert(marker.bounds, to: longHeader)
            XCTAssertTrue((longName.text ?? "").utf16.elementsEqual(long.name.utf16))
            XCTAssertEqual(longName.numberOfLines, 0)
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertGreaterThanOrEqual(frame.minX, 0)
            XCTAssertLessThanOrEqual(frame.maxX, width + 0.5)
            XCTAssertLessThanOrEqual(markerFrame.maxX, width + 0.5)
            XCTAssertFalse(frame.intersects(markerFrame))
            XCTAssertGreaterThanOrEqual(frame.height + 0.5, longName.sizeThatFits(CGSize(width: frame.width, height: CGFloat.greatestFiniteMagnitude)).height)
            if width == 180 { XCTAssertGreaterThanOrEqual(markerFrame.minY, frame.maxY - 0.5, "The full long identity and pill must reflow, not squeeze or overlap") }
            assertCommonAncestors(in: longHeader)
        }
    }

    func testCompactProfileGridHasContentDrivenHeightAndPreservesAllValues() throws {
        let compact = ScriptCharacter(id: "compact-person", name: "Mara", aliases: ["Mae"], biography: "Works at the garden.", appearance: "Dark curly hair. Blue work jacket.")
        for snapshot in [try snapshotForPerson(compact), try snapshotFixture()] {
            let person = try XCTUnwrap(snapshot.context.characters.first)
            let controller = GenerationBriefReviewController(snapshot: snapshot)
            controller.loadViewIfNeeded()
            let review = try XCTUnwrap(controller.reviewView)
            review.select(.people)
            let grid = try XCTUnwrap(descendants(review.body).first { $0.accessibilityIdentifier == "generation-profile-grid-" + person.id })
            let rows = try XCTUnwrap(grid as? UIStackView)
            XCTAssertEqual(rows.spacing, 0)
            XCTAssertEqual(rows.arrangedSubviews.count, 5, "Three content-sized profile rows are separated by two rules")
            var gridHeights: [CGFloat] = []
            // UIKit can install content-size/autoresizing height equalities on
            // UITextView. Their shape is not evidence of an application-imposed
            // height cap. Exercise the same real views across resize and assert
            // complete text fits and remains reachable in the outer scroller.
            for width in [CGFloat(560), 360, 560] {
                controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 650)
                review.scroll.setContentOffset(.zero, animated: false)
                settleProfileLayout(controller.view)
                let footer = review.footer.frame
                var frames: [CGRect] = []
                for expected in [person.aliases.joined(separator: ", "), person.appearance, person.biography] {
                    let value = try XCTUnwrap(descendants(grid).compactMap { $0 as? UITextView }.first { ($0.text ?? "").utf16.elementsEqual(expected.utf16) })
                    XCTAssertFalse(value.isEditable)
                    XCTAssertTrue(value.isSelectable)
                    XCTAssertFalse(value.isScrollEnabled)
                    XCTAssertEqual(value.textContainer.maximumNumberOfLines, 0)
                    XCTAssertGreaterThan(value.bounds.width, 0)
                    let fitting = value.sizeThatFits(CGSize(width: value.bounds.width, height: CGFloat.greatestFiniteMagnitude))
                    XCTAssertGreaterThan(fitting.height, 0)
                    XCTAssertGreaterThanOrEqual(value.bounds.height + 0.5, fitting.height, "Full profile value must fit without an inner scroll or clipped final lines at width \(width)")
                    let frame = value.convert(value.bounds, to: grid)
                    XCTAssertGreaterThanOrEqual(frame.minY, -0.5)
                    XCTAssertLessThanOrEqual(frame.maxY, grid.bounds.height + 0.5)
                    frames.append(frame)
                }
                if person.id == compact.id {
                    for (previous, next) in zip(frames, frames.dropFirst()) {
                        XCTAssertGreaterThanOrEqual(next.minY - previous.maxY, 0)
                        XCTAssertLessThanOrEqual(next.minY - previous.maxY, 14, "Short profile values should form one compact ruled grid, not three separated cards")
                    }
                }
                gridHeights.append(grid.bounds.height)
                XCTAssertGreaterThan(review.scroll.bounds.height, 0)
                let gridInScroll = grid.convert(grid.bounds, to: review.scroll)
                XCTAssertLessThanOrEqual(gridInScroll.maxY, review.scroll.contentSize.height + 0.5, "Full profile must contribute to the outer scroll extent")
                // Ask the real scroller to reveal the final line, rather than
                // calculating a minimum offset from a possibly intermediate
                // resize pass. The name/badge row changes axis during layout,
                // and UIKit's automatic insets also belong to the scroll range.
                let finalLine = CGRect(x: 0, y: max(0, grid.bounds.height - 22), width: grid.bounds.width, height: min(22, grid.bounds.height))
                review.scroll.scrollRectToVisible(grid.convert(finalLine, to: review.scroll), animated: false)
                settleProfileLayout(controller.view)
                let visibleLine = grid.convert(finalLine, to: review)
                XCTAssertLessThanOrEqual(grid.convert(grid.bounds, to: review).maxY, review.scroll.frame.maxY + 0.5, "The complete profile bottom must remain reachable after settled scroll layout")
                XCTAssertGreaterThanOrEqual(visibleLine.minY, review.scroll.frame.minY - 0.5, "The profile's final line must actually be in the viewport, not scrolled past its top")
                XCTAssertLessThanOrEqual(visibleLine.maxY, review.scroll.frame.maxY + 0.5, "The profile's final line must be reachable by scrolling")
                let minimumOffset = -review.scroll.adjustedContentInset.top
                let maximumOffset = max(minimumOffset, review.scroll.contentSize.height - review.scroll.bounds.height + review.scroll.adjustedContentInset.bottom)
                XCTAssertGreaterThanOrEqual(review.scroll.contentOffset.y, minimumOffset - 0.5)
                XCTAssertLessThanOrEqual(review.scroll.contentOffset.y, maximumOffset + 0.5, "Reachability must not depend on overscrolling beyond the content")
                print("SCRIV_PROFILE_SCROLL person=\(person.id) width=\(width) grid=\(gridInScroll) line=\(visibleLine) viewport=\(review.scroll.frame) offset=\(review.scroll.contentOffset) content=\(review.scroll.contentSize) insets=\(review.scroll.adjustedContentInset)")
                assertRect(review.footer.frame, equals: footer)
                assertCommonAncestors(in: controller.view)
            }
            XCTAssertEqual(gridHeights[0], gridHeights[2], accuracy: 0.5, "Returning to the original width must restore content-driven height")
            if person.id != compact.id {
                XCTAssertGreaterThan(gridHeights[1], gridHeights[0], "Long Unicode profile values must grow at narrow width instead of clipping to the initial height")
            }
        }
    }

    func testExpandedAndCollapsedPeopleCardsMeasureTheirActualContent() throws {
        let sample = ScrivProject.example()
        let cue = try XCTUnwrap(sample.cues.first { $0.label == "01A" })
        let sampleSnapshot = GenerationBriefSnapshot(context: try GenerationContext.build(project: sample, cueID: cue.id).selectingPortraits(availableAssetIDs: []), localPortraitURLs: [:])
        XCTAssertEqual(sampleSnapshot.context.characters.first?.name, "Randy")
        let mara = ScriptCharacter(id: "measure-mara", name: "Mara", aliases: ["Mae"], biography: "Works at the garden.", appearance: "Dark curly hair. Blue work jacket.")
        for snapshot in [sampleSnapshot, try snapshotForPerson(mara)] {
            let person = try XCTUnwrap(snapshot.context.characters.first)
            for size in [CGSize(width: 560, height: 650), CGSize(width: 360, height: 560)] {
                let controller = GenerationBriefReviewController(snapshot: snapshot)
                controller.loadViewIfNeeded(); controller.view.frame = CGRect(origin: .zero, size: size)
                let review = try XCTUnwrap(controller.reviewView)
                review.select(.people); layout(controller.view)
                let card = try XCTUnwrap(review.body.arrangedSubviews.first { card in descendants(card).contains { $0.accessibilityIdentifier == "generation-person-" + person.id } })
                let grid = try XCTUnwrap(descendants(card).first { $0.accessibilityIdentifier == "generation-profile-grid-" + person.id })
                let expanded = card.bounds, profile = grid.bounds, footer = review.footer.frame
                let values = descendants(grid).compactMap { ($0 as? UITextView)?.text }
                for fact in [person.appearance, person.biography] {
                    XCTAssertTrue(values.contains { $0.utf16.elementsEqual(fact.utf16) })
                }
                review.togglePerson(person.id); layout(controller.view)
                let collapsed = try XCTUnwrap(review.body.arrangedSubviews.first { card in descendants(card).contains { $0.accessibilityIdentifier == "generation-person-" + person.id } })
                XCTAssertGreaterThan(expanded.height, collapsed.bounds.height)
                XCTAssertFalse(descendants(collapsed).contains { $0.accessibilityIdentifier == "generation-profile-grid-" + person.id })
                assertRect(review.footer.frame, equals: footer)
                print("SCRIV_PEOPLE_CARD_LAYOUT name=\(person.name) sheet=\(size) expanded=\(expanded) profile=\(profile) collapsed=\(collapsed.bounds)")
            }
        }
    }

    func testDistinctCueDirectionsStayScopedThroughSelectionEditingAndExplicitClear() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--screenshots") else { throw XCTSkip("Requires isolated verification mode; never construct or edit a live user workspace in this test.") }
        let store = WorkspaceStore()
        while store.isBootstrapping { await Task.yield() }
        let package = try XCTUnwrap(store.projectURL)
        let temporaryRoot = package.deletingLastPathComponent().deletingLastPathComponent()
        defer {
            // Caller-supplied capture/test roots are never deleted. This cleanup
            // only owns the unique root allocated by this verification Store.
            if ProcessInfo.processInfo.environment["SCRIV_VERIFICATION_ROOT"] == nil,
               temporaryRoot.lastPathComponent.hasPrefix("ScrivVerification-"),
               temporaryRoot.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL {
                try? FileManager.default.removeItem(at: temporaryRoot)
            }
        }
        XCTAssertNil(store.project.cloudProjectId)
        let a = try XCTUnwrap(store.sceneCues.first), b = try XCTUnwrap(store.sceneCues.dropFirst().first)
        let directionA = "ONLY A: close-up of a blue gate — cafe\u{301}."
        let directionB = "ONLY B: wide view of a red barn — 日本語."
        // The bundled sample intentionally repeats directions. Seed two distinct
        // overrides via the real durable Store API, not by changing SampleProject.
        store.updateCuePrompt(a.id, prompt: directionA)
        store.updateCuePrompt(b.id, prompt: directionB)
        await store.flushPendingSaves()
        store.selectedCueID = a.id
        let panel = GenerationPanelViewController(store: store)
        panel.loadViewIfNeeded(); await store.prepareGenerationPromptForPresentation()?.value; panel.storeDidChange()
        let field = try XCTUnwrap(descendants(panel.view).compactMap { $0 as? UITextView }.first { $0.accessibilityIdentifier == "generation-optional-direction" })
        let scopeA = store.generationPromptScopeKey
        XCTAssertNotEqual(scopeA, "no-cue")
        XCTAssertEqual(field.text, directionA)
        let reviewA = GenerationBriefReviewController(store: store, context: try XCTUnwrap(store.selectedImageGenerationContext))
        reviewA.loadViewIfNeeded()
        XCTAssertEqual(reviewA.snapshot.context.cueID, a.id)
        XCTAssertEqual(reviewA.snapshot.context.userDirection, directionA)

        panel.textViewDidBeginEditing(field)
        store.selectedCueID = b.id
        XCTAssertFalse(panel.textView(field, shouldChangeTextIn: NSRange(location: 0, length: (field.text ?? "").utf16.count), replacementText: "STALE A EDIT MUST NOT REPLACE B"))
        XCTAssertEqual(store.generationPrompt, directionB, "An edit whose responder began on A must be rejected after selection changes to B")
        XCTAssertEqual(store.project.cues.first { $0.id == a.id }?.prompt, directionA)
        panel.storeDidChange(); await store.prepareGenerationPromptForPresentation()?.value; panel.storeDidChange(); reviewA.storeDidChange()
        let scopeB = store.generationPromptScopeKey
        XCTAssertNotEqual(scopeB, scopeA)
        XCTAssertEqual(field.text, directionB)
        XCTAssertEqual(store.selectedImageGenerationContext?.cueID, b.id)
        XCTAssertEqual(store.selectedImageGenerationContext?.userDirection, directionB)
        XCTAssertFalse(reviewA.reviewIsCurrent)
        XCTAssertFalse(reviewA.reviewView.isValid)
        XCTAssertEqual(reviewA.snapshot.context.userDirection, directionA, "An already-open review must never retarget to B")
        let reviewB = GenerationBriefReviewController(store: store, context: try XCTUnwrap(store.selectedImageGenerationContext))
        XCTAssertEqual(reviewB.snapshot.context.cueID, b.id)
        XCTAssertEqual(reviewB.snapshot.context.userDirection, directionB)

        store.selectedCueID = a.id; panel.storeDidChange(); await store.prepareGenerationPromptForPresentation()?.value; panel.storeDidChange()
        XCTAssertEqual(store.generationPromptScopeKey, scopeA)
        XCTAssertEqual(field.text, directionA)
        XCTAssertEqual(store.selectedImageGenerationContext?.cueID, a.id)
        let editedA = "ONLY A EDITED: keep the gate small, with 👩🏽‍🚀 in the foreground."
        try replaceDirection(editedA, in: field, using: panel)
        await store.flushPendingSaves(); panel.storeDidChange()
        XCTAssertEqual(field.text, editedA)
        XCTAssertEqual(store.selectedImageGenerationContext?.userDirection, editedA)
        XCTAssertEqual(store.project.cues.first { $0.id == b.id }?.prompt, directionB)
        XCTAssertEqual(reviewB.snapshot.context.userDirection, directionB)

        try replaceDirection("", in: field, using: panel)
        await store.flushPendingSaves(); panel.storeDidChange()
        XCTAssertEqual(field.text, "")
        XCTAssertEqual(store.selectedImageGenerationContext?.userDirection, "")
        XCTAssertEqual(store.project.cues.first { $0.id == a.id }?.prompt, "")
        XCTAssertEqual(store.project.cues.first { $0.id == b.id }?.prompt, directionB)
        store.selectedCueID = b.id; panel.storeDidChange(); await store.prepareGenerationPromptForPresentation()?.value; panel.storeDidChange()
        XCTAssertEqual(store.generationPromptScopeKey, scopeB)
        XCTAssertEqual(field.text, directionB)
        XCTAssertEqual(store.selectedImageGenerationContext?.userDirection, directionB)
        store.selectedCueID = a.id; panel.storeDidChange(); await store.prepareGenerationPromptForPresentation()?.value; panel.storeDidChange()
        XCTAssertEqual(store.generationPromptScopeKey, scopeA)
        XCTAssertTrue((field.text ?? "").isEmpty)
        let clearedReview = GenerationBriefReviewController(store: store, context: try XCTUnwrap(store.selectedImageGenerationContext))
        XCTAssertEqual(clearedReview.snapshot.context.cueID, a.id)
        XCTAssertTrue(clearedReview.snapshot.context.userDirection.isEmpty)
        await store.flushPendingSaves()
    }

    func testPreviewChromeCommandsKeepReadableTitlesSymbolsAndOriginalActions() throws {
        var inspections = 0, chosenVersions: [Int] = []
        let inspect = PreviewChromeUI.inspect { inspections += 1 }
        let versions = [1, 12, 123456].map { number in
            (number, PreviewChromeUI.version(number) { chosenVersions.append(number) })
        }
        for (title, button) in [("Inspect", inspect)] + versions.map({ ("Version \($0.0)", $0.1) }) {
            button.frame = CGRect(origin: .zero, size: button.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize))
            layout(button)
            try assertPreviewCommand(button, title: title)
            XCTAssertLessThanOrEqual(button.bounds.height, 36, "Preview chrome must remain a compact strip, not review-sheet command sizing")
            button.sendActions(for: .primaryActionTriggered)
        }
        XCTAssertEqual(inspect.accessibilityLabel, "Inspect original image")
        XCTAssertEqual(inspections, 1)
        XCTAssertEqual(chosenVersions, [1, 12, 123456])
        for (number, button) in versions {
            XCTAssertEqual(button.accessibilityLabel, "Image version \(number), choose another version")
            XCTAssertEqual(button.configuration?.imagePlacement, .trailing)
            let label = try XCTUnwrap(button.titleLabel), icon = try XCTUnwrap(button.imageView)
            XCTAssertGreaterThanOrEqual(icon.convert(icon.bounds, to: button).minX, label.convert(label.bounds, to: button).maxX, "The version chevron must actually render after its complete title")
        }
    }

    func testPreviewHeaderAndTaggedMetadataKeepCommandsVisibleAcrossCompactResize() throws {
        let unicodeName = "Mara cafe\u{301} 👩🏽‍🚀 — 日本語 " + String(repeating: "long identity ", count: 3)
        for number in [12, 123456] {
            let inspect = PreviewChromeUI.inspect {}
            let header = ImageUI.row([ImageUI.label("Preview", size: 30, weight: .semibold), ImageUI.spacer(), ImageUI.badge("16:9"), inspect])
            let tag = ImageUI.tag(unicodeName, color: .systemBlue, compact: true)
            let plus = ImageUI.button("", symbol: "plus") {}; ImageUI.compact(plus)
            let flow = ImageTagFlowView([tag, ImageUI.tag("Mae", color: .systemGreen, compact: true), plus])
            let version = PreviewChromeUI.version(number) {}
            let menu = ImageUI.button("", symbol: "ellipsis") {}; ImageUI.compact(menu)
            let metadata = ImageUI.row([flow, version, menu], spacing: 6)
            // Install both rows in a real constrained hierarchy like Preview's
            // content stack. Only the host has a fixed viewport; Auto Layout
            // must allocate each row's natural height, with no bottom cap or
            // manually fitted row heights that could mask a production defect.
            let host = UIView()
            let content = ImageUI.stack([header, metadata], spacing: 9)
            content.translatesAutoresizingMaskIntoConstraints = false; host.addSubview(content)
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: host.topAnchor, constant: 12),
                content.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 12),
                content.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -12)
            ])
            for width in [CGFloat(560), 360, 560] {
                host.frame = CGRect(x: 0, y: 0, width: width, height: 840)
                let context = "Preview width=\(width), version=\(number)"
                settlePreviewChrome(host, context: context)
                print("SCRIV_PREVIEW_METADATA \(context) row=\(metadata.bounds) flow=\(flow.frame) intrinsic=\(flow.intrinsicContentSize) chips=\(flow.subviews.map(\.frame))")
                try assertPreviewCommand(inspect, title: "Inspect")
                try assertPreviewCommand(version, title: "Version \(number)")
                for (button, row) in [(inspect, header), (version, metadata), (menu, metadata)] {
                    let frame = button.convert(button.bounds, to: row)
                    XCTAssertGreaterThanOrEqual(frame.minX, -0.5)
                    XCTAssertLessThanOrEqual(frame.maxX, row.bounds.width + 0.5)
                    XCTAssertGreaterThanOrEqual(frame.minY, -0.5)
                    XCTAssertLessThanOrEqual(frame.maxY, row.bounds.height + 0.5)
                    XCTAssertLessThanOrEqual(button.bounds.height, 36)
                }
                XCTAssertGreaterThan(flow.bounds.width, 0)
                XCTAssertLessThanOrEqual(flow.frame.maxX, version.frame.minX)
                XCTAssertLessThanOrEqual(version.frame.maxX, menu.frame.minX)
                let label = try XCTUnwrap(descendants(tag).compactMap { $0 as? UILabel }.first { $0.text == unicodeName })
                XCTAssertTrue((label.text ?? "").utf16.elementsEqual(unicodeName.utf16))
                XCTAssertGreaterThan(label.bounds.width, 0)
                XCTAssertGreaterThanOrEqual(label.bounds.height + 0.5, label.sizeThatFits(CGSize(width: label.bounds.width, height: CGFloat.greatestFiniteMagnitude)).height, "The long tag must wrap fully instead of borrowing command width or clipping")
                for chip in flow.subviews {
                    XCTAssertGreaterThanOrEqual(chip.frame.minX, -0.5)
                    XCTAssertLessThanOrEqual(chip.frame.maxX, flow.bounds.width + 0.5)
                    XCTAssertLessThanOrEqual(chip.frame.maxY, flow.bounds.height + 0.5, "\(context): chip \(chip.frame) must fit actual flow \(flow.bounds), intrinsic \(flow.intrinsicContentSize)")
                }
                assertCommonAncestors(in: host)
            }
        }
    }

    private func settlePreviewChrome(_ root: UIView, context: String, file: StaticString = #filePath, line: UInt = #line) {
        var previous: [CGRect] = []
        var stablePasses = 0
        for _ in 0..<12 {
            root.setNeedsLayout(); root.layoutIfNeeded()
            let geometry = descendants(root).flatMap { view -> [CGRect] in
                var values = [view.frame, view.bounds]
                if view is ImageTagFlowView { values.append(CGRect(origin: .zero, size: view.intrinsicContentSize)) }
                return values
            }
            stablePasses = geometry == previous ? stablePasses + 1 : 0
            if stablePasses == 2 { return }
            previous = geometry
        }
        XCTFail("\(context): constrained row and tag-flow geometry did not stabilize; do not accept intermediate or clipped layout", file: file, line: line)
    }

    private func assertPreviewCommand(_ button: UIButton, title: String, file: StaticString = #filePath, line: UInt = #line) throws {
        button.layoutIfNeeded()
        let label = try XCTUnwrap(button.titleLabel, file: file, line: line)
        let rendered = label.attributedText ?? NSAttributedString(string: label.text ?? "")
        let attributedFont = rendered.length > 0 ? rendered.attribute(.font, at: 0, effectiveRange: nil) as? UIFont : nil
        let font = try XCTUnwrap(attributedFont ?? label.font, file: file, line: line)
        XCTAssertEqual(rendered.string, title, file: file, line: line)
        XCTAssertEqual(font.pointSize, 15, accuracy: 0.1, file: file, line: line)
        XCTAssertFalse(label.adjustsFontSizeToFitWidth, file: file, line: line)
        XCTAssertNotNil(button.configuration?.image, file: file, line: line)
        XCTAssertNotNil(button.imageView?.image, file: file, line: line)
        XCTAssertGreaterThan(label.bounds.width, 0, file: file, line: line)
        XCTAssertGreaterThan(label.bounds.height, 0, file: file, line: line)
        let measured = NSMutableAttributedString(attributedString: rendered)
        measured.enumerateAttribute(.font, in: NSRange(location: 0, length: measured.length), options: []) { value, range, _ in
            if value == nil { measured.addAttribute(.font, value: font, range: range) }
        }
        let fullTitle = measured.boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        XCTAssertLessThanOrEqual(fullTitle.width, label.bounds.width + 0.5, "Complete short title must fit on one readable line", file: file, line: line)
        XCTAssertGreaterThanOrEqual(label.bounds.height + 0.5, label.sizeThatFits(CGSize(width: label.bounds.width, height: CGFloat.greatestFiniteMagnitude)).height, file: file, line: line)
        let frame = label.convert(label.bounds, to: button)
        XCTAssertGreaterThanOrEqual(frame.minX, -0.5, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, button.bounds.width + 0.5, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxY, button.bounds.height + 0.5, file: file, line: line)
    }

    private var sourceText: String { String(repeating: "Mara opens the blue gate — cafe\u{301}, 👩🏽‍🚀 and 日本語 stay verbatim.\n", count: 10) }
    private func snapshotFixture() throws -> GenerationBriefSnapshot {
        let person = ScriptCharacter(id: "mara", name: "Mara", aliases: ["Mae", "Ma\u{301}ra"], biography: String(repeating: "Keeps the garden ledger. Background only; never a new scene event. 👩🏽‍🚀\n", count: 8), appearance: String(repeating: "Dark curly hair, blue work jacket, cafe\u{301}-coloured buttons.\n", count: 5))
        let picture = ImageAsset(id: "picture", fileName: "picture.png", sha256: "picture", byteCount: 1, characterIds: [person.id])
        let project = ScrivProject(scenes: [ScriptScene(id: "scene", title: "INT. LOCATION — DAY")], entries: [ScriptEntry(id: "direction", sceneId: "scene", order: 0, kind: .direction, text: sourceText, ownedDurationMs: 8000, coverageDurationMs: 8000)], characters: [person], images: [picture], cues: [ImageCue(id: "cue", sceneId: "scene", imageId: "picture", label: "01A", startMs: 0, endMs: 8000)])
        let context = try GenerationContext.build(project: project, cueID: "cue", userDirection: "Keep Mara small against the open gate. 👩🏽‍🚀").selectingPortraits(availableAssetIDs: [])
        return GenerationBriefSnapshot(context: context, localPortraitURLs: [:])
    }
    private func snapshotForPerson(_ person: ScriptCharacter) throws -> GenerationBriefSnapshot {
        let picture = ImageAsset(id: "portrait-test-picture", fileName: "picture.png", sha256: "picture", byteCount: 1, characterIds: [person.id])
        let project = ScrivProject(scenes: [ScriptScene(id: "scene")], characters: [person], images: [picture], cues: [ImageCue(id: "cue", sceneId: "scene", imageId: picture.id, startMs: 0, endMs: 8000, prompt: "Wide shot.")])
        return GenerationBriefSnapshot(context: try GenerationContext.build(project: project, cueID: "cue").selectingPortraits(availableAssetIDs: []), localPortraitURLs: [:])
    }
    private func fitHeader(_ header: UIView, width: CGFloat) {
        header.frame = CGRect(x: 0, y: 0, width: width, height: 1000)
        layout(header)
        let size = header.systemLayoutSizeFitting(CGSize(width: width, height: UIView.layoutFittingCompressedSize.height), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        header.frame.size.height = max(1, size.height)
        layout(header)
    }
    private func replaceDirection(_ replacement: String, in field: UITextView, using panel: GenerationPanelViewController) throws {
        panel.textViewDidBeginEditing(field)
        let range = NSRange(location: 0, length: (field.text ?? "").utf16.count)
        let accepted = panel.textView(field, shouldChangeTextIn: range, replacementText: replacement)
        let value = try XCTUnwrap(accepted ? replacement : nil, "Durable journal must accept this synthetic edit before UIKit changes the field")
        field.text = value
        panel.textViewDidChange(field)
        panel.textViewDidEndEditing(field)
    }
    /// A resize can invalidate ancestor measurements from a descendant's
    /// layoutSubviews (notably the responsive person name/marker stack).
    /// Two no-op layoutIfNeeded calls are not a fixed-point guarantee. Require
    /// consecutive stable geometry before testing a scroll destination; fail
    /// explicitly if the hierarchy does not settle instead of masking reflow.
    private func settleProfileLayout(_ root: UIView, file: StaticString = #filePath, line: UInt = #line) {
        var previous: [CGRect] = []
        var stablePasses = 0
        for _ in 0..<12 {
            root.setNeedsLayout(); root.layoutIfNeeded()
            let geometry = descendants(root).flatMap { view -> [CGRect] in
                var values = [view.frame, view.bounds]
                if let scroll = view as? UIScrollView { values.append(CGRect(origin: .zero, size: scroll.contentSize)) }
                return values
            }
            stablePasses = geometry == previous ? stablePasses + 1 : 0
            if stablePasses == 2 { return }
            previous = geometry
        }
        XCTFail("Profile hierarchy did not settle after resize/scroll; do not measure an intermediate layout", file: file, line: line)
    }
    private func layout(_ view: UIView) { view.setNeedsLayout(); view.layoutIfNeeded(); view.layoutIfNeeded() }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    private func isEffectivelyHidden(_ view: UIView) -> Bool {
        var next: UIView? = view
        while let current = next { if current.isHidden { return true }; next = current.superview }
        return false
    }
    private func owner(_ item: Any?) -> UIView? {
        if let view = item as? UIView { return view }
        return (item as? UILayoutGuide)?.owningView
    }
    private func assertCommonAncestors(in root: UIView, file: StaticString = #filePath, line: UInt = #line) {
        for constraint in descendants(root).flatMap(\.constraints) where constraint.isActive {
            guard let first = owner(constraint.firstItem), let second = owner(constraint.secondItem) else { continue }
            var ancestor: UIView? = first
            var found = false
            while let candidate = ancestor {
                if candidate === second || second.isDescendant(of: candidate) { found = true; break }
                ancestor = candidate.superview
            }
            XCTAssertTrue(found, "Active constraint has no common ancestor: \(constraint)", file: file, line: line)
        }
    }
    private func assertRect(_ actual: CGRect, equals expected: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.5, file: file, line: line)
    }
}
