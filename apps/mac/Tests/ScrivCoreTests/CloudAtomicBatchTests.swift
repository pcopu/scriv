import XCTest
@testable import ScrivCore

final class CloudAtomicBatchTests: XCTestCase {
    private func command(_ count: Int, text: String = "") -> JSONValue {
        .object(["commandId":.string("command"),"sessionId":.string("editor"),"epoch":.number(1),"expectedTimingVersion":.number(8),"label":.string("Resize long scene"),"operations":.array((0..<count).map { .object(["op":.string("put"),"id":.string("cue-\($0)"),"expectedVersion":.number(9),"data":.object(["prompt":.string(text)])]) })])
    }
    func testOneThousandChangesAreImmutableTransportPartsOfOneCommand() throws {
        let original = command(1001), plan = try CloudAtomicBatch.plan(original)
        XCTAssertTrue(try CloudAtomicBatch.requiresStaging(original))
        XCTAssertEqual(plan["manifest"]?["commandId"],original["commandId"])
        XCTAssertEqual(plan["manifest"]?["epoch"],.number(1)); XCTAssertEqual(plan["manifest"]?["expectedTimingVersion"],.number(8))
        XCTAssertEqual(plan["manifest"]?["operationCount"],.number(1001)); XCTAssertNil(plan["manifest"]?["operations"])
        let contents = try XCTUnwrap(plan["parts"]?.array), descriptors = try XCTUnwrap(plan["manifest"]?["parts"]?.array)
        XCTAssertEqual(contents.count,11); XCTAssertEqual(descriptors.count,contents.count)
        var restored: [JSONValue] = []
        for (index, content) in contents.enumerated() {
            let data = Data(try XCTUnwrap(content.string).utf8), operations = try ScrivJSON.decoder.decode([JSONValue].self,from:data)
            XCTAssertLessThanOrEqual(data.count,CloudAtomicBatch.maximumPartBytes); XCTAssertLessThanOrEqual(operations.count,100)
            XCTAssertEqual(descriptors[index]["bytes"]?.int,data.count); XCTAssertEqual(descriptors[index]["hash"]?.string,ScrivDigest.sha256(data))
            XCTAssertEqual(descriptors[index]["count"]?.int,operations.count); restored += operations
        }
        XCTAssertEqual(restored,original["operations"]?.array)
        let persisted = try ScrivJSON.encoder.encode(plan)
        XCTAssertEqual(try ScrivJSON.decoder.decode(JSONValue.self,from:persisted),plan)
        XCTAssertEqual(try CloudAtomicBatch.plan(original),plan)
    }
    func testSmallEditPreservesNormalCommandRoute() throws {
        XCTAssertFalse(try CloudAtomicBatch.requiresStaging(command(100)))
        XCTAssertTrue(try CloudAtomicBatch.requiresStaging(command(101)))
    }
    func testPartBudgetUsesUTF8BytesAndNeverSplitsOneItem() throws {
        let original = command(15,text:String(repeating:"🎬\\\"",count:8000))
        XCTAssertTrue(try CloudAtomicBatch.requiresStaging(original))
        let plan = try CloudAtomicBatch.plan(original), parts = try XCTUnwrap(plan["parts"]?.array)
        XCTAssertGreaterThan(parts.count,1)
        for part in parts { XCTAssertLessThanOrEqual(Data(try XCTUnwrap(part.string).utf8).count,CloudAtomicBatch.maximumPartBytes) }
    }
    func testBoundsRejectRatherThanPartiallyCommitting() throws {
        XCTAssertThrowsError(try CloudAtomicBatch.plan(command(0)))
        XCTAssertThrowsError(try CloudAtomicBatch.plan(command(10001)))
        XCTAssertThrowsError(try CloudAtomicBatch.plan(command(1,text:String(repeating:"x",count:CloudAtomicBatch.maximumPartBytes))))
        XCTAssertThrowsError(try CloudAtomicBatch.plan(command(300,text:String(repeating:"x",count:60000))))
    }
    func testKnownTransactionalRejectionsCanRetireTheImmutablePendingRequest() {
        let rejected: [(Int, [String])] = [
            (400,["invalid_reference", "image_version", "scene_too_long"]),
            (409,["stale_epoch", "version_conflict", "timing_conflict", "batch_session_changed", "item_in_use", "cue_timing", "cue_anchor", "kind_conflict", "immutable_image", "schema_upgrade_required"]),
            (413,["batch_history_too_large", "project_limit"]),
            (423,["lease_required", "item_locked"])
        ]
        for (status, codes) in rejected {
            for code in codes { XCTAssertTrue(CloudAtomicBatch.isDefinitivelyUncommitted(status:status,code:code),code) }
        }
    }
    func testUncertainAndRetryableFailuresMustKeepTheOriginalRequestIdentity() {
        let retained = [(409,"command_reused"),(409,"access_changed"),(409,"batch_incomplete"),
                        (400,"invalid_batch"),(400,"batch_part_mismatch"),(400,"invalid_field"),(400,"duplicate_word"),
                        (413,"body_too_large"),(413,"item_too_large"),(401,"session_expired"),
                        (402,"team_subscription_required"),(403,"read_only"),(404,"not_found"),
                        (429,"batch_capacity"),(429,"rate_limited"),(500,"internal_error"),
                        (503,"batch_history_too_large"),(409,"future_server_error")]
        for (status, code) in retained { XCTAssertFalse(CloudAtomicBatch.isDefinitivelyUncommitted(status:status,code:code),code) }
    }
}
