// Tests for the MailMIME transfer-encoding layer (Transfer) and the MIME
// structure parser (Body). All fixtures are synthetic and use obviously
// fake values; the uuencode/BinHex fixtures were generated and verified to
// round-trip against the decoder logic.

import Foundation
import XCTest
@testable import MailMIME

final class TransferTests: XCTestCase {
    // MARK: - base64

    func testBase64RoundTrip() {
        let payload = Array("Hello, world! \u{e9}".utf8)
        let encoded = Data(payload).base64EncodedString()
        XCTAssertEqual(Transfer.base64(Array(encoded.utf8)), payload)
    }

    func testBase64MissingPadding() {
        let payload = Array("Hi".utf8)
        let full = Data(payload).base64EncodedString()
        XCTAssertTrue(full.hasSuffix("="))
        let stripped = String(full.dropLast())
        XCTAssertEqual(Transfer.base64(Array(stripped.utf8)), payload)
    }

    func testBase64Whitespace() {
        let payload = Array("Hello, world!".utf8)
        let full = Data(payload).base64EncodedString()
        let mid = full.index(full.startIndex, offsetBy: full.count / 2)
        let withNL = full[..<mid] + "\n" + full[mid...]
        XCTAssertEqual(Transfer.base64(Array(withNL.utf8)), payload)
    }

    func testBase64IgnoresNonAlphabet() {
        let payload = Array("Hello".utf8)
        let full = Data(payload).base64EncodedString()
        let junk = full + "!!!\n"
        XCTAssertEqual(Transfer.base64(Array(junk.utf8)), payload)
    }

    func testBase64TrailingSingleCharDropped() {
        // "SGVs" decodes to "Hel"; the trailing 'x' is a lone 6-bit group
        // (length % 4 == 1) and is dropped.
        XCTAssertEqual(Transfer.base64(Array("SGVsx".utf8)), Array("Hel".utf8))
    }

    func testBase64Empty() {
        XCTAssertEqual(Transfer.base64([]), [])
    }

    // MARK: - quoted-printable

    func testQPHexPair() {
        XCTAssertEqual(Transfer.quotedPrintable(Array("=3D".utf8)), Array("=".utf8))
    }

    func testQPMultibyte() {
        XCTAssertEqual(Transfer.quotedPrintable(Array("=C2=A9".utf8)), [0xC2, 0xA9])
    }

    func testQPSoftBreak() {
        // "ab" + "=" + CRLF + "cd" -> "abcd"
        let input: [UInt8] = [0x61, 0x62, 0x3D, 0x0D, 0x0A, 0x63, 0x64]
        XCTAssertEqual(Transfer.quotedPrintable(input), Array("abcd".utf8))
    }

    func testQPBareEquals() {
        XCTAssertEqual(Transfer.quotedPrintable(Array("= ".utf8)), Array("= ".utf8))
    }

    func testQPPlainText() {
        XCTAssertEqual(Transfer.quotedPrintable(Array("hello".utf8)), Array("hello".utf8))
    }

    // MARK: - uuencode

    func testUuencodeSmall() {
        let fixture = "begin 644 cafe.txt\n#04)#\nend\n"
        XCTAssertEqual(Transfer.uuencode(Array(fixture.utf8)), Array("ABC".utf8))
    }

    func testUuencodeLarge() {
        let fixture = "begin 644 cafe.txt\nM04)#1$5&1TA)2DM,34Y/4%%24U155E=865I;7%U>7V!A8F-D969G:&EJ:VQM\nM;F]P<7)S='5V=WAY>GM\\?7Y_@(&\"@X2%AH>(B8J+C(V.CY\"1DI.4E9:7F)F:\n*FYR=GI^@H:*CI   \nend\n"
        let expected = (65...164).map { UInt8($0) }
        XCTAssertEqual(Transfer.uuencode(Array(fixture.utf8)), expected)
    }

    func testUuencodeName() {
        let fixture = "begin 644 cafe.txt\n#04)#\nend\n"
        XCTAssertEqual(Transfer.uuencodeName(Array(fixture.utf8)), "cafe.txt")
    }

