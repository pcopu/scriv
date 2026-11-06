import Foundation
import Combine
import ImageIO
import CoreGraphics
import ScrivCore

struct CharacterImageReviewItem: Identifiable {
    let image: ImageAsset
    let annotation: CharacterImageAnnotation
    var id: String { image.id + ":" + annotation.id }
}

/// One serial, cancelable scan across immutable versions. Successful annotations
/// live in project history; interrupted work is safely rediscovered after reopen.
@MainActor
final class CharacterAnalysisController {
    private weak var store: WorkspaceStore?
    private let provider: any CharacterImageAnalysisProvider
    private let allowsAnalysis: Bool
    private let pendingDirectory: URL
    private var task: Task<Void,Never>?
    private var generation = 0
    private var projectID: String?
    private var previousAvailability: String?
    private var failed: [String:String] = [:]
    private var forced: Set<String> = []
    private var paused = false
    private(set) var isScanning = false
    private(set) var status = "Connect an image-capable AI to check characters."
    private(set) var currentImageID: String?
    init(store: WorkspaceStore, provider: any CharacterImageAnalysisProvider, allowsAnalysis: Bool = true, pendingDirectory: URL? = nil) {
        self.store = store; self.provider = provider; self.allowsAnalysis = allowsAnalysis
        let verification = ProcessInfo.processInfo.arguments.contains("--screenshots") || ProcessInfo.processInfo.arguments.contains("--peer-smoke")
        let root = verification
            ? (ProcessInfo.processInfo.environment["SCRIV_VERIFICATION_ROOT"].map { URL(fileURLWithPath:$0,isDirectory:true) } ?? FileManager.default.temporaryDirectory.appendingPathComponent("ScrivCharacterVerification-" + UUID().uuidString,isDirectory:true))
            : FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Scriv",isDirectory:true)
        self.pendingDirectory = pendingDirectory ?? root.appendingPathComponent("CharacterAnalysisPending",isDirectory:true)
    }
    var availability: String? { allowsAnalysis ? provider.availability : "Image analysis is disabled in verification mode." }
    var autoTagEnabled: Bool {
        get { guard let store else { return false }; return UserDefaults.standard.object(forKey:preferenceKey(store.project.id)) as? Bool ?? true }
        set {
            guard let store else { return }; UserDefaults.standard.set(newValue,forKey:preferenceKey(store.project.id))
            if newValue { paused = false; refresh() } else { cancel(); publish("Auto-tagging is paused. Your existing tags are kept.") }
        }
    }
    private func preferenceKey(_ id: String) -> String { "ScrivCharacterAutoTag.v1." + id }
    private func interruptionKey(_ id: String) -> String { "ScrivCharacterAnalysisInterruption.v1." + id }
    private func pendingFile(_ projectID: String) -> URL { pendingDirectory.appendingPathComponent(ScrivDigest.sha256(Data(projectID.utf8))).appendingPathExtension("pending") }
    private func recordPending(projectID: String, attempt: String) throws {
        // Complete the atomic disk write before invoking the provider. A process
        // crash must not turn a possibly submitted inference into an auto-retry.
        try FileManager.default.createDirectory(at:pendingDirectory,withIntermediateDirectories:true)
        let bytes = Data(attempt.utf8), file = pendingFile(projectID)
        try bytes.write(to:file,options:.atomic)
        guard try Data(contentsOf:file) == bytes else { throw ScrivError.unavailable("The pending analysis marker could not be verified.") }
    }
    private func clearPending(projectID: String, attempt: String) throws {
        let file = pendingFile(projectID)
        guard FileManager.default.fileExists(atPath:file.path), try Data(contentsOf:file) == Data(attempt.utf8) else { return }
        try FileManager.default.removeItem(at:file)
    }
    var reviewItems: [CharacterImageReviewItem] {
        guard let store else { return [] }
        return store.project.images.flatMap { image in
            guard let analysis = image.characterAnalysis, analysis.matches(image) else { return [CharacterImageReviewItem]() }
            return analysis.annotations.filter { $0.decision == .needsReview }.map { CharacterImageReviewItem(image:image,annotation:$0) }
        }
    }
    var reviewImageCount: Int { Set(reviewItems.map { $0.image.id }).count }
    var checkedCount: Int { store?.project.images.filter { image in image.characterAnalysis.map { $0.providerID != "manual" && $0.matches(image) } == true }.count ?? 0 }
    var failureCount: Int { failed.count }
    func refresh() {
        guard let store else { return }
        if projectID != store.project.id { cancel(); projectID = store.project.id; failed = [:]; forced = []; paused = false }
        let unavailable = availability
        if previousAvailability != unavailable {
            if unavailable == nil { failed = [:]; paused = false }
            previousAvailability = unavailable
        }
        if let unavailable { cancel(); publish(unavailable); return }
        if let reason = UserDefaults.standard.string(forKey: interruptionKey(store.project.id)) {
            paused = true; publish("Character scan paused. " + reason); return
        }
        if task == nil, FileManager.default.fileExists(atPath:pendingFile(store.project.id).path) {
            paused = true; publish("The previous character scan did not finish. Review Codex, then choose Scan again; nothing was resubmitted."); return
        }
        guard autoTagEnabled, !paused else { return }
        guard task == nil else { return }
        let pending = store.project.images.filter { image in
            let key = CharacterImageAnalysis.workKey(projectID:store.project.id,image:image)
            return failed[key] == nil && (forced.contains(key) || image.characterAnalysis.map { $0.providerID != "manual" && $0.matches(image) } != true)
        }
        guard pending.contains(where: { store.assetURL($0) != nil }) else {
            if !pending.isEmpty { publish("\(checkedCount) of \(store.project.images.count) checked · \(pending.count) waiting for images on this device") }
            return
        }
        start()
    }
    func scanAgain() {
        guard let store else { return }
        cancel(); failed = [:]; paused = false
        do {
            let pending = pendingFile(store.project.id)
            if FileManager.default.fileExists(atPath:pending.path) { try FileManager.default.removeItem(at:pending) }
        } catch { paused = true; publish("The previous analysis marker could not be cleared. " + error.localizedDescription); return }
        UserDefaults.standard.removeObject(forKey: interruptionKey(store.project.id))
        forced = Set(store.project.images.map { CharacterImageAnalysis.workKey(projectID:store.project.id,image:$0) })
        if let availability { publish(availability); return }
        start()
    }
    func cancel() {
        generation += 1; task?.cancel(); task = nil; isScanning = false; currentImageID = nil
    }
    func pause() { paused = true; cancel(); publish("Scan paused. Checked images and your corrections are kept.") }
    private func publish(_ message: String) {
        guard status != message else { return }; status = message; store?.objectWillChange.send()
    }
    private func start() {
        guard allowsAnalysis, let store, availability == nil else { return }
        let currentGeneration = generation, navigation = store.navigationContext, expectedProject = store.project.id
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == currentGeneration { self.task = nil; self.isScanning = false; self.currentImageID = nil; self.store?.objectWillChange.send() }
            }
            var waitingForBytes = 0
            let candidates = store.project.images
            for image in candidates {
                guard !Task.isCancelled, self.generation == currentGeneration, store.navigationContext == navigation, store.project.id == expectedProject, self.availability == nil else { return }
                let key = CharacterImageAnalysis.workKey(projectID:expectedProject,image:image)
                let alreadyChecked = image.characterAnalysis.map { $0.providerID != "manual" && $0.matches(image) } == true
                guard (!alreadyChecked || self.forced.contains(key)), self.failed[key] == nil else { continue }
                guard let url = store.assetURL(image) else { waitingForBytes += 1; continue }
                self.isScanning = true; self.currentImageID = image.id
                self.publish("Checking image \(self.checkedCount + 1) of \(store.project.images.count)…")
                let request = CharacterImageAnalysisRequest(projectID:expectedProject,imageID:image.id,imageVersion:image.version,imageSHA256:image.sha256,imageURL:url,context:self.context(image,project:store.project),characters:store.project.characters)
                let attempt = UUID().uuidString
                do {
                    // Verify the immutable bytes, not just a filename or byte count.
                    let digest = try await Task.detached(priority:.utility) { try ScrivDigest.sha256(Data(contentsOf:url,options:.mappedIfSafe)) }.value
                    try Task.checkCancellation()
                    guard self.generation == currentGeneration, store.navigationContext == navigation, store.project.id == expectedProject, self.availability == nil else { return }
                    guard digest == image.sha256 else { throw ScrivError.invalid("Image bytes failed their version check. Restore this exact image before retrying.") }
                    do { try self.recordPending(projectID:expectedProject,attempt:attempt) }
                    catch { throw CharacterAnalysisInterruption(reason:"The scan could not record its pending state. No analysis was submitted. " + error.localizedDescription) }
                    let result = try await self.analyzeWithRetry(request)
                    try Task.checkCancellation()
                    guard self.generation == currentGeneration, store.navigationContext == navigation, store.project.id == expectedProject, store.project.asset(image.id)?.sha256 == image.sha256, store.project.asset(image.id)?.version == image.version else {
                        try self.clearPending(projectID:expectedProject,attempt:attempt); continue
                    }
                    guard await store.applyCharacterAnalysis(result,image:image,providerID:self.provider.providerID,navigation:navigation) else { throw ScrivError.conflict(store.errorMessage ?? "Character tags could not be saved. Retry when this image is editable.") }
                    guard self.generation == currentGeneration, store.navigationContext == navigation, store.project.id == expectedProject else { return }
                    try self.clearPending(projectID:expectedProject,attempt:attempt)
                    self.forced.remove(key)
                } catch is CancellationError { return }
                catch let interruption as CharacterAnalysisInterruption {
                    // A reconnect, project switch, or app reopen must not replay
                    // a turn whose effects are uncertain. Only Scan again clears it.
                    // A cancelled predecessor must not pause a replacement scan;
                    // its unresolved pending marker remains available for recovery.
                    guard self.generation == currentGeneration else { return }
                    UserDefaults.standard.set(interruption.reason, forKey: self.interruptionKey(expectedProject))
                    guard store.project.id == expectedProject, store.navigationContext == navigation else { return }
                    self.failed[key] = interruption.reason; self.paused = true
                    self.publish("Character scan paused. " + interruption.reason)
                    return // Never replay uncertain turns or continue the queue after tool activity.
                }
                catch {
                    // A normal provider error has a known outcome. The Codex
                    // adapter classifies uncertain outcomes as interruption.
                    do { try self.clearPending(projectID:expectedProject,attempt:attempt) }
                    catch {
                        guard self.generation == currentGeneration, store.project.id == expectedProject, store.navigationContext == navigation else { return }
                        self.paused = true; self.publish("Character scan paused: its pending marker could not be cleared."); return
                    }
                    guard self.generation == currentGeneration, store.project.id == expectedProject, store.navigationContext == navigation else { return }
                    self.failed[key] = error.localizedDescription
                }
            }
            if !self.failed.isEmpty { self.publish("\(self.checkedCount) of \(store.project.images.count) checked · \(self.failed.count) need retry. " + (self.failed.sorted { $0.key < $1.key }.first?.value ?? "")) }
            else if waitingForBytes > 0 { self.publish("\(self.checkedCount) of \(store.project.images.count) checked · \(waitingForBytes) waiting for images on this device") }
            else { self.publish("\(self.checkedCount) of \(store.project.images.count) images checked · \(self.reviewImageCount) need review") }
        }
    }
    private func analyzeWithRetry(_ request: CharacterImageAnalysisRequest) async throws -> CharacterImageAnalysisResult {
        do { return try await provider.analyze(request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cannotConnectToHost {
            // Retry only a completed transient failure; never replay an uncertain turn.
            try await Task.sleep(for:.seconds(2)); try Task.checkCancellation()
            guard availability == nil else { throw error }
            return try await provider.analyze(request)
        }
    }
    private func context(_ image: ImageAsset, project: ScrivProject) -> String {
        let sceneIDs = Set(project.cues.filter { $0.imageId == image.id }.map(\.sceneId))
        let script = project.entries.filter { sceneIDs.contains($0.sceneId) }.map(\.text).joined(separator:"\n")
        return String(("Image direction: " + image.prompt + "\nScene script:\n" + script).prefix(12000))
    }
}

/// Device-local derived thumbnails, keyed by original digest + crop coordinates.
/// ImageIO applies orientation before the top-left crop. The original is read-only.
enum CharacterPortraitCache {
    static func thumbnail(source: URL, sha256: String, region: NormalizedCharacterRegion) async throws -> URL {
        guard region.isValid else { throw ScrivError.invalid("The portrait crop is outside this image.") }
        return try await Task.detached(priority:.utility) {
            // A cache key must be deterministic: JSONEncoder's key order is not
            // guaranteed without .sortedKeys, so identical crops missed the cache.
            let key = ScrivDigest.sha256(try ScrivJSON.encoder.encode(CharacterPortraitRegion(imageID:"",imageSHA256:sha256,region:region)))
            let root = FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("Scriv/CharacterPortraits",isDirectory:true)
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            let output = root.appendingPathComponent(key).appendingPathExtension("png")
            if FileManager.default.fileExists(atPath:output.path) { return output }
            let data = try Data(contentsOf:source,options:.mappedIfSafe)
            guard ScrivDigest.sha256(data) == sha256 else { throw ScrivError.invalid("The source image no longer matches this portrait.") }
            guard let imageSource = CGImageSourceCreateWithData(data as CFData,nil),
                  let oriented = CGImageSourceCreateThumbnailAtIndex(imageSource,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:2048] as CFDictionary) else { throw ScrivError.invalid("This image could not be cropped.") }
            let bounds = CGRect(x:region.x * Double(oriented.width),y:region.y * Double(oriented.height),width:region.width * Double(oriented.width),height:region.height * Double(oriented.height)).integral.intersection(CGRect(x:0,y:0,width:CGFloat(oriented.width),height:CGFloat(oriented.height)))
            guard !bounds.isEmpty, let cropped = oriented.cropping(to:bounds) else { throw ScrivError.invalid("The portrait region is empty.") }
            let temporary = root.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
            defer { try? FileManager.default.removeItem(at:temporary) }
            guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL,"public.png" as CFString,1,nil) else { throw ScrivError.unavailable("Portrait cache could not be written.") }
            CGImageDestinationAddImage(destination,cropped,nil)
            guard CGImageDestinationFinalize(destination) else { throw ScrivError.unavailable("Portrait cache could not be saved.") }
            do { try FileManager.default.moveItem(at:temporary,to:output) } catch { guard FileManager.default.fileExists(atPath:output.path) else { throw error } }
            return output
        }.value
    }
}
