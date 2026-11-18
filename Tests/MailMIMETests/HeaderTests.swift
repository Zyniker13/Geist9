// Header layer tests (M1.6): block scanning and unfolding, RFC 2047 encoded
// words (including split multibyte repair), RFC 5322 addresses and dates,
// RFC 2231 parameters, message identity extraction.

import XCTest
@testable import MailMIME

final class HeaderBlockTests: XCTestCase {
    func testSimpleCRLFHeaders() {
        let raw = "From: alice@example.com\r\nTo: bob@example.org\r\nSubject: Hello\r\n\r\nbody"
        let block = HeaderScanner.scan(Data(raw.utf8))
        XCTAssertEqual(block.fields.count, 3)
        XCTAssertEqual(block.first("from")?.valueText, "alice@example.com")
        XCTAssertEqual(block.first("Subject")?.valueText, "Hello")
        XCTAssertEqual(block.bodyStart, Data(raw.utf8).count - 4)
    }

    func testBareLFHeaders() {
        let raw = "From: alice@example.com\nSubject: LF only\n\nbody"
        let block = HeaderScanner.scan(Data(raw.utf8))
        XCTAssertEqual(block.fields.count, 2)
        XCTAssertEqual(block.first("Subject")?.valueText, "LF only")
    }

    func testFoldedHeader() {
        let raw = "Subject: first\r\n second\r\n\tthird\r\nX-Other: v\r\n\r\n"
        let block = HeaderScanner.scan(Data(raw.utf8))
        XCTAssertEqual(block.fields.count, 2)
        XCTAssertEqual(block.first("Subject")?.valueText, "first second third")
        XCTAssertEqual(block.first("X-Other")?.valueText, "v")
    }

    func testMultipleSameNameFieldsKeepOrder() {
        let raw = "Received: one\r\nReceived: two\r\nReceived: three\r\n\r\n"
        let block = HeaderScanner.scan(Data(raw.utf8))
        XCTAssertEqual(block.all("received").map(\.valueText), ["one", "two", "three"])
    }

    func testCaseInsensitiveLookup() {
        let raw = "MESSAGE-ID: <a@b>\r\n\r\n"
        let block = HeaderScanner.scan(Data(raw.utf8))
        XCTAssertEqual(block.first("Message-Id")?.valueText, "<a@b>")
    }

    func testNoBlankLine() {
        let raw = "From: a@b\r\nSubject: no blank line"
        let block = HeaderScanner.scan(Data(raw.utf8))
        XCTAssertEqual(block.fields.count, 2)
        XCTAssertEqual(block.bodyStart, Data(raw.utf8).count)
    }

    func testHeaderlessBody() {
        let raw = "this is just a body with no headers\r\nmore body"
        let block = HeaderScanner.scan(Data(raw.utf8))
        XCTAssertTrue(block.fields.isEmpty)
        XCTAssertEqual(block.bodyStart, 0)
    }

    func testJunkLineContinuesPreviousField() {
        let raw = "Subject: ok\r\nthis line has no colon\r\nFrom: a@b\r\n\r\n"
        let block = HeaderScanner.scan(Data(raw.utf8))
        XCTAssertEqual(block.first("Subject")?.valueText.contains("this line has no colon"), true)
        XCTAssertEqual(block.first("From")?.valueText, "a@b")
    }

    func testMissingSpaceAfterColon() {
        let raw = "Subject:no space\r\n\r\n"
        let block = HeaderScanner.scan(Data(raw.utf8))
        XCTAssertEqual(block.first("Subject")?.valueText, "no space")
    }

    func testEmptyValue() {
        let raw = "X-Empty:\r\nX-Full: v\r\n\r\n"
        let block = HeaderScanner.scan(Data(raw.utf8))
        XCTAssertEqual(block.first("X-Empty")?.valueText, "")
        XCTAssertEqual(block.first("X-Full")?.valueText, "v")
    }

    func testRaw8BitHeaderBytesPreserved() {
        var raw = Data("Subject: ".utf8)
        raw.append(contentsOf: [0xC3, 0xA9]) // UTF-8 é
        raw.append(Data("\r\n\r\n".utf8))
        let block = HeaderScanner.scan(raw)
        XCTAssertEqual(block.first("Subject")?.valueBytes, [0xC3, 0xA9])
    }
}

final class EncodedWordTests: XCTestCase {
    func testBase64Word() {
        // "Hello" in UTF-8 base64.
        XCTAssertEqual(EncodedWord.decode("=?UTF-8?B?SGVsbG8=?="), "Hello")
    }

