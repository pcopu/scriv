import XCTest
import UIKit
@testable import ScrivUIKit

@MainActor
final class SheetFittingTests: XCTestCase {
    func testSheetsShrinkToTheWindowAndGrowBack() {
        let sheet = UIViewController(); sheet.modalPresentationStyle = .formSheet
        sheet.preferredContentSize = CGSize(width: 1040, height: 740)
        // Minimum Scriv window (1080×720): the footer must stay inside it.
        ScrivSheetFitting.fit(sheet, in: CGSize(width: 1080, height: 720))
        XCTAssertEqual(sheet.preferredContentSize, CGSize(width: 1024, height: 680))
        ScrivSheetFitting.fit(sheet, in: CGSize(width: 1080, height: 720))
        XCTAssertEqual(sheet.preferredContentSize, CGSize(width: 1024, height: 680), "Fitting is idempotent")
        ScrivSheetFitting.fit(sheet, in: CGSize(width: 1600, height: 1000))
        XCTAssertEqual(sheet.preferredContentSize, CGSize(width: 1024, height: 740), "A larger window restores the designed height; width stays within the form-sheet maximum")
        let narrow = UIViewController(); narrow.modalPresentationStyle = .formSheet; narrow.preferredContentSize = CGSize(width: 960, height: 600)
        ScrivSheetFitting.fit(narrow, in: CGSize(width: 1600, height: 1000))
        XCTAssertEqual(narrow.preferredContentSize, CGSize(width: 960, height: 600), "Sheets within limits are untouched")
    }

    func testASheetThatResizesItselfKeepsItsNewDesign() {
        let sheet = UIViewController(); sheet.modalPresentationStyle = .formSheet
        sheet.preferredContentSize = CGSize(width: 500, height: 410)
        ScrivSheetFitting.fit(sheet, in: CGSize(width: 1080, height: 720))
        XCTAssertEqual(sheet.preferredContentSize, CGSize(width: 500, height: 410), "Small sheets are untouched")
        sheet.preferredContentSize = CGSize(width: 500, height: 900)
        ScrivSheetFitting.fit(sheet, in: CGSize(width: 1080, height: 720))
        XCTAssertEqual(sheet.preferredContentSize.height, 680)
        ScrivSheetFitting.fit(sheet, in: CGSize(width: 1080, height: 1200))
        XCTAssertEqual(sheet.preferredContentSize.height, 900)
    }

    func testOnlyFormSheetsAreFitted() {
        let page = UIViewController(); page.modalPresentationStyle = .fullScreen
        page.preferredContentSize = CGSize(width: 2000, height: 2000)
        ScrivSheetFitting.fit(page, in: CGSize(width: 1080, height: 720))
        XCTAssertEqual(page.preferredContentSize, CGSize(width: 2000, height: 2000))
    }

    func testAPresentedSheetThatGrowsItselfIsRefittedToTheWindow() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 1080, height: 720)
        let root = UIViewController(); window.rootViewController = root; window.makeKeyAndVisible()
        defer { root.dismiss(animated: false); window.isHidden = true }
        let content = UIViewController(); content.preferredContentSize = CGSize(width: 500, height: 410)
        let navigation = UINavigationController(rootViewController: content)
        navigation.modalPresentationStyle = .formSheet; navigation.preferredContentSize = content.preferredContentSize
        root.present(navigation, animated: false)
        for _ in 0..<50 where navigation.isBeingPresented { try await Task.sleep(for: .milliseconds(20)) }
        // Word timing grows to its content, up to 720 pt: taller than this window.
        content.preferredContentSize = CGSize(width: 500, height: 720); navigation.preferredContentSize = content.preferredContentSize
        ScrivSheetFitting.refit(containing: content)
        let available = try XCTUnwrap(ScrivSheetFitting.available(in: window))
        XCTAssertLessThanOrEqual(navigation.preferredContentSize.height, available.height - 2 * ScrivSheetFitting.margin.height)
        XCTAssertEqual(navigation.preferredContentSize.width, 500)
    }
}