    func testUuencodeNotUuencoded() {
        XCTAssertEqual(Transfer.uuencode(Array("just some text\nno begin line\n".utf8)), nil)
    }

    // MARK: - BinHex

    func testBinhexRoundTrip() {
        let fixture = ";File: cafe.txt;Size: 0000016\nMSGVsbG8sIHdvcmxkISDDqQ==\nM===\n"
        let result = Transfer.binhex(Array(fixture.utf8))
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.name, "cafe.txt")
        XCTAssertEqual(result?.bytes, Array("Hello, world! \u{e9}".utf8))
    }

    func testBinhexNotBinhex() {
        XCTAssertNil(Transfer.binhex(Array("not binhex\n".utf8)))
    }

    // MARK: - decode dispatch

    func testDecodeDispatchBase64() {
        let payload = Array("Hello".utf8)
        let encoded = Data(payload).base64EncodedString()
        XCTAssertEqual(Transfer.decode(encoding: "base64", Array(encoded.utf8)), payload)
    }

    func testDecodeDispatchQP() {
        XCTAssertEqual(Transfer.decode(encoding: "quoted-printable", Array("=3D".utf8)), Array("=".utf8))
    }

    func testDecodePassthrough() {
        let bytes = Array("plain".utf8)
        XCTAssertEqual(Transfer.decode(encoding: "7bit", bytes), bytes)
        XCTAssertEqual(Transfer.decode(encoding: "8bit", bytes), bytes)
        XCTAssertEqual(Transfer.decode(encoding: "binary", bytes), bytes)
        XCTAssertEqual(Transfer.decode(encoding: "", bytes), bytes)
        XCTAssertEqual(Transfer.decode(encoding: "x-unknown", bytes), bytes)
    }

    func testDecodeNil() {
        let bytes = Array("plain".utf8)
        XCTAssertEqual(Transfer.decode(encoding: nil, bytes), bytes)
    }
}

final class BodyTests: XCTestCase {
    // MARK: - leaves

    func testSimpleTextLeaf() {
        let msg = "From: alice@example.com\nTo: bob@example.org\nSubject: Hi\nContent-Type: text/plain; charset=utf-8\n\nHello there\n"
        let part = MIMEParser.parse(Data(msg.utf8))
        XCTAssertEqual(part.kind, .leaf)
        XCTAssertEqual(part.text, "Hello there\n")
    }

    func testMultipartMixed() {
        let msg = """
        From: alice@example.com
        Subject: Mixed
        Content-Type: multipart/mixed; boundary="B1"

        --B1
        Content-Type: text/plain; charset=utf-8

        Part one
        --B1
        Content-Type: text/plain; charset=utf-8

        Part two
        --B1--
        """
        let part = MIMEParser.parse(Data(msg.utf8))
        XCTAssertEqual(part.kind, .multipart)
        XCTAssertEqual(part.children.count, 2)
        XCTAssertEqual(part.children[0].text, "Part one\n")
        XCTAssertEqual(part.children[1].text, "Part two\n")
    }

    func testMultipartBase64Attachment() {
        let msg = """
        From: alice@example.com
        Subject: Attachment
        Content-Type: multipart/mixed; boundary="B1"

        --B1
        Content-Type: text/plain; charset=utf-8

        Body text
        --B1
        Content-Type: application/octet-stream; name="data.bin"
        Content-Disposition: attachment; filename="data.bin"
        Content-Transfer-Encoding: base64

        SGVsbG8=
        --B1--
        """
        let part = MIMEParser.parse(Data(msg.utf8))
        XCTAssertEqual(part.children.count, 2)
        let attach = part.children[1]
        XCTAssertEqual(attach.filename, "data.bin")
        XCTAssertEqual(attach.decodedBody, Array("Hello".utf8))
    }

