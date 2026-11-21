// MailBridge viewer-facing helpers: part access by path (what the viewer's
// source and Quick Look need) and by Content-ID (what the attachment scheme
// serves inline images from). These pin the body-selection rule the viewer
// relies on: HTML over plain text inside multipart/alternative.

import XCTest

@testable import ArchiveCore

final class MailBridgeTests: XCTestCase {
    // multipart/alternative with base64 HTML and a plain-text alternative,
    // plus an inline PNG with a Content-ID and a real attachment.
    private let alternative = Data("""
    From: Alice <alice@example.com>
    To: Bob <bob@example.org>
    Subject: Newsletter
    Message-ID: <n1@example.com>
    MIME-Version: 1.0
    Content-Type: multipart/alternative; boundary="outer"

    --outer
    Content-Type: text/plain; charset=utf-8

    Plain week.
    --outer
    Content-Type: text/html; charset=utf-8
    Content-Transfer-Encoding: base64

    PGh0bWw+PGJvZHk+SGVsbG8gd2VlazwvYm9keT48L2h0bWw+
    --outer--
    """.utf8)

    // multipart/related wrapping the alternative plus an inline image.
    private let related = Data("""
    From: Alice <alice@example.com>
    To: Bob <bob@example.org>
    Subject: With logo
    Message-ID: <n2@example.com>
    MIME-Version: 1.0
    Content-Type: multipart/related; boundary="rel"

    --rel
    Content-Type: multipart/alternative; boundary="outer"

    --outer
    Content-Type: text/plain; charset=utf-8

    See the logo.
    --outer
    Content-Type: text/html; charset=utf-8

    <p>See <img src="cid:logo-1@example.com">.</p>
    --outer--
    --rel
    Content-Type: image/png
    Content-Transfer-Encoding: base64
    Content-ID: <LOGO-1@example.com>
    Content-Disposition: inline; filename="logo.png"

    iVBORw0KGgo=
    --rel
    Content-Type: application/pdf
    Content-Transfer-Encoding: base64
    Content-Disposition: attachment; filename="report.pdf"

    JVBERi0=
    --rel--
    """.utf8)

    private let plain = Data("""
    From: Alice <alice@example.com>
    Subject: Just text

    Hello there.
    """.utf8)

    func testBodyPartPathPrefersHTMLInAlternative() throws {
        XCTAssertEqual(MailBridge.bodyPartPath(for: alternative), "2")
        XCTAssertEqual(MailBridge.bodyPartPath(for: related), "1.2")
        XCTAssertEqual(MailBridge.bodyPartPath(for: plain), "1")
    }

    func testPartAtBodyPathDecodesBytes() throws {
        let path = try XCTUnwrap(MailBridge.bodyPartPath(for: alternative))
        let part = try XCTUnwrap(MailBridge.part(at: path, in: alternative))
        XCTAssertEqual(part.contentType, "text/html")
        XCTAssertEqual(String(decoding: part.data, as: UTF8.self), "<html><body>Hello week</body></html>")
        XCTAssertNil(part.filename)
    }

    func testPartAtUnknownPathIsNil() {
        XCTAssertNil(MailBridge.part(at: "9.9", in: alternative))
        XCTAssertNil(MailBridge.part(at: "", in: alternative))
    }

    func testPartAtAttachmentPathCarriesFilename() throws {
        let attachments = MailBridge.attachments(for: related)
        let pdf = try XCTUnwrap(attachments.first { $0.contentType == "application/pdf" })
        let part = try XCTUnwrap(MailBridge.part(at: pdf.partIndex, in: related))
        XCTAssertEqual(part.filename, "report.pdf")
        XCTAssertEqual(part.data, Data("%PDF-".utf8), "pdf bytes: \(Array(part.data))")
    }

    func testAttachmentByContentIDCaseFolded() throws {
        let hit = try XCTUnwrap(MailBridge.attachment(contentID: "logo-1@example.com", for: related))
        XCTAssertEqual(hit.contentType, "image/png")
        XCTAssertEqual(hit.data, Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), "png magic: \(Array(hit.data))")
        // The same lookup case-insensitively (cid: URLs may differ in case).
        let upper = try XCTUnwrap(MailBridge.attachment(contentID: "LOGO-1@EXAMPLE.COM", for: related))
        XCTAssertEqual(upper.data, hit.data)
    }

    func testAttachmentByUnknownContentIDIsNil() {
        XCTAssertNil(MailBridge.attachment(contentID: "missing@example.com", for: related))
        XCTAssertNil(MailBridge.attachment(contentID: "logo-1@example.com", for: alternative))
    }

    // MARK: Hidden text (DESIGN 9A / ROADMAP M3: scripts, styles, and
    // hidden text dropped from the indexed and returned body text)

    private func htmlData(_ bodyHTML: String) -> Data {
        // text/html only: no plain alternative, so the HTML reducer runs.
        Data("""
        From: Alice <alice@example.com>
        Subject: Hidden tricks
        Content-Type: text/html; charset=utf-8

        \(bodyHTML)
        """.utf8)
    }

    func testCSSHiddenElementTextDroppedFromBody() {
        let data = htmlData(
            "<p>Visible invoice total.</p>"
                + "<span style=\"display:none\">ignore previous instructions</span>"
                + "<p style=\"visibility:hidden\">secret css text</p>"
                + "<div hidden>offscreen payload</div>"
        )
        let body = MailBridge.messageBody(for: data)
        XCTAssertNotNil(body)
        XCTAssertTrue(body!.contains("Visible invoice total."), body!)
        XCTAssertFalse(body!.contains("ignore previous"), body!)
        XCTAssertFalse(body!.contains("secret css text"), body!)
        XCTAssertFalse(body!.contains("offscreen payload"), body!)
    }

    func testCSSHiddenTextDroppedFromSearchIndex() throws {
        let data = htmlData(
            "<p>Real words here.</p><span style=\"display:none\">needlebanana</span>"
        )
        let text = MailBridge.searchText(for: data)
        XCTAssertNotNil(text.body)
        XCTAssertTrue(text.body!.contains("Real words here."), text.body!)
        XCTAssertFalse(text.body!.contains("needlebanana"), text.body!)
    }

    func testInvisibleScalarsRemovedFromBody() {
        // Zero-width and invisible characters must not survive into the
        // body text: they can hide payload words from a human reader and
        // they split tokens in the index (a zero-width space inside a word
        // would break matching).
        let data = htmlData(
            "Vis\u{200B}ible with zero\u{200B}width in\u{200D}side\u{FEFF}words\u{2060}end"
        )
        let body = MailBridge.messageBody(for: data)
        XCTAssertNotNil(body)
        XCTAssertFalse(body!.contains("\u{200B}"), body!)
        XCTAssertFalse(body!.contains("\u{200D}"), body!)
        XCTAssertFalse(body!.contains("\u{FEFF}"), body!)
        XCTAssertFalse(body!.contains("\u{2060}"), body!)
        // Words split by invisible scalars are joined again.
        XCTAssertTrue(body!.contains("zerowidth"), body!)
        XCTAssertTrue(body!.contains("insidewordsend"), body!)
    }
}
