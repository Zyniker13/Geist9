// Charset decoding tests (DESIGN 7, M1.8): every fixture decodes exactly,
// mislabelled aliases decode like their canonical form, and decoder failures
// fall back lossily instead of dropping text.

import XCTest
@testable import MailMIME

final class CharsetTests: XCTestCase {
    func testCanonicalFixturesDecodeExactly() {
        for fixture in charsetFixtures {
            XCTAssertEqual(
                Charset.decode(fixture.label, fixture.bytes),
                fixture.expected,
                "label \(fixture.label) failed"
            )
        }
    }

    func testMislabelledAliasesDecodeLikeCanonical() {
        let byLabel = Dictionary(
            charsetFixtures.map { ($0.label, $0) },
            uniquingKeysWith: { a, _ in a }
        )
        for mislabel in charsetMislabels {
            guard let reference = byLabel[mislabel.like] else {
                XCTFail("mislabel \(mislabel.alias) points at missing fixture \(mislabel.like)")
                continue
            }
            XCTAssertEqual(
                Charset.decode(mislabel.alias, reference.bytes),
                reference.expected,
                "alias \(mislabel.alias) did not decode like \(mislabel.like)"
            )
        }
    }

    func testLabelsNormalizeQuotesAndUnderscores() {
        let fixture = charsetFixtures.first { $0.label == "windows-1251" }!
        XCTAssertEqual(Charset.decode("\"windows_1251\"", fixture.bytes), fixture.expected)
        XCTAssertEqual(Charset.decode("  Windows-1251  ", fixture.bytes), fixture.expected)
        XCTAssertEqual(Charset.decode("CP1251", fixture.bytes), fixture.expected)
    }

    func testUTF16LabelsForceEndianness() {
        // "ok" with no BOM in both byte orders.
        let little: [UInt8] = [0x6F, 0x00, 0x6B, 0x00]
        let big: [UInt8] = [0x00, 0x6F, 0x00, 0x6B]
        XCTAssertEqual(Charset.decode("utf-16le", little), "ok")
        XCTAssertEqual(Charset.decode("utf-16be", big), "ok")
        XCTAssertEqual(Charset.decode("utf-16le", big), "漀欀") // wrong order still renders
        // BOM overrides the label, then is stripped.
        XCTAssertEqual(Charset.decode("utf-16le", [0xFE, 0xFF, 0x00, 0x6F, 0x00, 0x6B]), "ok")
        XCTAssertEqual(Charset.decode("utf-16", [0xFE, 0xFF, 0x00, 0x6F, 0x00, 0x6B]), "ok")
        XCTAssertEqual(Charset.decode("utf-16", [0xFF, 0xFE, 0x6F, 0x00, 0x6B, 0x00]), "ok")
    }

    func testSurrogatesSurviveUTF16() {
        // U+1F389 (party popper) in UTF-16BE: D8 3C DF 89.
        let big: [UInt8] = [0xD8, 0x3C, 0xDF, 0x89]
        XCTAssertEqual(Charset.decode("utf-16be", big), "\u{1F389}")
        // A lone surrogate still renders (as replacement), never crashes.
        XCTAssertEqual(Charset.decode("utf-16be", [0xD8, 0x3C]), "\u{FFFD}")
    }

    func testTruncatedMultibyteStillRenders() {
        // First half of a GB18030 character, and of a Shift-JIS one.
        for label in ["gb18030", "shift-jis", "big5", "cp949", "euc-jp"] {
            let fixture = charsetFixtures.first { $0.label == label }!
            let cut = Array(fixture.bytes.prefix(1))
            let decoded = Charset.decode(label, cut)
            XCTAssertFalse(decoded.isEmpty, "truncated \(label) dropped all text")
        }
    }

    func testUnknownLabelFallsBackLossily() {
        let utf8 = "h\u{e9}llo \u{4e2d}".data(using: .utf8)!
        XCTAssertEqual(Charset.decode("x-really-not-a-charset", [UInt8](utf8)), "h\u{e9}llo \u{4e2d}")
        let latin: [UInt8] = [0x63, 0x61, 0x66, 0xE9]
        XCTAssertEqual(Charset.decode("x-really-not-a-charset", latin), "caf\u{e9}")
    }

