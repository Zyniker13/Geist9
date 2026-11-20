// RTF-to-text decoding (M2.3, ROADMAP line 69): RTF attachments currently
// yield nothing (application/rtf is not text/*) or, for text/rtf, raw
// control words. These tests define the contract: visible text survives,
// destination groups (font tables, pictures, field instructions) do not,
// Windows-1252 hex escapes and \uN unicode escapes decode, and garbage
// yields nil like the other strict extractors.

import XCTest
@testable import ArchiveCore

final class RTFTextTests: XCTestCase {
    private func text(_ rtf: String) -> String? {
        RTFText.text(Array(rtf.utf8))
    }

    func testPlainParagraphsBecomeText() {
        XCTAssertEqual(text(#"{\rtf1\ansi Hello\par World}"#), "Hello\nWorld")
    }

    func testIgnoredControlWordsKeepTheirText() {
        XCTAssertEqual(
            text(#"{\rtf1\ansi\deff0\fs24 Hello \b bold\b0  tail}"#),
            "Hello bold tail"
        )
    }

    func testSkipsFontTableAndColorTable() {
        XCTAssertEqual(
            text(#"{\rtf1{\fonttbl{\f0\fswiss Helvetica;}}{\colortbl;\red0\green0\blue0;}Body text}"#),
            "Body text"
        )
    }

    func testSkipsPicturesAndUnknownStarDestinations() {
        XCTAssertEqual(
            text(#"{\rtf1{\pict\pngblip89504e47}before{\*\generator Riched20}after}"#),
            "beforeafter"
        )
    }

    func testHexEscapesMapWindows1252() {
        XCTAssertEqual(text(#"{\rtf1 quote: \'92 dash: \'96}"#), "quote: \u{2019} dash: \u{2013}")
    }

    func testUnicodeEscapesDecodeAndSkipFallback() {
        XCTAssertEqual(text(#"{\rtf1 caf\u233 ?}"#), "caf\u{e9}")
    }

    func testTabsAndLinesAndRawNewlines() {
        XCTAssertEqual(text(#"{\rtf1 a\tab b\par c\line d}"#), "a b\nc\nd")
        // Raw CR/LF bytes between visible runs are ignored per the RTF spec;
        // \par is the paragraph break. The bytes below are literal CR and LF,
        // not the \r and \n control words.
        XCTAssertEqual(text("{\\rtf1 Line1\r\nLine2}"), "Line1Line2")
    }

    func testFieldResultIsKeptAndInstructionIsNot() {
        XCTAssertEqual(
            text(#"{\rtf1{\field{\*\fldinst HYPERLINK "http://example.com"}{\fldrslt click here}}}"#),
            "click here"
        )
    }

    func testBinaryDataIsSkipped() {
        XCTAssertEqual(
            text("{\\rtf1 before{\\*\\shpinst\\bin4  \\u1\\u2\\u3\\u4}after}"),
            "beforeafter"
        )
    }

    func testGarbageIsNil() {
        XCTAssertNil(text("this is not rtf at all"))
        XCTAssertNil(text(""))
    }

    func testEmptyTextYieldsNil() {
        XCTAssertNil(text(#"{\rtf1}"#))
    }

    func testTruncatedFileStillYieldsItsText() {
        XCTAssertEqual(text(#"{\rtf1\ansi hello"#), "hello")
    }

    func testOversizedInputIsNil() {
        XCTAssertNil(RTFText.text(Array(repeating: UInt8(0x41), count: RTFText.maxInputBytes + 1)))
    }

    func testOutputIsCapped() {
        // 333,334 four-letter words exceed the 1,000,000-character cap with no
        // trailing whitespace, so the trimmed result is exactly the cap.
        let runs = String(repeating: "word", count: 333_334)
        let got = text("{\\rtf1\\ansi \(runs)}")
        XCTAssertEqual(got?.count, RTFText.maxOutputCharacters)
    }
}
