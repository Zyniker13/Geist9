import XCTest
@testable import ArchiveCore

/// CSV attachment text (M2.3, ROADMAP line 69): RFC 4180 rows become
/// lines, cells become space-joined values — no commas, no quote noise,
/// quoted cells keep their embedded newlines.
final class CSVTextTests: XCTestCase {
    private func text(_ csv: String) -> String? {
        CSVText.text(Array(csv.utf8))
    }

    func testRowsBecomeLinesAndCellsJoinWithSpaces() {
        XCTAssertEqual(text("name,qty\nWidget,2\nGadget,10"), "name qty\nWidget 2\nGadget 10")
    }

    func testQuotedCellKeepsCommaAndEmbeddedNewline() {
        XCTAssertEqual(text("a,\"x,y\nz\",b"), "a x,y\nz b")
    }

    func testDoubledQuoteUnescapes() {
        XCTAssertEqual(text("say,\"\"\"hi\"\"\",now"), "say \"hi\" now")
    }

    func testCarriageReturnAndCRLFLineEndings() {
        XCTAssertEqual(text("a,b\rc,d\r\n"), "a b\nc d")
    }

    func testTrailingSpacesInsideUnquotedCellsAreKept() {
        // Cells are kept verbatim and joined with one space: "a " + " " + " b".
        XCTAssertEqual(text("a , b"), "a   b")
    }

    func testEmptyInputYieldsNil() {
        XCTAssertNil(text(""))
        XCTAssertNil(text("\n\n"))
    }

    func testOversizedInputYieldsNil() {
        let big = Array(String(repeating: "a,", count: 13_000_000).utf8)
        XCTAssertGreaterThan(big.count, CSVText.maxInputBytes)
        XCTAssertNil(CSVText.text(big))
    }

    func testOutputIsCapped() {
        let rows = Array(String(repeating: "word ", count: 333_334).utf8)
        let capped = CSVText.text(rows)
        XCTAssertNotNil(capped)
        XCTAssertLessThanOrEqual(capped!.count, CSVText.maxOutputCharacters)
    }
}
