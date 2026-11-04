// Exercises the actual controller against reordered synthetic account reads.
import Foundation
import ScrivCore

@main @MainActor
struct AccountRefreshCheck {
    static func main() async throws {
        let env = ProcessInfo.processInfo.environment
        let mode = env["SCRIV_FAKE_ACCOUNT_MODE"]!
        let controller = CodexController()
        controller.executablePath = env["SCRIV_FAKE_EXECUTABLE"]!
        try await controller.start()
        try await Task.sleep(for: .seconds(1))
        if mode == "latest_failure" {
            precondition(!controller.accountChecked, "An unverified account must not remain ready")
            precondition(controller.lastError?.contains("current account error") == true, "The latest account error must remain visible")
        } else {
            let expected: String? = mode == "stale_signed_in" ? nil : "current@example.invalid"
            precondition(controller.accountChecked && controller.accountLabel == expected, "An older account snapshot replaced the latest state")
            precondition(controller.lastError == nil, "An older account error contaminated the latest state")
        }
        controller.disconnect()
        print("PASS: account \(mode)")
    }
}
