import Foundation

extension Bundle {
    /// SwiftPM's development accessor embeds an absolute build path. Installed
    /// applications must resolve resources inside the signed application bundle.
    static var scrivResources: Bundle {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Scriv_ScrivApp.bundle"), let bundle = Bundle(url: url) { return bundle }
        return Bundle.module
    }
}
