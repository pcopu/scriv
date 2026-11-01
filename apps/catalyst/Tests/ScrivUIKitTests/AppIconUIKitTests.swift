import UIKit
import XCTest
@testable import ScrivUIKit

final class AppIconUIKitTests: XCTestCase {
    func testHostBundleContainsCompiledPrimaryAppIcon() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        let icons = info["CFBundleIcons"] as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        let name = info["CFBundleIconName"] as? String ?? primary?["CFBundleIconName"] as? String
        let file = info["CFBundleIconFile"] as? String
        XCTAssertTrue(name == "AppIcon" || file?.hasPrefix("AppIcon") == true)
        XCTAssertNotNil(Bundle.main.url(forResource: "Assets", withExtension: "car"))
        if let file {
            let path = (file as NSString).deletingPathExtension
            XCTAssertNotNil(Bundle.main.url(forResource: path, withExtension: "icns"), "The Dock icon must exist in the actual host bundle.")
        } else {
            let files = try XCTUnwrap(primary?["CFBundleIconFiles"] as? [String])
            XCTAssertFalse(files.isEmpty)
            XCTAssertTrue(files.contains { filename in
                Bundle.main.url(forResource: filename, withExtension: "png") != nil ||
                Bundle.main.url(forResource: filename + "@2x~ipad", withExtension: "png") != nil
            }, "The declared primary icon must have a compiled resource.")
        }
    }
}