    func testNestedMessage() {
        let inner = "From: inner@example.com\nSubject: Inner\n\nInner body\n"
        let innerB64 = Data(inner.utf8).base64EncodedString()
        let msg = """
        From: alice@example.com
        Subject: Outer
        Content-Type: message/rfc822
        Content-Transfer-Encoding: base64

        \(innerB64)
        """
        let part = MIMEParser.parse(Data(msg.utf8))
        XCTAssertEqual(part.kind, .nestedMessage)
        let innerPart = part.nestedMessage
        XCTAssertNotNil(innerPart)
        XCTAssertEqual(innerPart?.text, "Inner body\n")
    }

    func testMultipartWithoutBoundary() {
        let msg = "From: alice@example.com\nContent-Type: multipart/mixed\n\nraw body\n"
        let part = MIMEParser.parse(Data(msg.utf8))
        // No usable boundary: keep the raw body as a leaf.
        XCTAssertEqual(part.kind, .leaf)
        XCTAssertEqual(part.bodyBytes, Array("raw body\n".utf8))
    }

    // MARK: - header accessors

    func testFilenameFromDisposition() {
        let msg = """
        Content-Type: application/octet-stream
        Content-Disposition: attachment; filename="report.pdf"

        body
        """
        let part = MIMEParser.parse(Data(msg.utf8))
        XCTAssertEqual(part.filename, "report.pdf")
    }

    func testFilenameFromContentType() {
        let msg = """
        Content-Type: application/octet-stream; filename="notes.txt"

        body
        """
        let part = MIMEParser.parse(Data(msg.utf8))
        XCTAssertEqual(part.filename, "notes.txt")
    }

    func testContentID() {
        let msg = """
        Content-Type: text/plain
        Content-ID: <Abc123@host>

        body
        """
        let part = MIMEParser.parse(Data(msg.utf8))
        XCTAssertEqual(part.contentID, "abc123@host")
    }

    func testTransferEncoding() {
        let msg = """
        Content-Type: text/plain
        Content-Transfer-Encoding: base64

        body
        """
        let part = MIMEParser.parse(Data(msg.utf8))
        XCTAssertEqual(part.transferEncoding, "base64")
    }

    func testContentTypeSplit() {
        let msg = """
        Content-Type: text/html; charset="UTF-8"; boundary=x

        body
        """
        let part = MIMEParser.parse(Data(msg.utf8))
        let ct = part.contentType
        XCTAssertEqual(ct.main, "text/html")
        XCTAssertEqual(ct.parameters["charset"], "UTF-8")
    }

    // MARK: - leaves()

    func testLeavesDepthFirst() {
        let msg = """
        From: alice@example.com
        Content-Type: multipart/mixed; boundary="B1"

        --B1
        Content-Type: text/plain; charset=utf-8

        One
        --B1
        Content-Type: multipart/alternative; boundary="B2"

        --B2
        Content-Type: text/plain; charset=utf-8

        Two
        --B2
        Content-Type: text/html; charset=utf-8

        <html>Three</html>
        --B2--
        --B1--
        """
        let part = MIMEParser.parse(Data(msg.utf8))
        let leaves = part.leaves()
        XCTAssertEqual(leaves.count, 3)
        XCTAssertEqual(leaves[0].text, "One\n")
        XCTAssertEqual(leaves[1].text, "Two\n")
        XCTAssertEqual(leaves[2].text, "<html>Three</html>\n")
    }

    // MARK: - charset

    func testCharsetText() {
        var bytes = Array("Content-Type: text/plain; charset=iso-8859-1\n\n".utf8)
        bytes.append(0xE9) // Latin-1 é
        bytes.append(0x0A)
        let part = MIMEParser.parse(Data(bytes))
        XCTAssertEqual(part.text, "\u{e9}\n")
    }

    func testTextNilForNonText() {
        let msg = """
        Content-Type: application/octet-stream

        body
        """
        let part = MIMEParser.parse(Data(msg.utf8))
        XCTAssertNil(part.text)
    }

    func testTextNilForMultipart() {
        let msg = """
        Content-Type: multipart/mixed; boundary="B1"

        --B1
        Content-Type: text/plain; charset=utf-8

        One
        --B1--
        """
        let part = MIMEParser.parse(Data(msg.utf8))
        XCTAssertNil(part.text)
    }
}