    func testQuotedPrintableWord() {
        // "a b" → a_b with =41 escapes.
        XCTAssertEqual(EncodedWord.decode("=?US-ASCII?Q?a_b=41?="), "a bA")
    }

    func testMixedPlaintextAndWords() {
        // ZsOpcw== decodes to "fés" (f, C3 A9, s).
        XCTAssertEqual(EncodedWord.decode("Re: =?UTF-8?B?ZsOpcw==?= text"), "Re: fés text")
    }

    func testAdjacentWordsJoinWithoutSpace() {
        // Two words separated by space decode as one string.
        XCTAssertEqual(EncodedWord.decode("=?UTF-8?B?SGVsbG8=?= =?UTF-8?B?V29ybGQ=?="), "HelloWorld")
    }

    func testSplitMultibyteReassembles() {
        // "é" is C3 A9 in UTF-8. Split across two B words of the same charset,
        // the bytes reassemble before decoding.
        let c3 = Data([0xC3]).base64EncodedString() // ww==
        let a9 = Data([0xA9]).base64EncodedString() // qQ==
        XCTAssertEqual(EncodedWord.decode("=?UTF-8?B?\(c3)?= =?UTF-8?B?\(a9)?="), "é")
        // Same via Q encoding split.
        XCTAssertEqual(EncodedWord.decode("=?UTF-8?Q?=C3?= =?UTF-8?Q?=A9?="), "é")
        // Whole char in one word as reference.
        let whole = Data([0xC3, 0xA9]).base64EncodedString() // w6k=
        XCTAssertEqual(EncodedWord.decode("=?UTF-8?B?\(whole)?="), "é")
    }

    func testISO8859Word() {
        // café in ISO-8859-1: 63 61 66 E9.
        XCTAssertEqual(EncodedWord.decode("=?ISO-8859-1?Q?caf=E9?="), "café")
    }

    func testWindows1252Word() {
        // 0x93 is a left double quote in 1252.
        XCTAssertEqual(EncodedWord.decode("=?WINDOWS-1252?Q?x=93y?="), "x\u{201C}y")
    }

    func testUnknownCharsetFallsBack() {
        // UTF-8 bytes labelled with a bogus charset still decode via sniffing.
        XCTAssertEqual(EncodedWord.decode("=?X-BOGUS?B?w6k=?="), "é")
    }

    func testMalformedStaysLiteral() {
        XCTAssertEqual(EncodedWord.decode("not an encoded word"), "not an encoded word")
        XCTAssertEqual(EncodedWord.decode("=?UTF-8?B?unterminated"), "=?UTF-8?B?unterminated")
        XCTAssertEqual(EncodedWord.decode("=?UTF-8?X?bad-enc?="), "=?UTF-8?X?bad-enc?=")
    }

    func testLowercaseEncodings() {
        XCTAssertEqual(EncodedWord.decode("=?utf-8?q?Ab_C?="), "Ab C")
    }

    func testTolerantBase64Padding() {
        // "a" is YQ==; writers sometimes send YQ (missing padding).
        XCTAssertEqual(EncodedWord.decode("=?UTF-8?B?YQ?="), "a")
    }

    func testSubjectWithBodyCharsetFallback() {
        // Raw 8-bit subject in Latin-1 with no encoded word, fed as bytes.
        var raw = Data("Subject: ".utf8)
        raw.append(contentsOf: [0x63, 0x61, 0x66, 0xE9])
        let block = HeaderScanner.scan(raw)
        let headers = Headers(block)
        // Lossy UTF-8 alone would mangle E9; the fallback charset repairs it.
        XCTAssertEqual(headers.subject(bodyCharset: "iso-8859-1"), "café")
        // And through the decoder directly, with the same byte sequence.
        XCTAssertEqual(EncodedWord.decode([0x63, 0x61, 0x66, 0xE9], fallback: "iso-8859-1"), "café")
    }
}

final class AddressTests: XCTestCase {
    func testBareAddress() {
        XCTAssertEqual(AddressParser.parse("bob@example.org"), [EmailAddress(address: "bob@example.org")])
    }

    func testDisplayName() {
        XCTAssertEqual(
            AddressParser.parse("Bob Examples <bob@example.org>"),
            [EmailAddress(name: "Bob Examples", address: "bob@example.org")]
        )
    }

