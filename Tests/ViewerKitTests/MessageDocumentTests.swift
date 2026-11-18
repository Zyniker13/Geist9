// Pure document tests (decision 0019): rendering, cid rewrite, CSP, and
// sanitizer integration. Fast and deterministic; the WebKit lockdown layers
// are exercised in LockdownTests.

import XCTest
import WebKit

@testable import ViewerKit

final class MessageDocumentTests: XCTestCase {
    private func renderHTML(_ body: String, rowID: Int64 = 42, allowRemote: Bool = false) -> MessageDocument.Output {
        MessageDocument.render(bodyHTML: body, plainText: nil, messageRowID: rowID, allowRemoteContent: allowRemote)
    }

    func testPlainTextRendersEscaped() {
        let output = MessageDocument.render(
            bodyHTML: nil, plainText: "Line one\n<evil> & \"friends\"", messageRowID: 7, allowRemoteContent: false
        )
        XCTAssertTrue(output.isPlainText)
        XCTAssertTrue(output.html.contains("<pre class=\"bc-plain\">"), output.html)
        XCTAssertTrue(output.html.contains("Line one\n&lt;evil&gt; &amp; &quot;friends&quot;"), output.html)
        XCTAssertFalse(output.hadActiveContent)
    }

    func testHTMLBodyPassesThroughSanitizer() {
        let output = renderHTML("<p onclick=\"x()\">hi <script>alert(1)</script></p>")
        XCTAssertEqual(output.html.contains("<p>hi </p>"), true, output.html)
        XCTAssertTrue(output.hadActiveContent)
        XCTAssertTrue(output.isPlainText == false)
    }

    func testCIDSourcesRewrittenToAttachmentScheme() {
        let output = renderHTML("<img src=\"cid:part1.0203@example\" alt=\"a\">")
        XCTAssertTrue(
            output.html.contains("src=\"x-bc-mail://message/42/cid/part1.0203@example\""),
            output.html
        )
        XCTAssertFalse(output.html.contains("\"cid:"), output.html)
    }

    func testCIDWithSpecialCharactersEncoded() {
        let output = renderHTML("<img src=\"cid:a b%c&d\">")
        XCTAssertTrue(output.html.contains("cid/a%20b%25c%26d"), output.html)
    }

    func testCIDInLinksListUnaffected() {
        // The sanitizer reports cid: hrefs in links; the document keeps them
        // as they were (the attachment handler is not a link target).
        let output = renderHTML("<a href=\"cid:part1@example\">t</a>")
        XCTAssertTrue(output.html.contains("href=\"cid:part1@example\""), output.html)
        XCTAssertEqual(output.links.first?.href, "cid:part1@example")
    }

    func testCSPBlocksEverythingByDefault() {
        let csp = MessageDocument.csp(allowRemoteContent: false)
        XCTAssertTrue(csp.contains("default-src 'none'"))
        XCTAssertTrue(csp.contains("script-src 'none'"))
        XCTAssertTrue(csp.contains("connect-src 'none'"))
        XCTAssertTrue(csp.contains("img-src x-bc-mail: data:"))
        XCTAssertFalse(csp.contains("https:"))
    }

    func testCSPAllowsHTTPOnlyUnderGrant() {
        let csp = MessageDocument.csp(allowRemoteContent: true)
        XCTAssertTrue(csp.contains("img-src x-bc-mail: data: https: http:"), csp)
    }

