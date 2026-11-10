import XCTest
@testable import LabelWerkCore

final class LabelStockChoiceTests: XCTestCase {

    // MARK: Vorauswahl

    func testDetectedSizeWithoutMatchSelectsPrinterWhileUntouched() {
        let choice = LabelStockChoice.preselection(current: .stock("w4h6in"), touched: false, hasDetectedSize: true,
                                                   matchingStockID: nil, fallbackStockID: "w4h6in")
        XCTAssertEqual(choice, .printer)
    }

    func testDetectedSizeWithMatchSelectsMatchingStock() {
        let choice = LabelStockChoice.preselection(current: .stock("w4h6in"), touched: false, hasDetectedSize: true,
                                                   matchingStockID: "custom-prefs-1", fallbackStockID: "w4h6in")
        XCTAssertEqual(choice, .stock("custom-prefs-1"))
    }

    func testTouchedChoiceIsKept() {
        for current in [LabelStockChoice.stock("w2h1in"), .custom, .printer] {
            let choice = LabelStockChoice.preselection(current: current, touched: true, hasDetectedSize: true,
                                                       matchingStockID: "x", fallbackStockID: "w4h6in")
            XCTAssertEqual(choice, current)
        }
    }

    func testWithoutDetectedSizePrinterFallsBack() {
        XCTAssertEqual(LabelStockChoice.preselection(current: .printer, touched: false, hasDetectedSize: false,
                                                     matchingStockID: nil, fallbackStockID: "w4h6in"),
                       .stock("w4h6in"))
        XCTAssertEqual(LabelStockChoice.preselection(current: .printer, touched: true, hasDetectedSize: false,
                                                     matchingStockID: nil, fallbackStockID: "w4h6in"),
                       .stock("w4h6in"))
        XCTAssertEqual(LabelStockChoice.preselection(current: .custom, touched: false, hasDetectedSize: false,
                                                     matchingStockID: nil, fallbackStockID: "w4h6in"),
                       .custom)
        XCTAssertEqual(LabelStockChoice.preselection(current: .stock("a"), touched: false, hasDetectedSize: false,
                                                     matchingStockID: nil, fallbackStockID: "w4h6in"),
                       .stock("a"))
    }

    func testStockID() {
        XCTAssertEqual(LabelStockChoice.stock("a").stockID, "a")
        XCTAssertNil(LabelStockChoice.printer.stockID)
        XCTAssertNil(LabelStockChoice.custom.stockID)
    }

    // MARK: Eingabe

    private let zd421 = LabelSizing.Limits(widthMM: 10...106, heightMM: 5...991)

    func testEntryParsesGermanDecimalComma() {
        let entry = LabelSizeEntry(widthText: "104", heightText: "76,2", tracking: .gap)
        XCTAssertEqual(entry.widthMM, 104)
        XCTAssertEqual(entry.heightMM, 76.2)
        XCTAssertTrue(entry.issues(in: zd421).isEmpty)
        let size = entry.size(in: zd421)
        XCTAssertEqual(size?.widthMM, 104)
        XCTAssertEqual(size?.heightMM, 76.2)
    }

    func testEntryAcceptsPointAndUnit() {
        let entry = LabelSizeEntry(widthText: " 104.0 mm", heightText: "76.20", tracking: .gap)
        XCTAssertEqual(entry.widthMM, 104)
        XCTAssertEqual(entry.heightMM, 76.2)
    }

    func testPrefilledEntryUsesComma() {
        let entry = LabelSizeEntry(widthMM: 104, heightMM: 76.2, tracking: .blackMark)
        XCTAssertEqual(entry.widthText, "104")
        XCTAssertEqual(entry.heightText, "76,2")
        XCTAssertEqual(entry.tracking, .blackMark)
        XCTAssertFalse(entry.isEmpty)
    }

    func testEntryValidationPerField() {
        var entry = LabelSizeEntry()
        XCTAssertTrue(entry.isEmpty)
        XCTAssertEqual(entry.widthIssues(in: zd421), [.widthMissing])
        XCTAssertEqual(entry.heightIssues(in: zd421), [.heightMissing])
        XCTAssertNil(entry.size(in: zd421))

        entry.widthText = "110"
        entry.heightText = "4"
        XCTAssertEqual(entry.widthIssues(in: zd421), [.widthTooLarge(maximum: 106)])
        XCTAssertEqual(entry.heightIssues(in: zd421), [.heightTooSmall(minimum: 5)])
        XCTAssertNil(entry.size(in: zd421))

        entry.widthText = "abc"
        entry.heightText = "76,2"
        XCTAssertEqual(entry.widthIssues(in: zd421), [.widthMissing])
        XCTAssertTrue(entry.heightIssues(in: zd421).isEmpty)

        entry.widthText = "9,5"
        XCTAssertEqual(entry.widthIssues(in: zd421), [.widthTooSmall(minimum: 10)])

        entry.widthText = "106"
        XCTAssertNotNil(entry.size(in: zd421))
    }

    func testIssueSide() {
        XCTAssertTrue(LabelSizing.Issue.widthMissing.concernsWidth)
        XCTAssertTrue(LabelSizing.Issue.widthTooLarge(maximum: 1).concernsWidth)
        XCTAssertFalse(LabelSizing.Issue.heightTooLarge(maximum: 1).concernsWidth)
        XCTAssertFalse(LabelSizing.Issue.heightMissing.concernsWidth)
    }
}
