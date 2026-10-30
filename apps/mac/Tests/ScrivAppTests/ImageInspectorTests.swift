import XCTest
import ScrivCore
@testable import ScrivApp

final class ImageInspectorTests: XCTestCase {
    func testInspectorDoesNotFollowPreferredPlacementToAnotherVersion() {
        let project = fixture()
        let cue = ImageInspectorContext.placement(imageID: "original", cueID: "changed-placement", project: project)
        XCTAssertEqual(cue?.id, "original-placement")
        XCTAssertEqual(cue?.imageId, "original")
        XCTAssertEqual(ImageInspectorContext.title(imageID: "original", cueID: "changed-placement", project: project), "The original shot")
    }

    func testUnplacedHistoricalVersionDoesNotInventAScriptDestination() {
        var project = fixture()
        project.cues.removeAll { $0.imageId == "original" }
        XCTAssertNil(ImageInspectorContext.placement(imageID: "original", cueID: "changed-placement", project: project))
        XCTAssertEqual(ImageInspectorContext.title(imageID: "original", cueID: "changed-placement", project: project), "Image")
    }

    func testPreferredExactPlacementWinsOverOtherUsesOfSameAsset() {
        var project = fixture()
        project.cues.append(ImageCue(id: "another-use", sceneId: "scene", imageId: "original", label: "Another moment", startMs: 2000, endMs: 3000))
        XCTAssertEqual(ImageInspectorContext.placement(imageID: "original", cueID: "another-use", project: project)?.id, "another-use")
        XCTAssertEqual(ImageInspectorContext.title(imageID: "original", cueID: "another-use", project: project), "Another moment")
        XCTAssertEqual(project.images[0].generationPrompt, "Exact submitted prompt\nOriginal source.")
    }

    func testUnplacedPortraitHasTruthfulTitleWithoutFakePlacement() {
        var project = fixture()
        project.cues.removeAll { $0.imageId == "original" }
        project.characters = [ScriptCharacter(id: "mara", name: "Mara", portraitImageId: "original")]
        XCTAssertEqual(ImageInspectorContext.title(imageID: "original", project: project), "Mara portrait")
        XCTAssertNil(ImageInspectorContext.placement(imageID: "original", cueID: nil, project: project))
    }

    private func fixture() -> ScrivProject {
        ScrivProject(scenes: [ScriptScene(id: "scene")], images: [
            ImageAsset(id: "original", version: 1, fileName: "original.png", sha256: "a", byteCount: 1, prompt: "Manual direction", generationPrompt: "Exact submitted prompt\nOriginal source."),
            ImageAsset(id: "new", version: 2, fileName: "new.png", sha256: "b", byteCount: 1, previousVersionId: "original")
        ], cues: [
            ImageCue(id: "changed-placement", sceneId: "scene", imageId: "new", label: "The new shot", startMs: 0, endMs: 1000),
            ImageCue(id: "original-placement", sceneId: "scene", imageId: "original", label: "The original shot", startMs: 1000, endMs: 2000)
        ])
    }
}
