import Foundation
import ScrivCore

extension CloudClient {
    private func generationPath(_ projectID: String) -> String {
        "/v1/projects/\(CloudEndpoint.queryValue(projectID))/generation-jobs"
    }
    func generationJobs(projectID explicitProjectID: String? = nil) async throws -> [CloudGenerationJob] {
        guard let projectID = explicitProjectID ?? projectId else { return [] }
        let sourceServer = baseURL, sourceAccount = account?.id, sourceDevice = deviceId, sourceProject = projectId
        struct Page: Decodable { var jobs: [CloudGenerationJob]; var nextCursor: String? }
        var cursor: String?, seen: Set<String> = [], jobs: [String: CloudGenerationJob] = [:]
        while true {
            let suffix = cursor.map { "&cursor=" + CloudEndpoint.queryValue($0) } ?? ""
            let page: Page = try await request(generationPath(projectID) + "?limit=100" + suffix)
            guard baseURL == sourceServer, account?.id == sourceAccount, deviceId == sourceDevice, projectId == sourceProject else { throw CancellationError() }
            for job in page.jobs { jobs[job.id] = job }
            guard let next = page.nextCursor else { return jobs.values.sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) } }
            guard !next.isEmpty, seen.insert(next).inserted else { throw ScrivError.invalid("Generation job pagination stopped advancing.") }
            cursor = next
        }
    }
    func generationJob(id: String, projectID: String? = nil) async throws -> CloudGenerationJob {
        guard let projectId = projectID ?? projectId else { throw ScrivError.unavailable("Open the original cloud project first.") }
        struct Response: Decodable { var job: CloudGenerationJob }
        let response: Response = try await request(generationPath(projectId) + "/" + CloudEndpoint.queryValue(id.lowercased()))
        return response.job
    }
    func createGenerationJob(id: String, targetItemId: String, sourceRevision: Int, projectID: String? = nil) async throws -> CloudGenerationJob {
        guard let projectId = projectID ?? projectId else { throw ScrivError.unavailable("Open the original cloud project first.") }
        struct Response: Decodable { var job: CloudGenerationJob }
        let response: Response = try await request(generationPath(projectId), method: "POST", body: .object([
            "id": .string(id.lowercased()), "targetItemId": .string(targetItemId), "sourceRevision": .number(Double(sourceRevision))
        ]))
        return response.job
    }
    func claimGenerationJob(id: String, expectedVersion: Int, recover: Bool = false, operationId: String = UUID().uuidString, projectID: String? = nil) async throws -> CloudGenerationJob {
        guard let projectId = projectID ?? projectId else { throw ScrivError.unavailable("Open the original cloud project first.") }
        struct Response: Decodable { var job: CloudGenerationJob }
        let response: Response = try await request(generationPath(projectId) + "/" + CloudEndpoint.queryValue(id.lowercased()) + "/claim", method: "POST", body: .object([
            "operationId": .string(operationId.lowercased()), "expectedVersion": .number(Double(expectedVersion)), "recover": .bool(recover)
        ]))
        return response.job
    }
    func updateGenerationJob(id: String, expectedVersion: Int, status: LocalGenerationJob.Status,
                             progressText: String, outputImageId: String? = nil, errorCode: String? = nil,
                             operationId: String = UUID().uuidString, projectID: String? = nil) async throws -> CloudGenerationJob {
        guard let projectId = projectID ?? projectId else { throw ScrivError.unavailable("Open the original cloud project first.") }
        struct Response: Decodable { var job: CloudGenerationJob }
        var safeProgress = ""
        for character in progressText {
            let value = character.isNewline ? " " : String(character)
            guard safeProgress.utf16.count + value.utf16.count <= 160 else { break }
            safeProgress += value
        }
        var body: [String: JSONValue] = ["operationId": .string(operationId.lowercased()), "expectedVersion": .number(Double(expectedVersion)),
                                      "status": .string(status.rawValue), "progressText": .string(safeProgress)]
        if let outputImageId { body["outputImageId"] = .string(outputImageId) }
        if let errorCode {
            guard errorCode.range(of: "^[a-z][a-z0-9_]{0,47}$", options: .regularExpression) != nil else { throw ScrivError.invalid("Generation metadata needs a short error code, not a runtime response.") }
            body["errorCode"] = .string(errorCode)
        }
        let response: Response = try await request(generationPath(projectId) + "/" + CloudEndpoint.queryValue(id.lowercased()), method: "PATCH", body: .object(body))
        return response.job
    }
}
