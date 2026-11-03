import XCTest
import UIKit
import ScrivCore
@testable import ScrivUIKit

/// Real view wiring over synthetic temporary images. No view is presented,
/// and no account request, generation, save, share or attachment action is sent.
@MainActor final class RemainingImageDigestTests: XCTestCase {
    func testExplicitAndFallbackPortraitsRejectUnverifiedCachedBytesAndRetry() async throws {
        try await withFixture { store, mainURL, portraitURL, mainBytes, portraitBytes, wrongBytes in
            let original = store.project
            let explicit = try XCTUnwrap(store.project.character("mara"))
            var fallback = explicit; fallback.portraitImageId = nil
            for (person, url, bytes, assetID) in [(explicit, portraitURL, portraitBytes, "portrait"), (fallback, mainURL, mainBytes, "main")] {
                let asset = try XCTUnwrap(store.project.asset(assetID))
                try wrongBytes.write(to: url, options: .atomic)
                XCTAssertNotNil(store.assetURL(asset))
                let unverified = UIKitAssetImageView()
                unverified.configure(url: url, title: "Synthetic unverified cache")
                try await settle(unverified); XCTAssertEqual(unverified.loadPhase, .loaded)
                let picture = try XCTUnwrap(CharacterTeamUI.portrait(person, store: store, size: CGSize(width: 120, height: 120)) as? UIKitAssetImageView)
                try await settle(picture); XCTAssertEqual(picture.loadPhase, .failed); XCTAssertNil(picture.loadedDigest)
                try bytes.write(to: url, options: .atomic)
                try retry(picture); try await settle(picture)
                XCTAssertEqual(picture.loadPhase, .loaded); XCTAssertEqual(picture.loadedDigest, asset.sha256)
            }
            XCTAssertEqual(store.project, original)
        }
    }

    func testTaggedCharacterCardUsesItsOwnDigestRatherThanThePortraitDigest() async throws {
        try await withFixture { store, mainURL, _, mainBytes, _, wrongBytes in
            let original = store.project, main = try XCTUnwrap(store.project.asset("main"))
            let portrait = try XCTUnwrap(store.project.asset("portrait"))
            XCTAssertNotEqual(main.sha256, portrait.sha256)
            try wrongBytes.write(to: mainURL, options: .atomic)
            let controller = CharactersController(store: store); controller.loadViewIfNeeded()
            let card = try picture(label: "01A", in: controller.view)
            try await settle(card); XCTAssertEqual(card.loadPhase, .failed); XCTAssertNil(card.loadedDigest)
            let avatar = try picture(label: "Mara", in: controller.view)
            try await settle(avatar); XCTAssertEqual(avatar.loadPhase, .loaded); XCTAssertEqual(avatar.loadedDigest, portrait.sha256)
            try mainBytes.write(to: mainURL, options: .atomic)
            try retry(card); try await settle(card)
            XCTAssertEqual(card.loadPhase, .loaded); XCTAssertEqual(card.loadedDigest, main.sha256)
            XCTAssertEqual(store.project, original)
        }
    }