    func testQuotedDisplayName() {
        XCTAssertEqual(
            AddressParser.parse("\"Smith, Bob\" <bob@example.org>"),
            [EmailAddress(name: "Smith, Bob", address: "bob@example.org")]
        )
    }

    func testCommentIgnored() {
        XCTAssertEqual(
            AddressParser.parse("bob@example.org (Bob at Example)"),
            [EmailAddress(address: "bob@example.org")]
        )
        XCTAssertEqual(
            AddressParser.parse("(weird) Bob <bob@example.org> (comment)"),
            [EmailAddress(name: "Bob", address: "bob@example.org")]
        )
    }

    func testMultipleAddresses() {
        let parsed = AddressParser.parse("alice@example.com, Bob <bob@example.org>, carol@example.net")
        XCTAssertEqual(parsed.map(\.address), ["alice@example.com", "bob@example.org", "carol@example.net"])
    }

    func testGroupFlattens() {
        let parsed = AddressParser.parse("Team: alice@example.com, bob@example.org;")
        XCTAssertEqual(parsed.map(\.address), ["alice@example.com", "bob@example.org"])
    }

    func testObsoleteRouteDropped() {
        XCTAssertEqual(
            AddressParser.parse("<@relay.example.com:user@example.com>"),
            [EmailAddress(address: "user@example.com")]
        )
    }

    func testUTF8DisplayName() {
        XCTAssertEqual(
            AddressParser.parse("Böb <bob@example.org>"),
            [EmailAddress(name: "Böb", address: "bob@example.org")]
        )
    }

    func testEmptyAndJunkTolerated() {
        XCTAssertEqual(AddressParser.parse("").count, 0)
        XCTAssertEqual(AddressParser.parse(",,,").count, 0)
        XCTAssertEqual(AddressParser.parse("nobody").count, 0)
    }

    func testMissingAngleBracket() {
        // Display name then bare address without <> — salvage the address.
        let parsed = AddressParser.parse("Bob bob@example.org")
        XCTAssertEqual(parsed.map(\.address), ["bob@example.org"])
        XCTAssertEqual(parsed.first?.name, "Bob")
    }
}

final class DateTests: XCTestCase {
    func testModernDate() {
        let date = MessageDate.parse("Tue, 17 Nov 2026 10:30:00 +0000")
        XCTAssertNotNil(date)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date!)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 11)
        XCTAssertEqual(components.day, 17)
        XCTAssertEqual(components.hour, 10)
        XCTAssertEqual(components.minute, 30)
    }

    func testZoneConversion() {
        // 10:30 EST = 15:30 UTC.
        let date = MessageDate.parse("Tue, 17 Nov 2026 10:30:00 -0500")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(calendar.dateComponents([.hour], from: date).hour, 15)
        // Named zone.
        let named = MessageDate.parse("Tue, 17 Nov 2026 10:30:00 EST")!
        XCTAssertEqual(calendar.dateComponents([.hour], from: named).hour, 15)
    }

    func testObsoleteTwoDigitYear() {
        let old = MessageDate.parse("Tue, 1 Jan 77 00:00:00 +0000")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(calendar.dateComponents([.year], from: old).year, 1977)
        let y2k = MessageDate.parse("Sat, 1 Jan 05 00:00:00 +0000")!
        XCTAssertEqual(calendar.dateComponents([.year], from: y2k).year, 2005)
    }

    func testCommentsStripped() {
        let date = MessageDate.parse("Tue, 17 Nov 2026 10:30:00 +0000 (Wednesday)")
        XCTAssertNotNil(date)
    }

    func testNoSeconds() {
        XCTAssertNotNil(MessageDate.parse("17 Nov 2026 10:30 +0000"))
    }

    func testNoWeekday() {
        XCTAssertNotNil(MessageDate.parse("17 Nov 2026 10:30:00 +0000"))
    }

    func testMilitaryZoneAsUTC() {
        let date = MessageDate.parse("Tue, 17 Nov 2026 10:30:00 K")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(calendar.dateComponents([.hour], from: date).hour, 10)
    }

    func testGarbageReturnsNil() {
        XCTAssertNil(MessageDate.parse("not a date"))
        XCTAssertNil(MessageDate.parse(""))
        XCTAssertNil(MessageDate.parse("32 Foo 2026 99:99:99 +0000"))
    }
}

final class ParameterTests: XCTestCase {
    func testSimpleSplit() {
        let (main, params) = HeaderParameters.split("text/plain; charset=utf-8")
        XCTAssertEqual(main, "text/plain")
        XCTAssertEqual(params.count, 1)
        XCTAssertEqual(params[0].name, "charset")
        XCTAssertEqual(params[0].value, "utf-8")
    }

