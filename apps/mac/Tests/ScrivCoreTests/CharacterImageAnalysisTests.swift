import XCTest
@testable import ScrivCore

final class CharacterImageAnalysisTests: XCTestCase {
    private let fixtureSHA256 = String(repeating:"a",count:64)
    private let face = NormalizedCharacterRegion(x:0.1,y:0.1,width:0.2,height:0.3)
    private let other = NormalizedCharacterRegion(x:0.6,y:0.2,width:0.25,height:0.6)
    private func project() -> ScrivProject {
        ScrivProject(id:"project",characters:[ScriptCharacter(id:"mara",name:"Mara",aliases:["Captain"]),ScriptCharacter(id:"eli",name:"Eli")],images:[ImageAsset(id:"image",fileName:"original.png",sha256:fixtureSHA256,byteCount:100)])
    }
    private func apply(_ detections: [CharacterImageDetection], _ project: inout ScrivProject) throws {
        try CharacterImageAnalysis.apply(.init(detections:detections),to:&project,imageID:"image",version:1,sha256:fixtureSHA256,providerID:"synthetic-test")
    }
    func testDistinctCanonicalCharactersAndUnknownCandidateUseSeparateRegions() throws {
        var p = project()
        try apply([.init(region:face,characterID:"mara",confidence:0.96),.init(region:other,characterID:"eli",confidence:0.94),.init(region:.init(x:0.4,y:0.4,width:0.1,height:0.2),kind:.obscured,suggestedName:"Hooded traveler",confidence:0.99)],&p)
        XCTAssertEqual(p.images[0].characterIds,["eli","mara"])
        XCTAssertEqual(p.characters.count,2,"An unknown candidate is not an invented canonical identity")
        XCTAssertEqual(p.images[0].characterAnalysis?.annotations.filter { $0.decision == .needsReview }.count,1)
        XCTAssertEqual(p.character("mara")?.portraitRegion?.region,face)
        XCTAssertEqual(p.images[0].fileName,"original.png"); XCTAssertEqual(p.images[0].sha256,fixtureSHA256); XCTAssertEqual(p.images[0].byteCount,100)
    }
    func testUnknownIDPartialObscuredAndLowConfidenceNeverAutoTag() throws {
        for (kind,id,confidence) in [(CharacterImageRegionKind.partial,"mara",1.0),(.obscured,"mara",1.0),(.face,"missing",1.0),(.face,"mara",0.87)] {
            var p = project(); try apply([.init(region:face,kind:kind,characterID:id,confidence:confidence)],&p)
            XCTAssertTrue(p.images[0].characterIds.isEmpty); XCTAssertEqual(p.images[0].characterAnalysis?.annotations.first?.decision,.needsReview)
        }
    }
    func testFaceAndBodySubjectGroupDeduplicatesButTwoDifferentPeopleDoNot() throws {
        var p = project()
        try apply([.init(region:other,kind:.figure,characterID:"mara",confidence:0.95,subjectKey:"subject-a"),.init(region:face,characterID:"mara",confidence:0.95,subjectKey:"subject-a"),.init(region:face,characterID:"eli",confidence:0.95,subjectKey:"subject-b")],&p)
        XCTAssertEqual(p.images[0].characterAnalysis?.annotations.count,2)
        XCTAssertEqual(p.images[0].characterIds,["eli","mara"])
    }
    func testRepeatedResultsHaveStableRegionIDsAndCanonicalCharacterIDs() throws {
        var p = project(); let result = [CharacterImageDetection(region:face,characterID:"mara",confidence:0.99)]
        try apply(result,&p); let ids = p.images[0].characterAnalysis?.annotations.map(\.id), characters = p.characters.map(\.id)
        try apply(result,&p)
        XCTAssertEqual(p.images[0].characterAnalysis?.annotations.map(\.id),ids); XCTAssertEqual(p.characters.map(\.id),characters); XCTAssertEqual(p.images[0].characterIds,["mara"])
    }
    func testStaleVersionAndStaleHashAreRejectedWithoutMutation() throws {
        for (version,fixtureSHA256) in [(2,self.fixtureSHA256),(1,String(repeating:"b",count:64))] {
            var p = project(); let before = p
            XCTAssertThrowsError(try CharacterImageAnalysis.apply(.init(detections:[]),to:&p,imageID:"image",version:version,sha256:fixtureSHA256,providerID:"test"))
            XCTAssertEqual(p,before)
        }
    }
    func testManualLabelsAndExplicitRemovalSurviveRescan() throws {
        var p = project(); p.images[0].characterIds = ["eli"]
        let result = [CharacterImageDetection(region:face,characterID:"mara",confidence:0.99)]
        try apply(result,&p)
        CharacterImageAnalysis.setManualTags(&p.images[0],characterIDs:["eli"])
        try apply(result,&p)
        XCTAssertEqual(p.images[0].characterIds,["eli"])
        XCTAssertEqual(p.images[0].characterAnalysis?.annotations.first?.decision,.ignored)
        XCTAssertEqual(p.images[0].characterAnalysis?.excludedCharacterIDs,["mara"])
    }
    func testManualRemovalBeforeFirstAnalysisIsNotMistakenForCompletedScan() throws {
        var p = project(); p.images[0].characterIds = ["mara"]
        CharacterImageAnalysis.setManualTags(&p.images[0],characterIDs:[])
        XCTAssertEqual(p.images[0].characterAnalysis?.providerID,"manual")
        try apply([.init(region:face,characterID:"mara",confidence:0.99)],&p)
        XCTAssertTrue(p.images[0].characterIds.isEmpty)
    }
    func testUserCorrectionWinsOverRepeatedAndSlightlyShiftedModelResults() throws {
        var p = project(); try apply([.init(region:face,characterID:"mara",confidence:0.5)],&p)
        let id = try XCTUnwrap(p.images[0].characterAnalysis?.annotations.first?.id)
        try CharacterImageAnalysis.resolve(&p,imageID:"image",sha256:fixtureSHA256,annotationID:id,characterID:"eli")
        try apply([.init(region:.init(x:0.105,y:0.105,width:0.2,height:0.3),characterID:"mara",confidence:0.99)],&p)
        XCTAssertEqual(p.images[0].characterAnalysis?.annotations.count,1)
        XCTAssertEqual(p.images[0].characterAnalysis?.annotations.first?.characterID,"eli")
        XCTAssertEqual(p.images[0].characterAnalysis?.annotations.first?.decision,.confirmed)
        XCTAssertEqual(p.images[0].characterIds,["eli"])
    }
    func testNewNameUsesCanonicalAliasAndOnlyExplicitNewNameCreatesCharacter() throws {
        var p = project(); try apply([.init(region:face,confidence:0.5)],&p)
        let id = try XCTUnwrap(p.images[0].characterAnalysis?.annotations.first?.id)
        try CharacterImageAnalysis.resolve(&p,imageID:"image",sha256:fixtureSHA256,annotationID:id,characterID:nil,newName:" captain ")
        XCTAssertEqual(p.characters.count,2); XCTAssertEqual(p.images[0].characterIds,["mara"])
        var q = project(); try apply([.init(region:face,confidence:0.5)],&q)
        try CharacterImageAnalysis.resolve(&q,imageID:"image",sha256:fixtureSHA256,annotationID:id,characterID:nil,newName:"Traveler")
        XCTAssertEqual(q.characters.count,3); XCTAssertEqual(q.characters.last?.portraitRegion?.region,face)
    }
    func testIgnoreDoesNotCreatePendingNewNameAndStaysIgnored() throws {
        var p = project(); try apply([.init(region:face,confidence:0.5)],&p)
        let id = try XCTUnwrap(p.images[0].characterAnalysis?.annotations.first?.id)
        try CharacterImageAnalysis.resolve(&p,imageID:"image",sha256:fixtureSHA256,annotationID:id,characterID:nil,newName:"Do not create",ignore:true)
        try apply([.init(region:face,characterID:"mara",confidence:0.99)],&p)
        XCTAssertEqual(p.characters.count,2); XCTAssertTrue(p.images[0].characterIds.isEmpty); XCTAssertEqual(p.images[0].characterAnalysis?.annotations.first?.decision,.ignored)
    }
    func testInvalidBoundsNonfiniteAndOutOfRangeConfidenceAreRejected() throws {
        for detection in [CharacterImageDetection(region:.init(x:-0.1,y:0,width:1,height:1),confidence:0.9),.init(region:face,confidence:.infinity),.init(region:face,confidence:1.01),.init(region:.init(x:0,y:0,width:0,height:1),confidence:0.9)] {
            var p = project(); let before = p; XCTAssertThrowsError(try apply([detection],&p)); XCTAssertEqual(p,before)
        }
    }
    func testCloudAndPackageRoundTripKeepAnnotationsCropsAndOriginalBytesMetadata() throws {
        var p = project(); try apply([.init(region:face,characterID:"mara",confidence:0.99)],&p)
        let restored = try CloudCodec.applying(CloudCodec.items(from:p),to:p)
        XCTAssertEqual(restored.images,p.images); XCTAssertEqual(restored.characters,p.characters)
        XCTAssertNoThrow(try TimingEngine.validate(restored))
        let legacy = project(); XCTAssertNil(try ScrivJSON.decoder.decode(ScrivProject.self,from:ScrivJSON.encoder.encode(legacy)).images[0].characterAnalysis)
    }
    func testChangingPortraitClearsCropFromPreviousVersion() throws {
        var p = project(); try apply([.init(region:face,characterID:"mara",confidence:0.99)],&p)
        p.images.append(ImageAsset(id:"second",fileName:"second.png",sha256:String(repeating:"b",count:64),byteCount:100))
        try ProjectEditing.setPortrait(&p,characterId:"mara",imageId:"second")
        XCTAssertNil(p.character("mara")?.portraitRegion); XCTAssertEqual(p.character("mara")?.portraitImageId,"second")
    }
    func testRemovingWrongAutomaticTagClearsItsCropButPreservesChosenPortrait() throws {
        var p = project(); try apply([.init(region:face,characterID:"mara",confidence:0.99)],&p)
        CharacterImageAnalysis.setManualTags(&p,imageID:"image",characterIDs:[])
        XCTAssertNil(p.character("mara")?.portraitRegion); XCTAssertNil(p.character("mara")?.portraitImageId)
        var q = project(); try apply([.init(region:face,characterID:"mara",confidence:0.99)],&q)
        try ProjectEditing.setPortrait(&q,characterId:"mara",imageId:"image")
        CharacterImageAnalysis.setManualTags(&q,imageID:"image",characterIDs:[])
        XCTAssertNotNil(q.character("mara")?.portraitRegion); XCTAssertEqual(q.character("mara")?.portraitImageId,"image")
    }

    func testStaleReviewCannotReplaceAnotherUsersConfirmedCharacter() throws {
        var p = project(); try apply([.init(region:face,confidence:0.5)],&p)
        let original = try XCTUnwrap(p.images[0].characterAnalysis?.annotations.first)
        try CharacterImageAnalysis.resolve(&p,imageID:"image",sha256:fixtureSHA256,annotationID:original.id,characterID:"eli",expectedAnnotation:original)
        let accepted = p
        XCTAssertThrowsError(try CharacterImageAnalysis.resolve(&p,imageID:"image",sha256:fixtureSHA256,annotationID:original.id,characterID:"mara",expectedAnnotation:original))
        XCTAssertEqual(p,accepted)
    }

}
