import UIKit
import XCTest
import Darwin
import ScrivCore
@testable import ScrivUIKit

private final class PromptTestReleaseFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

private final class PromptTestLockLease: @unchecked Sendable {
    private let mutex = NSLock()
    private var descriptor: Int32
    init(root: URL) throws {
        descriptor = open(root.appendingPathComponent(".journal-lock").path,O_RDWR | O_CREAT,mode_t(0o600))
        guard descriptor >= 0 else { throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno)) }
        guard flock(descriptor,LOCK_EX | LOCK_NB) == 0 else {
            let code = errno; close(descriptor); descriptor = -1
            throw NSError(domain:NSPOSIXErrorDomain,code:Int(code))
        }
    }
    func release() {
        mutex.lock(); defer { mutex.unlock() }
        guard descriptor >= 0 else { return }
        _ = flock(descriptor,LOCK_UN); close(descriptor); descriptor = -1
    }
    deinit { release() }
}

/// Real isolated store/journal tests, including a deliberately held private test
/// lock. A utility-queue failsafe releases it, so a regression cannot deadlock
/// the test host indefinitely. These do not inspect user files or processes.
@MainActor
final class PromptRecoveryPresentationTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let store: WorkspaceStore
        let journal: CuePromptDraftJournal
        let cue: ImageCue
        let scope: CuePromptDraftScope
    }
    private func fixture() throws -> Fixture {
        guard ProcessInfo.processInfo.arguments.contains("--screenshots") else { throw XCTSkip("Requires isolated verification storage") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ScrivPromptPresentation-" + UUID().uuidString)
        let prior = ProcessInfo.processInfo.environment["SCRIV_VERIFICATION_ROOT"]
        setenv("SCRIV_VERIFICATION_ROOT",root.path,1)
        defer { if let prior { setenv("SCRIV_VERIFICATION_ROOT",prior,1) } else { unsetenv("SCRIV_VERIFICATION_ROOT") } }
        let store = WorkspaceStore()
        let cue = try XCTUnwrap(store.project.cues.first)
        store.selectedCueID = cue.id
        let package = try XCTUnwrap(store.projectURL)
        let scope = CuePromptDraftScope(packagePath:package.resolvingSymlinksInPath().path,projectID:store.project.id,
            cloudProjectID:store.project.cloudProjectId,server:store.cloud.baseURL.absoluteString,accountID:store.cloud.account?.id,
            sceneID:cue.sceneId,cueID:cue.id)
        let journal = try CuePromptDraftJournal(root:root.appendingPathComponent("CuePromptDrafts"))
        return Fixture(root:root,store:store,journal:journal,cue:cue,scope:scope)
    }
    private func recoveredDraft(_ fixture: Fixture, text: String) -> LocalCuePromptDraft {
        // Requires explicit review, preventing automatic canonical application
        // from obscuring what the presentation-only read retained.
        var draft = LocalCuePromptDraft(scope:fixture.scope,sourcePrompt:"Earlier saved direction",sourceEpoch:nil)
        draft.replaceText(text)
        return draft
    }
    private func holdLock(_ root: URL) throws -> PromptTestLockLease { try PromptTestLockLease(root:root) }
    private func descendants(_ root: UIView) -> [UIView] { [root] + root.subviews.flatMap { descendants($0) } }

    func testBusyRecoveryKeepsRenderResponsiveAndEditingClosedUntilExactDraftLoads() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at:f.root) }
        let text = "  👩🏽‍🚀 cafe\u{301}\n日本語\t  "
        let draft = recoveredDraft(f,text:text); try f.journal.save(draft,replacing:nil)
        let original = f.store.project
        let lease = try holdLock(f.journal.root); defer { lease.release() }
        let released = PromptTestReleaseFlag(), release = expectation(description:"Utility queue releases private fixture lock")
        DispatchQueue.global(qos:.userInitiated).asyncAfter(deadline:.now() + 0.8) {
            lease.release(); released.set(); release.fulfill()
        }
        let read = f.store.prepareGenerationPromptForPresentation()
        let panel = GenerationPanelViewController(store:f.store)
        panel.loadViewIfNeeded()
        let field = try XCTUnwrap(descendants(panel.view).compactMap { $0 as? UITextView }.first { $0.accessibilityIdentifier == "generation-optional-direction" })
        for _ in 0..<20 {
            _ = f.store.generationPrompt; _ = f.store.generationPromptScopeKey
            _ = f.store.generationPromptIssue; _ = f.store.generationPromptNeedsReview
            _ = f.store.generationPromptDraftStatus; _ = f.store.localSaveStatusMessage
            _ = f.store.selectedImageGenerationContext; panel.storeDidChange()
        }
        XCTAssertFalse(released.isSet,"Rendering must not wait for the held recovery lock")
        XCTAssertFalse(f.store.generationPromptRecoveryIsReady)
        XCTAssertFalse(field.isEditable)
        panel.textViewDidBeginEditing(field)
        XCTAssertFalse(panel.textView(field,shouldChangeTextIn:NSRange(location:0,length:0),replacementText:"Must not overwrite unseen recovery"))
        await fulfillment(of:[release],timeout:3)
        await read?.value
        panel.storeDidChange()
        XCTAssertTrue(f.store.generationPromptRecoveryIsReady)
        XCTAssertTrue(f.store.generationPromptNeedsReview)
        XCTAssertTrue(f.store.generationPrompt.utf16.elementsEqual(text.utf16))
        XCTAssertEqual(try f.journal.load(f.scope),draft)
        XCTAssertEqual(f.store.project,original)
    }

    func testCueSwitchCancelsBusyReadAndOldResultCannotRetargetTheNewCue() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at:f.root) }
        let b = try XCTUnwrap(f.store.project.cues.dropFirst().first)
        let aDraft = recoveredDraft(f,text:"Private A draft")
        try f.journal.save(aDraft,replacing:nil)
        var bScope = f.scope; bScope.cueID = b.id; bScope.sceneID = b.sceneId
        var bDraft = LocalCuePromptDraft(scope:bScope,sourcePrompt:"Earlier B",sourceEpoch:nil)
        bDraft.replaceText("Private B draft"); try f.journal.save(bDraft,replacing:nil)
        let lease = try holdLock(f.journal.root); defer { lease.release() }
        let released = PromptTestReleaseFlag(), release = expectation(description:"Release fixture lock")
        DispatchQueue.global(qos:.userInitiated).asyncAfter(deadline:.now() + 0.8) {
            lease.release(); released.set(); release.fulfill()
        }
        let oldRead = f.store.prepareGenerationPromptForPresentation()
        f.store.selectedCueID = b.id
        let newRead = f.store.prepareGenerationPromptForPresentation()
        await oldRead?.value
        XCTAssertFalse(released.isSet,"Cancellation must not await advisory-lock availability")
        XCTAssertNotEqual(f.store.generationPrompt,"Private A draft")
        await fulfillment(of:[release],timeout:3); await newRead?.value
        XCTAssertEqual(f.store.generationPrompt,"Private B draft")
        XCTAssertEqual(try f.journal.load(f.scope),aDraft)
        XCTAssertEqual(try f.journal.load(bScope),bDraft)
    }

    func testAcceptedEditInvalidatesInFlightReadAndRetainsExactNewerBytes() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at:f.root) }
        let draft = recoveredDraft(f,text:"Earlier retained text")
        try f.journal.save(draft,replacing:nil)
        let pending = f.store.prepareGenerationPromptForPresentation()
        let edited = "  New accepted edit 👩🏽‍🚀\nwith exact spaces  "
        // This synchronous API must journal before returning; whichever read
        // snapshot won scheduling is invalidated by the accepted edit.
        f.store.generationPrompt = edited
        let retained = try XCTUnwrap(f.journal.load(f.scope))
        XCTAssertTrue(retained.text.utf16.elementsEqual(edited.utf16))
        await pending?.value
        XCTAssertTrue(f.store.generationPrompt.utf16.elementsEqual(edited.utf16))
        XCTAssertNotEqual(retained.revisionID,draft.revisionID)
        await f.store.flushPendingSaves()
    }

    func testForeignNewerDraftStillRejectsStaleEditWithoutOverwritingEitherText() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at:f.root) }
        let old = recoveredDraft(f,text:"Earlier loaded draft")
        try f.journal.save(old,replacing:nil)
        let panel = GenerationPanelViewController(store:f.store); panel.loadViewIfNeeded()
        await f.store.prepareGenerationPromptForPresentation()?.value; panel.storeDidChange()
        let field = try XCTUnwrap(descendants(panel.view).compactMap { $0 as? UITextView }.first { $0.accessibilityIdentifier == "generation-optional-direction" })
        var foreign = old; foreign.replaceText("Other window's newer accepted draft")
        try f.journal.save(foreign,replacing:old.revisionID)
        panel.textViewDidBeginEditing(field)
        let attempted = "My rejected attempt must remain visible"
        XCTAssertFalse(panel.textView(field,shouldChangeTextIn:NSRange(location:0,length:field.text.utf16.count),replacementText:attempted))
        panel.storeDidChange()
        XCTAssertEqual(try f.journal.load(f.scope),foreign)
        XCTAssertEqual(field.text,old.text)
        XCTAssertNotNil(f.store.generationPromptIssue)
        let visible = descendants(panel.view).compactMap { ($0 as? UITextView)?.text ?? ($0 as? UILabel)?.text }
        XCTAssertTrue(visible.contains(attempted),"Rejected native input must remain available for explicit retry, not disappear")
    }
    func testKnownAbsentRecoveryDoesNotAdoptAndOverwriteAnUnseenForeignDraft() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at:f.root) }
        let panel = GenerationPanelViewController(store:f.store); panel.loadViewIfNeeded()
        await f.store.prepareGenerationPromptForPresentation()?.value; panel.storeDidChange()
        XCTAssertTrue(f.store.generationPromptRecoveryIsReady)
        XCTAssertNil(try f.journal.load(f.scope))
        let field = try XCTUnwrap(descendants(panel.view).compactMap { $0 as? UITextView }.first { $0.accessibilityIdentifier == "generation-optional-direction" })
        let foreign = recoveredDraft(f,text:"Created elsewhere after observed absence")
        try f.journal.save(foreign,replacing:nil)
        panel.textViewDidBeginEditing(field)
        let attempted = "Do not silently replace the unseen recovery"
        XCTAssertFalse(panel.textView(field,shouldChangeTextIn:NSRange(location:0,length:field.text.utf16.count),replacementText:attempted))
        panel.storeDidChange()
        XCTAssertEqual(try f.journal.load(f.scope),foreign)
        let visible = descendants(panel.view).compactMap { ($0 as? UITextView)?.text ?? ($0 as? UILabel)?.text }
        XCTAssertTrue(visible.contains(attempted))
        let stableScope = f.store.generationPromptScopeKey
        let request = f.store.generationPromptPreparationID
        f.store.cloud.disconnect() // Local verification fixture only; no account/session.
        XCTAssertEqual(f.store.generationPromptScopeKey,stableScope)
        XCTAssertNotEqual(f.store.generationPromptPreparationID,request)
        panel.storeDidChange(); await f.store.prepareGenerationPromptForPresentation()?.value; panel.storeDidChange()
        let retained = descendants(panel.view).compactMap { ($0 as? UITextView)?.text ?? ($0 as? UILabel)?.text }
        XCTAssertTrue(retained.contains(attempted),"A lifecycle change must not orphan rejected text under an ephemeral UI key")
    }

    func testNoCueTransitionCancelsBusyReadWithoutNeedingAVisibleRenderer() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at:f.root) }
        let lease = try holdLock(f.journal.root); defer { lease.release() }
        let released = PromptTestReleaseFlag(), release = expectation(description:"Release held test lock")
        DispatchQueue.global(qos:.userInitiated).asyncAfter(deadline:.now() + 0.8) {
            lease.release(); released.set(); release.fulfill()
        }
        let read = f.store.prepareGenerationPromptForPresentation()
        f.store.project.cues = []
        await read?.value
        await f.store.flushPendingSaves()
        XCTAssertFalse(released.isSet,"Removing the last cue must cancel its reader independently of view refresh")
        await fulfillment(of:[release],timeout:3)
    }

    func testFlushDrainsReplacementReadRatherThanReportingCancelledSnapshotAsSaved() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at:f.root) }
        let b = try XCTUnwrap(f.store.project.cues.dropFirst().first)
        let lease = try holdLock(f.journal.root); defer { lease.release() }
        let release = expectation(description:"Release held test lock")
        DispatchQueue.global(qos:.userInitiated).asyncAfter(deadline:.now() + 0.8) {
            lease.release(); release.fulfill()
        }
        f.store.prepareGenerationPromptForPresentation()
        let finished = PromptTestReleaseFlag()
        let flush = Task { await f.store.flushPendingSaves(); finished.set() }
        await Task.yield()
        f.store.selectedCueID = b.id
        let bRead = f.store.prepareGenerationPromptForPresentation()
        try await Task.sleep(for:.milliseconds(80))
        XCTAssertFalse(finished.isSet,"Flush must also wait for B, not just cancelled A")
        await fulfillment(of:[release],timeout:3); await bRead?.value; await flush.value
        XCTAssertTrue(finished.isSet)
        XCTAssertTrue(f.store.generationPromptRecoveryIsReady)
    }

    func testImageMetadataRefreshDoesNotReloadForeignDraftOrDisableKnownRecovery() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at:f.root) }
        let metadata = ImageAsset(id:"metadata-only",fileName:"absent-metadata-only.png",sha256:"metadata-only",byteCount:1)
        f.store.project.images.append(metadata)
        let old = recoveredDraft(f,text:"Current editor's observed text")
        try f.journal.save(old,replacing:nil)
        await f.store.prepareGenerationPromptForPresentation()?.value
        var foreign = old; foreign.replaceText("A foreign revision must await explicit recovery reopen")
        try f.journal.save(foreign,replacing:old.revisionID)
        let index = try XCTUnwrap(f.store.project.images.indices.first)
        f.store.project.images[index].version += 1
        let assets = f.store.prepareGenerationPromptForPresentation()
        XCTAssertTrue(f.store.generationPromptRecoveryIsReady,"Unrelated portrait metadata must not revoke editing/IME readiness")
        XCTAssertFalse(f.store.generationPromptPresentationIsCurrent)
        await assets?.value
        XCTAssertEqual(f.store.generationPrompt,old.text,"An asset-only refresh must not adopt unseen recovery text")
        XCTAssertTrue(f.store.generationPromptPresentationIsCurrent)
        XCTAssertEqual(try f.journal.load(f.scope),foreign)
    }

    func testAcceptedEditDuringAssetRefreshPublishesTheCompletedAvailabilitySnapshot() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at:f.root) }
        let package = try XCTUnwrap(f.store.projectURL)
        let directory = package.appendingPathComponent("assets",isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let bytes = Data([0x01]) // Metadata-only local-file fixture; never decoded or submitted.
        let portrait = ImageAsset(id:"presentation-portrait",fileName:"presentation-portrait.png",sha256:ScrivDigest.sha256(bytes),byteCount:bytes.count)
        try bytes.write(to:directory.appendingPathComponent(portrait.fileName))
        let person = ScriptCharacter(id:"presentation-person",name:"Presentation Person",portraitImageId:portrait.id)
        let picture = ImageAsset(id:"presentation-picture",fileName:"absent-presentation-picture.png",sha256:"presentation-picture",byteCount:1,characterIds:[person.id])
        let cueIndex = try XCTUnwrap(f.store.project.cues.firstIndex { $0.id == f.cue.id })
        f.store.project.characters.append(person)
        f.store.project.images.append(contentsOf:[portrait,picture])
        f.store.project.cues[cueIndex].imageId = picture.id
        let draft = recoveredDraft(f,text:"Observed recovery before metadata refresh")
        try f.journal.save(draft,replacing:nil)
        await f.store.prepareGenerationPromptForPresentation()?.value
        XCTAssertTrue(f.store.selectedImageGenerationContext?.portraits.contains { $0.assetID == portrait.id } == true)
        let portraitIndex = try XCTUnwrap(f.store.project.images.firstIndex { $0.id == portrait.id })
        f.store.project.images[portraitIndex].byteCount += 1 // No longer matches the local file.
        let pendingAssets = f.store.prepareGenerationPromptForPresentation()
        XCTAssertFalse(f.store.generationPromptPresentationIsCurrent)
        // No suspension: the edit must not mark the in-flight request as a
        // completed asset snapshot before the worker has published its result.
        let edited = "Accepted edit while portrait metadata is pending 🎬"
        f.store.generationPrompt = edited
        XCTAssertTrue(f.store.generationPromptPresentationIsCurrent)
        XCTAssertFalse(f.store.selectedImageGenerationContext?.portraits.contains { $0.assetID == portrait.id } == true)
        await pendingAssets?.value
        XCTAssertEqual(f.store.generationPrompt,edited)
        XCTAssertFalse(f.store.selectedImageGenerationContext?.portraits.contains { $0.assetID == portrait.id } == true)
        XCTAssertEqual(try f.journal.load(f.scope)?.text,edited)
        await f.store.flushPendingSaves()
    }

}
