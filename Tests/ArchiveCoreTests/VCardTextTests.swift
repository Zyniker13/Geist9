import XCTest
@testable import ArchiveCore

/// vCard attachment text (M2.3, ROADMAP line 69): names, organizations,
/// notes and addresses become searchable prose; photos, identifiers and
/// the property machinery do not.
final class VCardTextTests: XCTestCase {
    private func text(_ vcf: String) -> String? {
        VCardText.text(Array(vcf.utf8))
    }

    func testNamesOrgAndEmailsEmit() {
        let vcf = "BEGIN:VCARD\r\nVERSION:3.0\r\n" +
            "FN:Alice Example\r\n" +
            "N:Example;Alice;;;\r\n" +
            "ORG:Example Studio;Design\r\n" +
            "TITLE:Lead\r\n" +
            "EMAIL;TYPE=WORK:alice@example.com\r\n" +
            "NOTE:prefers email\r\n" +
            "END:VCARD\r\n"
        let out = text(vcf)
        XCTAssertNotNil(out)
        XCTAssertTrue(out!.contains("Alice Example"))
        XCTAssertTrue(out!.contains("Example Alice"))
        XCTAssertTrue(out!.contains("Example Studio Design"))
        XCTAssertTrue(out!.contains("Lead"))
        XCTAssertTrue(out!.contains("alice@example.com"))
        XCTAssertTrue(out!.contains("prefers email"))
        XCTAssertFalse(out!.contains("VERSION"))
        XCTAssertFalse(out!.contains("TYPE=WORK"))
    }

    func testMultipleCards() {
        let vcf = "BEGIN:VCARD\r\nFN:Bob Example\r\nEND:VCARD\r\n" +
            "BEGIN:VCARD\r\nFN:Carol Example\r\nEND:VCARD\r\n"
        let out = text(vcf)
        XCTAssertTrue(out!.contains("Bob Example"))
        XCTAssertTrue(out!.contains("Carol Example"))
    }

    func testPhotoBase64NeverAppears() {
        let vcf = "BEGIN:VCARD\r\nVERSION:3.0\r\n" +
            "FN:Bob Example\r\n" +
            "PHOTO;ENCODING=b;TYPE=JPEG:/9j/4AAQSkZJRgABAQEAYABgAAD\r\n" +
            "END:VCARD\r\n"
        let out = text(vcf)
        XCTAssertTrue(out!.contains("Bob Example"))
        XCTAssertFalse(out!.contains("9j"))
        XCTAssertFalse(out!.contains("JPEG"))
    }

    func testQuotedPrintableDecodes() {
        let vcf = "BEGIN:VCARD\r\nVERSION:2.1\r\n" +
            "NOTE;ENCODING=QUOTED-PRINTABLE:caf=C3=A9 at caf=C3=A9\r\n" +
            "FN:Al Colors\r\n" +
            "END:VCARD\r\n"
        let out = text(vcf)
        XCTAssertTrue(out!.contains("café at café"))
    }

    func testQuotedPrintableSoftBreaks() {
        let vcf = "BEGIN:VCARD\r\nVERSION:2.1\r\n" +
            "NOTE;ENCODING=QUOTED-PRINTABLE:one=\r\n" +
            " two\r\n" +
            "FN:Al Breaks\r\n" +
            "END:VCARD\r\n"
        let out = text(vcf)
        XCTAssertTrue(out!.contains("one two"))
    }

    func testGarbageYieldsNil() {
        XCTAssertNil(text("not a vcard"))
        XCTAssertNil(text(""))
        XCTAssertNil(text("BEGIN:CALENDAR\r\nFN:nope\r\nEND:VCARD\r\n"))
    }

    func testOversizedInputYieldsNil() {
        let big = Array(String(repeating: "FN:x\r\n", count: 4_200_000).utf8)
        XCTAssertGreaterThan(big.count, VCardText.maxInputBytes)
        XCTAssertNil(VCardText.text(big))
    }

    func testOutputIsCapped() {
        var vcf = "BEGIN:VCARD\r\n"
        vcf += String(repeating: "NOTE:word\r\n", count: 250_000)
        vcf += "END:VCARD\r\n"
        let capped = VCardText.text(Array(vcf.utf8))
        XCTAssertNotNil(capped)
        XCTAssertLessThanOrEqual(capped!.count, VCardText.maxOutputCharacters)
    }
}
