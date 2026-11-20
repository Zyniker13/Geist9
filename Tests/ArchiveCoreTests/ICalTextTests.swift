import XCTest
@testable import ArchiveCore

/// iCalendar attachment text (M2.3, ROADMAP line 69): SUMMARY,
/// DESCRIPTION and LOCATION values from VEVENT, VTODO and VJOURNAL
/// components become searchable prose; identifiers, dates, recurrence
/// rules and base64 attachments do not.
final class ICalTextTests: XCTestCase {
    private func text(_ ics: String) -> String? {
        ICalText.text(Array(ics.utf8))
    }

    func testSummariesDescriptionsLocationsFromTwoEvents() {
        let ics = "BEGIN:VCALENDAR\r\n" +
            "VERSION:2.0\r\n" +
            "BEGIN:VEVENT\r\n" +
            "UID:1234\r\n" +
            "DTSTART:20261201T090000Z\r\n" +
            "SUMMARY:Studio review\r\n" +
            "LOCATION:Studio Mac\r\n" +
            "DESCRIPTION:Bring the\r\n" +
            "  quarterly numbers\r\n" +
            "END:VEVENT\r\n" +
            "BEGIN:VEVENT\r\n" +
            "UID:5678\r\n" +
            "SUMMARY:Invoice call\r\n" +
            "END:VEVENT\r\n" +
            "END:VCALENDAR\r\n"
        let out = text(ics)
        XCTAssertNotNil(out)
        XCTAssertTrue(out!.contains("Studio review"))
        XCTAssertTrue(out!.contains("Studio Mac"))
        XCTAssertTrue(out!.contains("Bring the quarterly numbers"))
        XCTAssertTrue(out!.contains("Invoice call"))
        XCTAssertFalse(out!.contains("20261201"))
        XCTAssertFalse(out!.contains("UID"))
        XCTAssertFalse(out!.contains("1234"))
        XCTAssertFalse(out!.contains("5678"))
    }

    func testEscapesDecode() {
        let ics = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\n" +
            "DESCRIPTION:line one\\nline two\\, comma\\; semi\r\n" +
            "END:VEVENT\r\nEND:VCALENDAR\r\n"
        XCTAssertEqual(text(ics), "line one\nline two, comma; semi")
    }

    func testParametersAreStrippedFromTheName() {
        let ics = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\n" +
            "SUMMARY;LANGUAGE=en:quarterly meeting\r\n" +
            "END:VEVENT\r\nEND:VCALENDAR\r\n"
        XCTAssertEqual(text(ics), "quarterly meeting")
    }

    func testTodoAndJournalSummaries() {
        let ics = "BEGIN:VCALENDAR\r\n" +
            "BEGIN:VTODO\r\nSUMMARY:file the expenses\r\nEND:VTODO\r\n" +
            "BEGIN:VJOURNAL\r\nSUMMARY:trip notes\r\nDESCRIPTION:pack light\r\nEND:VJOURNAL\r\n" +
            "END:VCALENDAR\r\n"
        let out = text(ics)
        XCTAssertTrue(out!.contains("file the expenses"))
        XCTAssertTrue(out!.contains("trip notes"))
        XCTAssertTrue(out!.contains("pack light"))
    }

    func testAttachBase64NeverAppears() {
        let ics = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\n" +
            "SUMMARY:with attachment\r\n" +
            "ATTACH;FMTTYPE=application/pdf;ENCODING=BASE64:JVBERi0xLjQK\r\n" +
            "END:VEVENT\r\nEND:VCALENDAR\r\n"
        let out = text(ics)
        XCTAssertTrue(out!.contains("with attachment"))
        XCTAssertFalse(out!.contains("JVBERi0xLjQK"))
    }

    func testGarbageYieldsNil() {
        XCTAssertNil(text("not a calendar at all"))
        XCTAssertNil(text("BEGIN:VEVENT\r\nSUMMARY:no envelope\r\nEND:VEVENT\r\n"))
        XCTAssertNil(text(""))
    }

    func testOversizedInputYieldsNil() {
        let big = Array(String(repeating: "SUMMARY:x\r\n", count: 2_500_000).utf8)
        XCTAssertGreaterThan(big.count, ICalText.maxInputBytes)
        XCTAssertNil(ICalText.text(big))
    }

    func testOutputIsCapped() {
        let body = "SUMMARY:word\r\n"
        var ics = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\n"
        ics += String(repeating: body, count: 250_000)
        ics += "END:VEVENT\r\nEND:VCALENDAR\r\n"
        let capped = ICalText.text(Array(ics.utf8))
        XCTAssertNotNil(capped)
        XCTAssertLessThanOrEqual(capped!.count, ICalText.maxOutputCharacters)
    }
}