    func testDiscussionAttachmentVersionAndContextKeepTheirOwnDigestAcrossReuse() async throws {
        try await withFixture { store, mainURL, _, mainBytes, _, wrongBytes in
            let original = store.project, main = try XCTUnwrap(store.project.asset("main"))
            let portrait = try XCTUnwrap(store.project.asset("portrait"))
            try wrongBytes.write(to: mainURL, options: .atomic)
            let cell = DiscussionMessageCell(style: .default, reuseIdentifier: "synthetic")
            let message = try ScrivJSON.decoder.decode(DiscussionMessage.self, from: Data(#"{"id":"message","threadId":"thread","userId":"synthetic-author","name":"Synthetic","body":"Synthetic image","attachments":[{"imageVersionId":"main","itemId":"portrait"}]}"#.utf8))
            cell.configure(message: message, store: store, focused: false, reply: {}, openAttachment: { _ in XCTFail("Must not open an attachment") })
            let attachment = try XCTUnwrap(pictures(in: cell).first)
            try await settle(attachment); XCTAssertEqual(attachment.loadPhase, .failed); XCTAssertNil(attachment.loadedDigest)
            store.discussionItemID = main.id
            let controller = ScrivDiscussionController(store: store); controller.loadViewIfNeeded()
            let context = try XCTUnwrap(pictures(in: controller.view).first)
            XCTAssertNil(store.account, "Signed-out context rendering must not request remote members")
            try await settle(context); XCTAssertEqual(context.loadPhase, .failed); XCTAssertNil(context.loadedDigest)
            try mainBytes.write(to: mainURL, options: .atomic)
            for picture in [attachment, context] {
                try retry(picture); try await settle(picture)
                XCTAssertEqual(picture.loadPhase, .loaded); XCTAssertEqual(picture.loadedDigest, main.sha256)
            }
            var other = message; other.attachments = [.object(["imageVersionId": .string(portrait.id)])]
            cell.configure(message: other, store: store, focused: false, reply: {}, openAttachment: { _ in XCTFail("Must not open an attachment") })
            XCTAssertEqual(pictures(in: cell).count, 1)
            let reused = try XCTUnwrap(pictures(in: cell).first)
            try await settle(reused); XCTAssertEqual(reused.loadPhase, .loaded); XCTAssertEqual(reused.loadedDigest, portrait.sha256)
            store.discussionItemID = portrait.id; controller.storeDidChange()
            try await settle(context); XCTAssertEqual(context.loadPhase, .loaded); XCTAssertEqual(context.loadedDigest, portrait.sha256)
            store.discussionItemID = nil; controller.storeDidChange(); XCTAssertTrue(context.isHidden)
            XCTAssertEqual(store.project, original)
        }
    }

    func testTeamCoverRejectsWrongBytesAndRetainsRetry() async throws {
        try await withFixture { store, mainURL, _, mainBytes, _, wrongBytes in
            let original = store.project, main = try XCTUnwrap(store.project.asset("main"))
            try wrongBytes.write(to: mainURL, options: .atomic)
            try installSyntheticTeam(in: store)
            // loadViewIfNeeded renders only. Do not present or call viewDidAppear,
            // which would start the controller's real account refresh.
            let controller = TeamsController(store: store); controller.loadViewIfNeeded()
            let cover = try XCTUnwrap(pictures(in: controller.view).first)
            try await settle(cover); XCTAssertEqual(cover.loadPhase, .failed); XCTAssertNil(cover.loadedDigest)
            try mainBytes.write(to: mainURL, options: .atomic)
            try retry(cover); try await settle(cover)
            XCTAssertEqual(cover.loadPhase, .loaded); XCTAssertEqual(cover.loadedDigest, main.sha256)
            XCTAssertEqual(store.project, original)
        }
    }

    func testGenerationAvatarUsesTheDeduplicatedReferenceURLAndDigest() async throws {
        try await withFixture { store, mainURL, portraitURL, _, portraitBytes, wrongBytes in
            let original = store.project
            var project = original
            let shared = try XCTUnwrap(project.asset("portrait"))
            let mae = ScriptCharacter(id: "mae", name: "Mae", portraitImageId: "portrait-copy")
            project.characters.append(mae)
            var duplicate = shared; duplicate.id = "portrait-copy"; duplicate.fileName = "portrait-copy.png"
            project.images.append(duplicate); project.images[0].characterIds.append(mae.id)
            let context = try GenerationContext.build(project: project, cueID: "cue").selectingPortraits(availableAssetIDs: ["portrait", "portrait-copy"])
            let snapshot = GenerationBriefSnapshot(context: context, localPortraitURLs: ["portrait": portraitURL, "portrait-copy": mainURL])
            XCTAssertEqual(context.portraits.count, 1)
            XCTAssertEqual(context.portraits.first?.characterIDs, ["mara", "mae"])
            XCTAssertEqual(snapshot.attachedPortraitURL(for: mae.id), portraitURL)
            XCTAssertEqual(snapshot.attachedPortrait(for: mae.id)?.sha256, shared.sha256)
            XCTAssertNotEqual(mainURL, portraitURL, "Unused duplicate URL must not replace the selected shared input")
            try wrongBytes.write(to: portraitURL, options: .atomic)
            let avatar = try XCTUnwrap(GenerationReviewUI.avatar(mae, snapshot: snapshot, size: 110) as? UIKitAssetImageView)
            try await settle(avatar); XCTAssertEqual(avatar.loadPhase, .failed); XCTAssertNil(avatar.loadedDigest)
            try portraitBytes.write(to: portraitURL, options: .atomic)
            try retry(avatar); try await settle(avatar)
            XCTAssertEqual(avatar.loadPhase, .loaded); XCTAssertEqual(avatar.loadedDigest, shared.sha256)
            let unavailable = GenerationBriefSnapshot(context: context, localPortraitURLs: [:])
            XCTAssertNil(unavailable.attachedPortrait(for: mae.id)); XCTAssertNil(unavailable.attachedPortraitURL(for: mae.id))
            XCTAssertFalse(GenerationReviewUI.avatar(mae, snapshot: unavailable, size: 44) is UIKitAssetImageView)
            XCTAssertEqual(store.project, original)
        }
    }

    func testMissingPortraitAndTeamCoverKeepTheirPlaceholders() async throws {
        try await withFixture { store, _, _, _, _, _ in
            store.project.images[0].fileName = "missing-main.png"
            store.project.images[1].fileName = "missing-portrait.png"
            let original = store.project, person = try XCTUnwrap(store.project.character("mara"))
            let large = try XCTUnwrap(CharacterTeamUI.portrait(person, store: store, size: CGSize(width: 120, height: 120)) as? UIKitAssetImageView)
            XCTAssertEqual(large.loadPhase, .empty); XCTAssertEqual(large.accessibilityValue, "No portrait on this device")
            let small = CharacterTeamUI.portrait(person, store: store, size: CGSize(width: 44, height: 44))
            XCTAssertEqual(small.accessibilityIdentifier, "character-portrait-placeholder")
            try installSyntheticTeam(in: store)
            let controller = TeamsController(store: store); controller.loadViewIfNeeded()
            let cover = try XCTUnwrap(pictures(in: controller.view).first)
            XCTAssertEqual(cover.loadPhase, .empty); XCTAssertEqual(cover.accessibilityValue, "No preview")
            XCTAssertNil(large.loadedDigest); XCTAssertNil(cover.loadedDigest)
            XCTAssertEqual(store.project, original)
        }
    }

    private func installSyntheticTeam(in store: WorkspaceStore) throws {
        store.account = try ScrivJSON.decoder.decode(CloudUser.self, from: Data(#"{"id":"synthetic-user","name":"Synthetic User"}"#.utf8))
        store.teams = [try ScrivJSON.decoder.decode(CloudTeam.self, from: Data(#"{"id":"synthetic-team","name":"Synthetic Team","role":"viewer","plan":"free"}"#.utf8))]
    }
    private func withFixture(_ check: (WorkspaceStore, URL, URL, Data, Data, Data) async throws -> Void) async throws {
        guard ProcessInfo.processInfo.arguments.contains("--screenshots") else {
            throw XCTSkip("Requires isolated verification storage; never construct a live user workspace.")
        }
        let store = WorkspaceStore()
        let scratch = try XCTUnwrap(store.projectURL).deletingLastPathComponent().deletingLastPathComponent()
        defer {
            if ProcessInfo.processInfo.environment["SCRIV_VERIFICATION_ROOT"] == nil,
               scratch.lastPathComponent.hasPrefix("ScrivVerification-"),
               scratch.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL {
                try? FileManager.default.removeItem(at: scratch)
            }
        }
        for _ in 0..<500 where store.isBootstrapping { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.isBootstrapping)
        guard !store.isBootstrapping else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ScrivRemainingDigestTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Synthetic.scriv", isDirectory: true)
        let assets = package.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        var mainBytes = png(.blue), portraitBytes = png(.green), wrongBytes = png(.red)
        let size = max(mainBytes.count, max(portraitBytes.count, wrongBytes.count))
        mainBytes.append(Data(repeating: 0, count: size - mainBytes.count))
        portraitBytes.append(Data(repeating: 0, count: size - portraitBytes.count))
        wrongBytes.append(Data(repeating: 0, count: size - wrongBytes.count))
        for bytes in [mainBytes, portraitBytes, wrongBytes] { XCTAssertNotNil(UIImage(data: bytes)) }
        XCTAssertEqual(Set([mainBytes, portraitBytes, wrongBytes].map { ScrivDigest.sha256($0) }).count, 3)
        let mainURL = assets.appendingPathComponent("main.png"), portraitURL = assets.appendingPathComponent("portrait.png")
        try mainBytes.write(to: mainURL); try portraitBytes.write(to: portraitURL)
        let main = ImageAsset(id: "main", fileName: "main.png", sha256: ScrivDigest.sha256(mainBytes), byteCount: mainBytes.count, characterIds: ["mara"])
        let portrait = ImageAsset(id: "portrait", fileName: "portrait.png", sha256: ScrivDigest.sha256(portraitBytes), byteCount: portraitBytes.count)
        store.projectURL = package
        store.project = ScrivProject(id: "remaining-image-digest-fixture", scenes: [ScriptScene(id: "scene")],
            entries: [ScriptEntry(id: "line", sceneId: "scene", order: 0, text: "Synthetic scene", ownedDurationMs: 1000)],
            characters: [ScriptCharacter(id: "mara", name: "Mara", portraitImageId: portrait.id)],
            images: [main, portrait], cues: [ImageCue(id: "cue", sceneId: "scene", imageId: main.id, label: "01A", startMs: 0, endMs: 1000)])
        store.selectedSceneID = "scene"; store.selectedCharacterID = "mara"
        try await check(store, mainURL, portraitURL, mainBytes, portraitBytes, wrongBytes)
    }
    private func retry(_ picture: UIKitAssetImageView) throws {
        let button = try XCTUnwrap(descendants(picture).compactMap { $0 as? UIButton }.first { $0.title(for: .normal) == "Retry" })
        XCTAssertFalse(button.isHidden); button.sendActions(for: .touchUpInside)
    }
    private func settle(_ picture: UIKitAssetImageView) async throws {
        for _ in 0..<300 where picture.loadPhase == .loading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotEqual(picture.loadPhase, .loading)
    }
    private func pictures(in view: UIView) -> [UIKitAssetImageView] { descendants(view).compactMap { $0 as? UIKitAssetImageView } }
    private func picture(label: String, in view: UIView) throws -> UIKitAssetImageView {
        try XCTUnwrap(pictures(in: view).first { picture in descendants(picture).contains { ($0 as? UIImageView)?.accessibilityLabel == label } })
    }
    private func png(_ color: UIColor) -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).pngData { context in color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8)) }
    }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
}
