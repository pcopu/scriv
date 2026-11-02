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
        XCTAssertEqual(sheet.preferredContentSize, CGSize(width: 1032, height: 680))
        ScrivSheetFitting.fit(sheet, in: CGSize(width: 1080, height: 720))
        XCTAssertEqual(sheet.preferredContentSize, CGSize(width: 1032, height: 680), "Fitting is idempotent")
        ScrivSheetFitting.fit(sheet, in: CGSize(width: 1600, height: 1000))
        XCTAssertEqual(sheet.preferredContentSize, CGSize(width: 1040, height: 740), "A larger window restores the designed size")
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
}
