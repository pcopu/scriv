#if SCRIV_CLI_AUTOMATION
import Foundation
import ScrivCore

/// Two checked-in 2 × 2 RGB PNGs. No caller-controlled bytes or filesystem names.
enum ScrivCLILocalImageFixtures {
    struct Failure: Error {}
    static func bytes(_ token: String) throws -> Data {
        let encoded: String
        switch token {
        case "coral": encoded = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGP4EGADRAwQCgAsbgXx43oYYAAAAABJRU5ErkJggg=="
        case "blue": encoded = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGPQSLkDRAwQCgAkngWhX3lw/wAAAABJRU5ErkJggg=="
        default: throw Failure()
        }
        guard let data = Data(base64Encoded: encoded), data.count <= 128 else { throw Failure() }
        return data
    }
    static func matching(_ data: Data) -> Bool {
        ["coral", "blue"].contains { (try? bytes($0)) == data }
    }
}
#endif