    func testDocumentCarriesCSPAndNoReferrer() {
        let output = renderHTML("<p>x</p>")
        XCTAssertTrue(output.html.contains(#"<meta http-equiv="Content-Security-Policy""#), output.html)
        XCTAssertTrue(output.html.contains(#"<meta name="referrer" content="no-referrer">"#), output.html)
        XCTAssertTrue(output.html.contains(#"<meta charset="utf-8">"#), output.html)
    }

    func testBaseAndAttachmentURLsParseIntoMessageSpace() {
        XCTAssertEqual(MessageDocument.baseURL(messageRowID: 9).absoluteString, "x-bc-mail://message/9/")
        XCTAssertEqual(
            MessageDocument.attachmentURL(messageRowID: 9, contentID: "a@b").absoluteString,
            "x-bc-mail://message/9/cid/a@b"
        )
    }

    func testRemoteImageFollowsGrant() {
        let html = "<img src=\"http://tracker.example/pixel\">"
        let denied = renderHTML(html, allowRemote: false)
        XCTAssertFalse(denied.html.contains("src="), denied.html)
        XCTAssertEqual(denied.remoteResources, ["http://tracker.example/pixel"])

        let granted = renderHTML(html, allowRemote: true)
        XCTAssertTrue(granted.html.contains("src=\"http://tracker.example/pixel\""), granted.html)
        XCTAssertEqual(granted.remoteResources, ["http://tracker.example/pixel"])
    }

    func testUnescapeRoundTripsSanitizerEscapes() {
        XCTAssertEqual(MessageDocument.unescape("a&amp;b&lt;c&gt;d&quot;e&#39;f"), "a&b<c>d\"e'f")
        XCTAssertEqual(MessageDocument.unescape("plain"), "plain")
        XCTAssertEqual(MessageDocument.unescape("trailing&"), "trailing&")
        XCTAssertEqual(MessageDocument.unescape("&ampx"), "&ampx")
    }
}

final class AttachmentSchemeTests: XCTestCase {
    func testParseShapes() throws {
        let good = URL(string: "x-bc-mail://message/7/cid/part1@example")!
        let parsed = try XCTUnwrap(AttachmentSchemeHandler.parse(good))
        XCTAssertEqual(parsed.rowID, 7)
        XCTAssertEqual(parsed.contentID, "part1@example")

        let encoded = URL(string: "x-bc-mail://message/12/cid/a%20b")!
        let parsedEncoded = try XCTUnwrap(AttachmentSchemeHandler.parse(encoded))
        XCTAssertEqual(parsedEncoded.contentID, "a b")

        // Not the message namespace, wrong path shapes, bad ids: nothing.
        XCTAssertNil(AttachmentSchemeHandler.parse(URL(string: "x-bc-mail://other/7/cid/x")!))
        XCTAssertNil(AttachmentSchemeHandler.parse(URL(string: "x-bc-mail://message/abc/cid/x")!))
        XCTAssertNil(AttachmentSchemeHandler.parse(URL(string: "x-bc-mail://message/7/x/x")!))
        XCTAssertNil(AttachmentSchemeHandler.parse(URL(string: "x-bc-mail://message/7/cid")!))
        XCTAssertNil(AttachmentSchemeHandler.parse(URL(string: "https://example/7/cid/x")!))
    }

    @MainActor
    func testHandlerServesResolvedContent() throws {
        let source = AttachmentSource { rowID, cid in
            rowID == 5 && cid == "logo@example" ? (data: Data([0x89, 0x50]), contentType: "image/png") : nil
        }
        let handler = AttachmentSchemeHandler(source: source)
        let url = MessageDocument.attachmentURL(messageRowID: 5, contentID: "logo@example")
        let task = MockSchemeTask(request: URLRequest(url: url))
        handler.webView(WKWebView(frame: .zero), start: task)
        XCTAssertEqual(task.responses.count, 1) // one response
        XCTAssertEqual(task.responses.first?.mimeType, "image/png")
        XCTAssertEqual(task.data, Data([0x89, 0x50]))
        XCTAssertTrue(task.finished)
        XCTAssertNil(task.error)
    }

    @MainActor
    func testHandlerAnswersNothingForUnknown() throws {
        let handler = AttachmentSchemeHandler(source: .none)
        let url = MessageDocument.attachmentURL(messageRowID: 5, contentID: "missing@example")
        let task = MockSchemeTask(request: URLRequest(url: url))
        handler.webView(WKWebView(frame: .zero), start: task)
        let http = try XCTUnwrap(task.responses.first as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 404)
        XCTAssertTrue(task.data.isEmpty)
        XCTAssertTrue(task.finished)
    }
}

/// Records what the handler delivered. Conforms to WKURLSchemeTask so the
/// handler can be exercised without a web view.
final class MockSchemeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    private(set) var responses: [URLResponse] = []
    private(set) var chunks: [Data] = []
    private(set) var finished = false
    private(set) var error: Error?

    var data: Data { chunks.reduce(Data(), +) }

    init(request: URLRequest) {
        self.request = request
    }

    func didReceive(_ response: URLResponse) { responses.append(response) }
    func didReceive(_ data: Data) { chunks.append(data) }
    func didFinish() { finished = true }
    func didFailWithError(_ error: Error) { self.error = error }
}
