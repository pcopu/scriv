import XCTest
import UIKit
import ScrivCore
@testable import ScrivUIKit

/// Execute on Catalyst. Portable source contracts do not establish layout.
@MainActor final class GenerationPersonNavigationTests: XCTestCase {
    func testSourceReferenceRevealsLaterIdentityAndPreservesFixedChromeAndSnapshot() async throws {
        let snapshot = try fixture()
        for size in [CGSize(width: 720, height: 830), CGSize(width: 560, height: 650), CGSize(width: 360, height: 560)] {
            var copies = 0, closes = 0
            let review = GenerationBriefReviewView(snapshot: snapshot, onClose: { closes += 1 }, onCopy: { _ in copies += 1 })
            review.frame = CGRect(origin: .zero, size: size)
            settle(review)
            let header = review.header.frame, footer = review.footer.frame
            let sourceLink = try button("generation-source-person-person-7", in: review)
            sourceLink.sendActions(for: .primaryActionTriggered)
            await nextMainQueueTurn()
            settle(review)
            XCTAssertEqual(review.selectedTab, .people)
            let requested = try button("generation-person-person-7", in: review)
            XCTAssertEqual(requested.accessibilityValue, "Expanded")
            let frame = requested.convert(requested.bounds, to: review)
            XCTAssertGreaterThan(review.scroll.contentOffset.y, 0, "A later identity must not reopen at the first person's card")
            XCTAssertGreaterThanOrEqual(frame.minY, review.scroll.frame.minY - 0.5)
            XCTAssertLessThanOrEqual(frame.maxY, review.scroll.frame.maxY + 0.5)
            XCTAssertEqual(review.header.frame, header)
            XCTAssertEqual(review.footer.frame, footer)
            XCTAssertEqual(review.snapshot.context, snapshot.context)
            XCTAssertEqual(review.exactText.text, snapshot.exactRequest)
            XCTAssertEqual(copies, 0); XCTAssertEqual(closes, 0)
            // Returning to the first identity must reveal that identity, too.
            review.select(.source); settle(review)
            try button("generation-source-person-person-0", in: review).sendActions(for: .primaryActionTriggered)
            await nextMainQueueTurn(); settle(review)
            let first = try button("generation-person-person-0", in: review)
            let firstFrame = first.convert(first.bounds, to: review)
            XCTAssertGreaterThanOrEqual(firstFrame.minY, review.scroll.frame.minY - 0.5)
            XCTAssertLessThanOrEqual(firstFrame.maxY, review.scroll.frame.maxY + 0.5)
        }
    }

    func testQueuedRevealCannotOverrideNewerTabOrInvalidatedReview() async throws {
        let review = GenerationBriefReviewView(snapshot: try fixture(), onClose: {}, onCopy: { _ in XCTFail("Navigation is read-only") })
        review.frame = CGRect(x: 0, y: 0, width: 560, height: 650); settle(review)
        review.showPerson("person-7")
        review.select(.exactRequest)
        await nextMainQueueTurn(); settle(review)
        XCTAssertEqual(review.selectedTab, .exactRequest)
        XCTAssertTrue(review.scroll.isHidden)
        XCTAssertEqual(review.scroll.contentOffset, .zero)
        let exact = review.exactText.text
        review.showPerson("not-in-this-snapshot")
        await nextMainQueueTurn()
        XCTAssertEqual(review.selectedTab, .exactRequest)
        XCTAssertEqual(review.exactText.text, exact)
        review.showPerson("person-7")
        review.select(.source)
        await nextMainQueueTurn(); settle(review)
        XCTAssertEqual(review.selectedTab, .source)
        XCTAssertEqual(review.scroll.contentOffset, .zero)
        review.showPerson("person-7"); review.invalidate()
        await nextMainQueueTurn(); settle(review)
        XCTAssertFalse(review.isValid)
        XCTAssertTrue(review.body.arrangedSubviews.isEmpty)
        XCTAssertTrue((review.exactText.text ?? "").isEmpty)
        review.showPerson("person-0")
        await nextMainQueueTurn()
        XCTAssertTrue(review.body.arrangedSubviews.isEmpty)
    }

    func testRepeatedIdentityLinkRetainsExistingExpandedViews() async throws {
        let review = GenerationBriefReviewView(snapshot: try fixture(), onClose: {}, onCopy: { _ in })
        review.frame = CGRect(x: 0, y: 0, width: 560, height: 650); settle(review)
        review.showPerson("person-7")
        await nextMainQueueTurn(); settle(review)
        let existing = try button("generation-person-person-7", in: review)
        let first = try button("generation-person-person-0", in: review)
        review.showPerson("person-7")
        await nextMainQueueTurn(); settle(review)
        XCTAssertTrue(try button("generation-person-person-7", in: review) === existing)
        XCTAssertTrue(try button("generation-person-person-0", in: review) === first)
        XCTAssertEqual(first.accessibilityValue, "Expanded", "Following another identity must not collapse unrelated disclosures")
    }

    func testStoryboardSelectionSummary() {
        XCTAssertEqual(StoryboardSelectionPresentation.summary(wordCount: 0), "")
        XCTAssertEqual(StoryboardSelectionPresentation.summary(wordCount: 1), "1 word selected")
        XCTAssertEqual(StoryboardSelectionPresentation.summary(wordCount: 2), "2 words selected")
        XCTAssertEqual(StoryboardSelectionPresentation.summary(wordCount: 100), "100 words selected")
    }

    private func fixture() throws -> GenerationBriefSnapshot {
        let people = (0..<8).map { index in
            ScriptCharacter(id: "person-\(index)", name: "Person \(index)", aliases: ["Alias \(index)"],
                            biography: String(repeating: "Identity history only. cafe\u{301} 日本語. ", count: index == 0 ? 20 : 1),
                            appearance: "Blue jacket.")
        }
        let image = ImageAsset(id: "picture", fileName: "synthetic.png", sha256: "synthetic", byteCount: 1, characterIds: people.map(\.id))
        let project = ScrivProject(scenes: [ScriptScene(id: "scene", title: "INT. TEST — DAY")], characters: people,
                                  images: [image], cues: [ImageCue(id: "cue", sceneId: "scene", imageId: image.id, label: "01A", startMs: 0, endMs: 8000, prompt: "Wide shot.")])
        let context = try GenerationContext.build(project: project, cueID: "cue").selectingPortraits(availableAssetIDs: [])
        return GenerationBriefSnapshot(context: context, localPortraitURLs: [:])
    }
    private func nextMainQueueTurn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
    private func descendants(_ root: UIView) -> [UIView] { [root] + root.subviews.flatMap(descendants) }
    private func button(_ id: String, in root: UIView) throws -> UIButton {
        try XCTUnwrap(descendants(root).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == id })
    }
    private func settle(_ root: UIView, file: StaticString = #filePath, line: UInt = #line) {
        var previous: [CGRect] = [], stable = 0
        for _ in 0..<12 {
            root.setNeedsLayout(); root.layoutIfNeeded()
            let geometry = descendants(root).flatMap { view -> [CGRect] in
                var values = [view.frame, view.bounds]
                if let scroll = view as? UIScrollView { values.append(CGRect(origin: .zero, size: scroll.contentSize)) }
                return values
            }
            stable = geometry == previous ? stable + 1 : 0
            if stable == 2 { return }
            previous = geometry
        }
        XCTFail("Review layout did not settle; do not claim measured reachability", file: file, line: line)
    }
}
