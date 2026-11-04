// Runs the real native controller against an isolated synthetic runtime.
import Foundation
import ScrivCore

@main @MainActor
struct CancellationCheck {
    static func main() async throws {
        let env = ProcessInfo.processInfo.environment
        let mode = env["SCRIV_FAKE_MODE"]!
        let log = URL(fileURLWithPath: env["SCRIV_FAKE_INTERRUPT_LOG"]!)
        let controller = CodexController()
        controller.executablePath = env["SCRIV_FAKE_EXECUTABLE"]!
        try await controller.start()
        precondition(controller.isConnected, "Synthetic runtime did not connect")
        let generation = Task { try await controller.generate(prompt: "A blue square") }
        if mode == "manual" || mode == "late" || mode == "acknowledged" {
            for _ in 0..<250 {
                if mode == "late" ? controller.activeGenerationJob?.threadID == "scriv-thread" : controller.activeGenerationJob?.turnID == "scriv-turn" { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            if mode == "late" { precondition(controller.activeGenerationJob?.turnID == nil, "Expected a pending turn response") }
            else { precondition(controller.activeGenerationJob?.turnID == "scriv-turn", "Synthetic turn did not start") }
            await controller.cancelGeneration()
        }
        do { _ = try await generation.value; preconditionFailure("Synthetic turn cannot produce an image") }
        catch {
            if ["own", "manual", "late", "acknowledged"].contains(mode) { precondition(error is CancellationError, "Expected cancellation") }
            else { precondition(!(error is CancellationError), "An unrelated request cancelled this job") }
        }
        guard let job = controller.jobs.first else { preconditionFailure("Missing generation journal") }
        let interrupts = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        if ["own", "manual", "late", "acknowledged"].contains(mode) {
            precondition(job.status == .waiting, "Unconfirmed cancellation must remain waiting")
            precondition(interrupts.contains("scriv-turn"), "Expected the actual generation to be interrupted")
            precondition(interrupts.split(separator: "\n").count == 1, "Cancellation must issue only one interruption")
            if mode != "acknowledged" { precondition(controller.lastError?.contains("could not be confirmed") == true) }
            try await controller.inspectJob(job.id)
            precondition(controller.jobs.first?.status == .cancelled, "A confirmed interrupted turn is cancelled")
        } else {
            precondition(job.status == .failed && interrupts.isEmpty, "Another thread must not affect this job")
            precondition(controller.lastError == "Synthetic turn finished", "Another thread must not contaminate the job error")
        }
        controller.disconnect()
        print("PASS: \(mode)")
    }
}