    func testNilAndEmptyLabelsUseDefaultPath() {
        XCTAssertEqual(Charset.decode(nil, [0x68, 0x69]), "hi")
        XCTAssertEqual(Charset.decode("", [0x68, 0x69]), "hi")
        XCTAssertEqual(Charset.decode(nil, []), "")
        XCTAssertEqual(Charset.decode("utf-8", []), "")
    }

    func testWindows1252UndefinedBytesStayWHATWG() {
        // WHATWG windows-1252 maps the five undefined bytes (0x81 0x8D 0x8F
        // 0x90 0x9D) to themselves (C1 controls), not to U+FFFD — matching
        // the interoperable behavior of browsers and mail clients.
        XCTAssertEqual(Charset.decode("windows-1252", [0x81, 0x41]), "\u{81}A")
        XCTAssertEqual(Charset.decode("windows-1252", [0x9D, 0x41]), "\u{9D}A")
    }

    func testCP949SupersetByteBeyondEUCKR() {
        // CP949 double-byte 0x8160 maps outside EUC-KR's range; the decoder
        // must still produce a rendering, not fail.
        let decoded = Charset.decode("ks_c_5601-1987", [0x81, 0x60])
        XCTAssertFalse(decoded.isEmpty)
    }

    func testLookupCoversEveryAliasKind() {
        XCTAssertEqual(Charset.lookup(Charset.normalized("gb2312")), .foundation(0x80000632))
        XCTAssertEqual(Charset.lookup(Charset.normalized("koi8-r")), .foundation(0x80000A02))
        XCTAssertEqual(Charset.lookup(Charset.normalized("utf-16be")), .utf16BE)
        XCTAssertEqual(Charset.lookup(Charset.normalized("macintosh")), .macRoman)
        XCTAssertEqual(Charset.lookup(Charset.normalized("eucjp")), .eucJP)
        XCTAssertEqual(Charset.lookup(Charset.normalized("nope")), .defaultSniff)
        XCTAssertEqual(Charset.lookup(""), .defaultSniff)
    }

    func testMacRomanTableEdgeBytes() {
        // Generated-table edges: accents, currency, math symbols, the
        // Apple-logo PUA slot, and untouched ASCII controls.
        XCTAssertEqual(Charset.decode("mac-roman", [0x8D]), "ç")
        XCTAssertEqual(Charset.decode("mac-roman", [0x8E]), "é")
        XCTAssertEqual(Charset.decode("mac-roman", [0x9F]), "ü")
        XCTAssertEqual(Charset.decode("mac-roman", [0xDB]), "€")
        XCTAssertEqual(Charset.decode("mac-roman", [0xF0]), "\u{F8FF}")
        XCTAssertEqual(Charset.decode("mac-roman", [0xFF]), "\u{2C7}")
        XCTAssertEqual(Charset.decode("mac-roman", [0x00, 0x41, 0x7F]), "\u{0}A\u{7F}")
    }

    func testEucJpPlanesAndMalformedSequences() {
        // Halfwidth katakana (0x8E-prefixed) uses the arithmetic mapping.
        XCTAssertEqual(Charset.decode("euc-jp", [0x8E, 0xB1]), "ｱ")
        // JIS X 0212 (0x8F-prefixed plane) decodes from the generated table.
        XCTAssertEqual(Charset.decode("euc-jp", [0x8F, 0xB0, 0xA1]), "丂")
        // Malformed and truncated sequences never throw; they render U+FFFD
        // and keep everything after the bad byte.
        XCTAssertEqual(Charset.decode("euc-jp", [0x8E]), "\u{FFFD}")
        XCTAssertEqual(Charset.decode("euc-jp", [0x8F]), "\u{FFFD}")
        XCTAssertEqual(Charset.decode("euc-jp", [0x8F, 0x41]), "\u{FFFD}A")
        XCTAssertEqual(Charset.decode("euc-jp", [0x8E, 0x41]), "\u{FFFD}A")
        XCTAssertEqual(Charset.decode("euc-jp", [0xA1]), "\u{FFFD}")
        XCTAssertEqual(Charset.decode("euc-jp", [0xFF]), "\u{FFFD}")
    }
}
