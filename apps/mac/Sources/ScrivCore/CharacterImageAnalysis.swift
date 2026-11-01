import Foundation

/// Image-space coordinates, measured from the top-left after EXIF orientation.
/// A derived portrait never changes the image's immutable bytes or version ID.
public struct NormalizedCharacterRegion: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
    public var isValid: Bool { [x,y,width,height].allSatisfy(\.isFinite) && x >= 0 && y >= 0 && width > 0 && height > 0 && x + width <= 1.000001 && y + height <= 1.000001 }
    public func overlap(_ other: Self) -> Double {
        let intersection = max(0,min(x + width,other.x + other.width) - max(x,other.x)) * max(0,min(y + height,other.y + other.height) - max(y,other.y))
        return intersection / max(0.000001,min(width * height,other.width * other.height))
    }
}
public enum CharacterImageRegionKind: String, Codable, Sendable { case face, figure, partial, obscured }
public enum CharacterImageDecision: String, Codable, Sendable { case automatic, needsReview, confirmed, ignored }
public struct CharacterImageDetection: Codable, Hashable, Sendable {
    public var region: NormalizedCharacterRegion
    public var portraitRegion: NormalizedCharacterRegion?
    public var kind: CharacterImageRegionKind
    public var characterID: String?
    public var suggestedName: String?
    public var confidence: Double
    public var reason: String
    /// Groups a face/body/hand belonging to one depicted subject, never an identity.
    public var subjectKey: String?
    public init(region: NormalizedCharacterRegion, portraitRegion: NormalizedCharacterRegion? = nil, kind: CharacterImageRegionKind = .face, characterID: String? = nil, suggestedName: String? = nil, confidence: Double, reason: String = "", subjectKey: String? = nil) {
        self.region = region; self.portraitRegion = portraitRegion; self.kind = kind; self.characterID = characterID; self.suggestedName = suggestedName; self.confidence = confidence; self.reason = reason; self.subjectKey = subjectKey
    }
}
public struct CharacterImageAnalysisResult: Codable, Hashable, Sendable {
    public var detections: [CharacterImageDetection]
    public init(detections: [CharacterImageDetection]) { self.detections = detections }
}
public struct CharacterImageAnalysisRequest: Sendable {
    public let projectID: String
    public let imageID: String
    public let imageVersion: Int
    public let imageSHA256: String
    public let imageURL: URL
    public let context: String
    public let characters: [ScriptCharacter]
    public init(projectID: String, imageID: String, imageVersion: Int, imageSHA256: String, imageURL: URL, context: String, characters: [ScriptCharacter]) {
        self.projectID = projectID; self.imageID = imageID; self.imageVersion = imageVersion; self.imageSHA256 = imageSHA256; self.imageURL = imageURL; self.context = context; self.characters = characters
    }
}
/// Future connections use the same capability-gated boundary. A nil availability
/// message means analysis is ready, not that image generation is available.
@MainActor public protocol CharacterImageAnalysisProvider: AnyObject {
    var providerID: String { get }
    var availability: String? { get }
    func analyze(_ request: CharacterImageAnalysisRequest) async throws -> CharacterImageAnalysisResult
}
public struct CharacterImageAnnotation: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var region: NormalizedCharacterRegion
    public var portraitRegion: NormalizedCharacterRegion
    public var kind: CharacterImageRegionKind
    public var characterID: String?
    public var suggestedName: String?
    public var confidence: Double
    public var reason: String
    public var decision: CharacterImageDecision
}
public struct ImageCharacterAnalysis: Codable, Hashable, Sendable {
    public var imageSHA256: String
    public var imageVersion: Int
    public var providerID: String
    public var completedAt: Date
    public var annotations: [CharacterImageAnnotation]
    /// Explicit tag removals survive every retry/rescan, including zero detections.
    public var excludedCharacterIDs: [String]
    public var manualCharacterIDs: [String]
    public init(imageSHA256: String, imageVersion: Int, providerID: String, completedAt: Date = ScrivClock.now, annotations: [CharacterImageAnnotation] = [], excludedCharacterIDs: [String] = [], manualCharacterIDs: [String] = []) {
        self.imageSHA256 = imageSHA256; self.imageVersion = imageVersion; self.providerID = providerID; self.completedAt = completedAt; self.annotations = annotations; self.excludedCharacterIDs = excludedCharacterIDs; self.manualCharacterIDs = manualCharacterIDs
    }
    public func matches(_ image: ImageAsset) -> Bool { imageSHA256 == image.sha256 && imageVersion == image.version }
}
public struct CharacterPortraitRegion: Codable, Hashable, Sendable {
    public var imageID: String
    public var imageSHA256: String
    public var region: NormalizedCharacterRegion
    public var isAutomatic: Bool?
    public init(imageID: String, imageSHA256: String, region: NormalizedCharacterRegion, isAutomatic: Bool = true) { self.imageID = imageID; self.imageSHA256 = imageSHA256; self.region = region; self.isAutomatic = isAutomatic }
}

