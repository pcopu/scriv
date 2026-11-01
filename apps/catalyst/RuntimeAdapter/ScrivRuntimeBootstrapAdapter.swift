// Native macOS target only. The existing client is exposed through a real
// Objective-C protocol, not selectors that bypass Catalyst availability.
import Foundation

@objc(ScrivRuntimeBootstrapAdapterImpl)
final class ScrivRuntimeBootstrapAdapterImpl: NSObject, ScrivRuntimeBootstrapAdapter {
    private let client = ScrivRuntimeBootstrapClient()
    func connectAfterUserConsent(_ approved: Bool, completion: @escaping (Data?, Error?) -> Void) {
        client.connectAfterUserConsent(approved) { data, error in completion(data, error) }
    }
    func disconnect() { client.disconnect() }
}