    func testQuotedSemicolon() {
        let (main, params) = HeaderParameters.split("text/plain; name=\"a;b.txt\"; charset=us-ascii")
        XCTAssertEqual(main, "text/plain")
        XCTAssertEqual(params[0].value, "a;b.txt")
        XCTAssertEqual(params[1].value, "us-ascii")
    }

    func testEscapedQuotes() {
        let (_, params) = HeaderParameters.split("application/octet-stream; name=\"say \\\"hi\\\".txt\"")
        XCTAssertEqual(params[0].value, "say \"hi\".txt")
    }

    func test2231ExtendedValue() {
        let (_, params) = HeaderParameters.split("application/pdf; filename*=UTF-8''caf%C3%A9.pdf")
        let resolved = HeaderParameters.resolve(params)
        XCTAssertEqual(resolved["filename"], "café.pdf")
    }

    func test2231WithCharsetAndLanguage() {
        let (_, params) = HeaderParameters.split("x/y; title*=us-ascii'en-us'This%20is%20odd")
        let resolved = HeaderParameters.resolve(params)
        XCTAssertEqual(resolved["title"], "This is odd")
    }

    func test2231Continuations() {
        let (_, params) = HeaderParameters.split(
            "x/y; name*0=\"long \"; name*1=\"value\"; name*2=\" here\""
        )
        let resolved = HeaderParameters.resolve(params)
        XCTAssertEqual(resolved["name"], "long value here")
    }

    func test2231MixedPlainAndEncodedContinuations() {
        let (_, params) = HeaderParameters.split(
            "x/y; name*0*=UTF-8''caf%C3%A9%20; name*1=plain"
        )
        let resolved = HeaderParameters.resolve(params)
        XCTAssertEqual(resolved["name"], "café plain")
    }

    func testPlainParams() {
        let (_, params) = HeaderParameters.split("multipart/mixed; boundary=\"xyz\"")
        let resolved = HeaderParameters.resolve(params)
        XCTAssertEqual(resolved["boundary"], "xyz")
    }

    func testPercentDecode() {
        XCTAssertEqual(String(decoding: HeaderParameters.percentDecode("%41%42%20C"), as: UTF8.self), "AB C")
    }
}

final class HeaderFieldTests: XCTestCase {
    func makeHeaders(_ raw: String) -> Headers {
        Headers(HeaderScanner.scan(Data(raw.utf8)))
    }

    func testSubjectDecoding() {
        let headers = makeHeaders("Subject: =?UTF-8?B?SGVsbG8=?=\r\n\r\n")
        XCTAssertEqual(headers.subject(), "Hello")
    }

    func testMessageID() {
        let headers = makeHeaders("Message-ID: <abc-123@example.com>\r\n\r\n")
        XCTAssertEqual(headers.messageID(), "<abc-123@example.com>")
    }

    func testMessageIDWithComment() {
        let headers = makeHeaders("Message-ID: <a@b> (created by mailer)\r\n\r\n")
        XCTAssertEqual(headers.messageID(), "<a@b>")
    }

    func testReferencesChain() {
        let headers = makeHeaders("References: <a@b> <c@d>\r\n <e@f>\r\n\r\n")
        XCTAssertEqual(headers.references(), ["<a@b>", "<c@d>", "<e@f>"])
    }

    func testInReplyTo() {
        let headers = makeHeaders("In-Reply-To: <parent@example.com>\r\n\r\n")
        XCTAssertEqual(headers.inReplyTo(), ["<parent@example.com>"])
    }

    func testAddressesFromTo() {
        let headers = makeHeaders("From: Alice <alice@example.com>\r\nTo: Bob <bob@example.org>, carol@example.net\r\n\r\n")
        XCTAssertEqual(headers.addresses("From").first?.address, "alice@example.com")
        XCTAssertEqual(headers.addresses("To").map(\.address), ["bob@example.org", "carol@example.net"])
    }

    func testListID() {
        let headers = makeHeaders("List-Id: Example Discussion <list.example.com>\r\n\r\n")
        XCTAssertEqual(headers.listID(), "Example Discussion <list.example.com>")
    }

    func testDate() {
        let headers = makeHeaders("Date: Tue, 17 Nov 2026 10:30:00 +0000\r\n\r\n")
        XCTAssertNotNil(headers.date())
    }
}