/// Pure, deterministic merge policy. Only canonical IDs with strong evidence are
/// auto-tagged. Unnamed, obscured and partial candidates stay visible for review.
public enum CharacterImageAnalysis {
    public static func validate(image: ImageAsset, characterIDs: Set<String>) throws {
        guard let analysis = image.characterAnalysis else { return }
        guard analysis.matches(image), !analysis.providerID.isEmpty, analysis.providerID.count <= 200, analysis.completedAt.timeIntervalSince1970.isFinite,
              analysis.annotations.count <= 100, Set(analysis.annotations.map(\.id)).count == analysis.annotations.count,
              analysis.manualCharacterIDs.count <= 100, analysis.manualCharacterIDs.allSatisfy(characterIDs.contains), analysis.excludedCharacterIDs.count <= 100 else { throw ScrivError.invalid("Image character analysis does not match this version.") }
        for annotation in analysis.annotations {
            guard !annotation.id.isEmpty, annotation.id.count <= 128, annotation.region.isValid, annotation.portraitRegion.isValid,
                  annotation.confidence.isFinite, (0...1).contains(annotation.confidence), annotation.reason.count <= 1000,
                  (annotation.suggestedName?.count ?? 0) <= 200, annotation.characterID.map(characterIDs.contains) ?? true,
                  (annotation.decision != .automatic && annotation.decision != .confirmed) || annotation.characterID != nil else { throw ScrivError.invalid("Invalid character image annotation.") }
        }
    }
    public static func workKey(projectID: String, image: ImageAsset) -> String { "\(projectID):\(image.id):\(image.version):\(image.sha256)" }
    public static func apply(_ result: CharacterImageAnalysisResult, to project: inout ScrivProject, imageID: String, version: Int, sha256: String, providerID: String) throws {
        guard let index = project.images.firstIndex(where: { $0.id == imageID }), project.images[index].version == version, project.images[index].sha256 == sha256 else { throw ScrivError.conflict("This image version changed while characters were checked. The result was discarded.") }
        guard result.detections.count <= 100 else { throw ScrivError.invalid("The analysis returned too many character regions.") }
        let image = project.images[index], old = image.characterAnalysis.flatMap { $0.matches(image) ? $0 : nil }
        var annotations = old?.annotations.filter { $0.decision == .confirmed || $0.decision == .ignored } ?? []
        let protectedIDs = Set(annotations.map(\.id))
        let excluded = Set(old?.excludedCharacterIDs ?? [])
        let known = Set(project.characters.map(\.id))
        var subjects: [String] = []
        for (_,detection) in result.detections.enumerated().sorted(by: { ($0.element.kind == .face ? 0 : 1,$0.offset) < ($1.element.kind == .face ? 0 : 1,$1.offset) }) {
            guard detection.region.isValid, (detection.portraitRegion?.isValid ?? true), detection.confidence.isFinite, (0...1).contains(detection.confidence), detection.reason.count <= 1000, (detection.suggestedName?.utf16.count ?? 0) <= 200, (detection.characterID?.utf16.count ?? 0) <= 128, (detection.subjectKey?.utf16.count ?? 0) <= 128 else { throw ScrivError.invalid("The analysis returned an invalid character region.") }
            let id = "region-" + String(ScrivDigest.sha256(Data("\(imageID):\(version):\(sha256):\(detection.characterID ?? detection.subjectKey ?? ""):\(Int(detection.region.x * 1000)):\(Int(detection.region.y * 1000)):\(Int(detection.region.width * 1000)):\(Int(detection.region.height * 1000))".utf8)).prefix(24))
            // User decisions win even when the model moves its box slightly.
            if annotations.contains(where: { prior in
                let compatible = prior.characterID == nil || detection.characterID == nil || prior.characterID == detection.characterID
                return prior.id == id || ((protectedIDs.contains(prior.id) || compatible) && prior.region.overlap(detection.region) > 0.8)
            }) { continue }
            if let subject = detection.subjectKey, !subject.isEmpty, subjects.contains(subject) { continue }
            if let subject = detection.subjectKey, !subject.isEmpty { subjects.append(subject) }
            let canonical = detection.characterID.flatMap { known.contains($0) ? $0 : nil }
            let confident = canonical != nil && detection.confidence >= 0.88 && detection.kind != .partial && detection.kind != .obscured
            let decision: CharacterImageDecision = canonical.map { excluded.contains($0) } == true ? .ignored : confident ? .automatic : .needsReview
            annotations.append(CharacterImageAnnotation(id:String(id), region:detection.region, portraitRegion:detection.portraitRegion ?? detection.region, kind:detection.kind, characterID:canonical, suggestedName:detection.suggestedName, confidence:detection.confidence, reason:detection.reason, decision:decision))
        }
        project.images[index].characterAnalysis = ImageCharacterAnalysis(imageSHA256:sha256, imageVersion:version, providerID:providerID, annotations:annotations, excludedCharacterIDs:Array(excluded).sorted(), manualCharacterIDs:old?.manualCharacterIDs ?? image.characterIds)
        var tags = Set(old?.manualCharacterIDs ?? image.characterIds).intersection(known).subtracting(excluded)
        for annotation in annotations where annotation.decision == .automatic || annotation.decision == .confirmed {
            guard let characterID = annotation.characterID, known.contains(characterID), !excluded.contains(characterID) else { continue }
            tags.insert(characterID)
            if let person = project.characters.firstIndex(where: { $0.id == characterID }), (project.characters[person].portraitImageId == nil || (project.characters[person].portraitImageId == imageID && project.characters[person].portraitRegion == nil)) {
                project.characters[person].portraitImageId = imageID
                project.characters[person].portraitRegion = CharacterPortraitRegion(imageID:imageID, imageSHA256:sha256, region:annotation.portraitRegion)
            }
        }
        project.images[index].characterIds = Array(tags).sorted()
    }
    public static func resolve(_ project: inout ScrivProject, imageID: String, sha256: String, annotationID: String, characterID: String?, newName: String? = nil, ignore: Bool = false, expectedAnnotation: CharacterImageAnnotation? = nil) throws {
        guard let imageIndex = project.images.firstIndex(where: { $0.id == imageID && $0.sha256 == sha256 }), var analysis = project.images[imageIndex].characterAnalysis, analysis.matches(project.images[imageIndex]), let regionIndex = analysis.annotations.firstIndex(where: { $0.id == annotationID }) else { throw ScrivError.conflict("This image changed. Reopen its character review.") }
        if let expectedAnnotation, analysis.annotations[regionIndex] != expectedAnnotation { throw ScrivError.conflict("This character was reviewed elsewhere. Reopen the image to use the latest tag.") }
        var id = characterID
        if let newName, !ignore {
            let name = newName.trimmingCharacters(in:.whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 200 else { throw ScrivError.invalid("Enter a character name of 1–200 characters.") }
            if let existing = project.characters.first(where: { ([$0.name] + $0.aliases).contains { $0.compare(name,options:[.caseInsensitive,.diacriticInsensitive]) == .orderedSame } }) { id = existing.id }
            else { let character = ScriptCharacter(name:name); id = character.id; project.characters.append(character) }
        }
        guard ignore || project.characters.contains(where: { $0.id == id }) else { throw ScrivError.invalid("Choose a character or give this character a name.") }
        let previousID = analysis.annotations[regionIndex].characterID
        analysis.annotations[regionIndex].characterID = ignore ? nil : id
        analysis.annotations[regionIndex].decision = ignore ? .ignored : .confirmed
        if let id, !ignore {
            analysis.excludedCharacterIDs.removeAll { $0 == id }
            if !project.images[imageIndex].characterIds.contains(id) { project.images[imageIndex].characterIds.append(id) }
            if let person = project.characters.firstIndex(where: { $0.id == id }), (project.characters[person].portraitImageId == nil || (project.characters[person].portraitImageId == imageID && project.characters[person].portraitRegion == nil)) {
                project.characters[person].portraitImageId = imageID
                project.characters[person].portraitRegion = CharacterPortraitRegion(imageID:imageID,imageSHA256:sha256,region:analysis.annotations[regionIndex].portraitRegion)
            }
        }
        if let previousID, previousID != id || ignore, !analysis.annotations.contains(where: { $0.characterID == previousID && ($0.decision == .confirmed || $0.decision == .automatic) }) {
            project.images[imageIndex].characterIds.removeAll { $0 == previousID }
            if !analysis.excludedCharacterIDs.contains(previousID) { analysis.excludedCharacterIDs.append(previousID) }
            if let person = project.characters.firstIndex(where: { $0.id == previousID }), let portrait = project.characters[person].portraitRegion,
               portrait.imageID == imageID, portrait.isAutomatic != false {
                project.characters[person].portraitImageId = nil; project.characters[person].portraitRegion = nil
            }
        }
        project.images[imageIndex].characterAnalysis = analysis
    }
    public static func setManualTags(_ project: inout ScrivProject, imageID: String, characterIDs: [String]) {
        guard let index = project.images.firstIndex(where: { $0.id == imageID }) else { return }
        let removed = Set(project.images[index].characterIds).subtracting(characterIDs)
        setManualTags(&project.images[index],characterIDs:characterIDs)
        for person in project.characters.indices where removed.contains(project.characters[person].id) {
            if let crop = project.characters[person].portraitRegion, crop.imageID == imageID, crop.isAutomatic != false {
                project.characters[person].portraitImageId = nil; project.characters[person].portraitRegion = nil
            }
        }
    }
    public static func setManualTags(_ image: inout ImageAsset, characterIDs: [String]) {
        let chosen = Set(characterIDs), removed = Set(image.characterIds).subtracting(chosen)
        if var analysis = image.characterAnalysis {
            analysis.excludedCharacterIDs = Array(Set(analysis.excludedCharacterIDs).union(removed).subtracting(chosen)).sorted()
            analysis.manualCharacterIDs = Array(chosen).sorted()
            for index in analysis.annotations.indices {
                guard let id = analysis.annotations[index].characterID else { continue }
                if removed.contains(id) { analysis.annotations[index].decision = .ignored }
                else if chosen.contains(id) { analysis.annotations[index].decision = .confirmed }
            }
            image.characterAnalysis = analysis
        } else if !removed.isEmpty {
            // No completed analysis yet; this marker is not considered scanned.
            image.characterAnalysis = ImageCharacterAnalysis(imageSHA256:image.sha256,imageVersion:image.version,providerID:"manual",excludedCharacterIDs:Array(removed).sorted(),manualCharacterIDs:Array(chosen).sorted())
        }
        image.characterIds = Array(chosen).sorted()
    }
}
