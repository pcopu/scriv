import XCTest
@testable import ScrivCore

final class CodexCharacterAnalysisProtocolTests: XCTestCase {
    private let cwd = URL(fileURLWithPath: "/tmp/ScrivAnalysisTest").resolvingSymlinksInPath().standardizedFileURL
    private var validThread: [String: JSONValue] {
        ["sandbox": .object(["type": .string("readOnly"), "networkAccess": .bool(false)]), "approvalPolicy": .string("never"), "model": .string("vision-model"), "cwd": .string(cwd.path), "thread": .object(["id": .string("owned"), "ephemeral": .bool(true)])]
    }
    func testThreadMustConfirmExactReadOnlyNoNetworkModelAndWorkingDirectory() throws {
        XCTAssertEqual(try CodexCharacterAnalysisProtocol.validateThread(.object(validThread), model: "vision-model", cwd: cwd), "owned")
        let invalid: [String: JSONValue] = [
            "sandbox": .object(["type": .string("dangerFullAccess")]), "approvalPolicy": .string("on-request"), "model": .string("other"), "cwd": .string("/"), "thread": .object(["id": .string("owned"), "ephemeral": .bool(false)])
        ]
        for (key, value) in invalid {
            var changed = validThread; changed[key] = value
            XCTAssertThrowsError(try CodexCharacterAnalysisProtocol.validateThread(.object(changed), model: "vision-model", cwd: cwd)) { XCTAssertTrue($0 is CharacterAnalysisInterruption, key) }
        }
        let policies: [JSONValue] = [.object(["type": .string("readOnly")]), .object(["type": .string("readOnly"), "networkAccess": .bool(true)])]
        for policy in policies {
            var changed = validThread; changed["sandbox"] = policy
            XCTAssertThrowsError(try CodexCharacterAnalysisProtocol.validateThread(.object(changed), model: "vision-model", cwd: cwd))
        }
    }
    func testPromptContainsOnlyBoundedExplicitCharacterAndImageContext() {
        let character = ScriptCharacter(id: "mara", name: "Mara", aliases: ["M"], biography: "PRIVATE-BIOGRAPHY-NOT-NEEDED", appearance: "red cloak")
        let request = CharacterImageAnalysisRequest(projectID: "project", imageID: "image", imageVersion: 1, imageSHA256: "sha", imageURL: URL(fileURLWithPath: "/never/read/project.png"), context: String(repeating: "story 🎬", count: 10_000), characters: Array(repeating: character, count: 500))
        let prompt = CodexCharacterAnalysisProtocol.prompt(request)
        XCTAssertTrue(prompt.contains("mara")); XCTAssertTrue(prompt.contains("red cloak")); XCTAssertTrue(prompt.contains("subjectKey"))
        XCTAssertFalse(prompt.contains("PRIVATE-BIOGRAPHY-NOT-NEEDED")); XCTAssertFalse(prompt.contains("/never/read")); XCTAssertLessThan(prompt.utf8.count, 65_536)
    }
    func testSchemaAndValidResultKeepUnknownCandidatesForReview() throws {
        let result = CharacterImageAnalysisResult(detections: [.init(region: .init(x: 0.1, y: 0.2, width: 0.3, height: 0.4), kind: .obscured, confidence: 0.4, reason: "Hood covers face", subjectKey: "person-1")])
        let text = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        XCTAssertEqual(try CodexCharacterAnalysisProtocol.decode(text), result)
        XCTAssertEqual(CodexCharacterAnalysisProtocol.outputSchema["additionalProperties"], .bool(false))
        XCTAssertEqual(CodexCharacterAnalysisProtocol.outputSchema["properties"]?["detections"]?["maxItems"], .number(100))
        XCTAssertTrue(CodexCharacterAnalysisProtocol.developerInstructions.contains("Do not call tools"))
    }
    func testMalformedOversizedAndOutOfBoundsResultsAreRejected() throws {
        for text in ["not JSON", "```json\n{\"detections\":[]}\n```", String(repeating: "x", count: 65_537)] { XCTAssertThrowsError(try CodexCharacterAnalysisProtocol.decode(text)) }
        let invalid = [
            CharacterImageDetection(region: .init(x: 0.9, y: 0.1, width: 0.5, height: 0.4), confidence: 0.9),
            CharacterImageDetection(region: .init(x: 0, y: 0, width: 1, height: 1), confidence: 1.1),
            CharacterImageDetection(region: .init(x: 0, y: 0, width: 1, height: 1), confidence: 0.5, reason: String(repeating: "x", count: 1001))
        ]
        for detection in invalid {
            let text = String(decoding: try JSONEncoder().encode(CharacterImageAnalysisResult(detections: [detection])), as: UTF8.self)
            XCTAssertThrowsError(try CodexCharacterAnalysisProtocol.decode(text))
        }
        let tooMany = CharacterImageAnalysisResult(detections: Array(repeating: .init(region: .init(x: 0, y: 0, width: 1, height: 1), confidence: 0.5), count: 101))
        XCTAssertThrowsError(try CodexCharacterAnalysisProtocol.decode(String(decoding: JSONEncoder().encode(tooMany), as: UTF8.self)))
    }
}
