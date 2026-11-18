// Fixture tests for the HTML sanitizer (DESIGN 8, TESTING "viewer security
// fixtures"). Each test is a mail-hostile markup trick that must stay
// neutralized forever. The sanitizer never throws; every input falls out as
// inert markup or text.

import XCTest

@testable import MailMIME

final class HTMLSanitizerTests: XCTestCase {
    private func sanitize(_ html: String, allowRemote: Bool = false) -> HTMLSanitizer.Result {
        HTMLSanitizer.sanitize(html, allowRemoteContent: allowRemote)
    }

    // MARK: script and active content

    func testScriptElementAndContentRemoved() {
        let result = sanitize("<p>before</p><script>alert(1)</script><p>after</p>")
        XCTAssertEqual(result.html, "<p>before</p><p>after</p>")
        XCTAssertTrue(result.hadActiveContent)
    }

    func testScriptSpellingVariantsRemoved() {
        for markup in [
            "<SCRIPT>alert(1)</SCRIPT>", "<script src=x>y</script>",
            "<script\n>alert(1)</script>", "<ScRiPt >alert(1)</sCrIpT>",
        ] {
            let result = sanitize("a\(markup)b")
            XCTAssertFalse(result.html.lowercased().contains("alert"), markup)
            XCTAssertFalse(result.html.lowercased().contains("<script"), markup)
            XCTAssertTrue(result.hadActiveContent, markup)
        }
    }

    func testEventHandlersDroppedAndFlagged() {
        let result = sanitize(
            "<p onclick=\"steal()\" onmouseover=probe()>x</p><img src=\"cid:a\" onerror=\"p()\">"
        )
        XCTAssertEqual(result.html, "<p>x</p><img src=\"cid:a\">")
        XCTAssertTrue(result.hadActiveContent)
    }

    func testIFrameObjectEmbedSVGSwallowed() {
        let tricks = [
            "<iframe src=\"http://tracker.example/f\"></iframe>after",
            "<object data=\"http://tracker.example/o\">fallback</object>after",
            "<embed src=\"http://tracker.example/e\">after",
            "<svg><image href=\"http://tracker.example/s\"></image></svg>after",
            "<svg onload=alert(1)><circle r=1></svg>after",
            "<math href=\"http://tracker.example/m\">x</math>after",
        ]
        for markup in tricks {
            let result = sanitize(markup)
            XCTAssertFalse(result.html.contains("tracker"), markup)
            XCTAssertFalse(result.html.contains("fallback"), markup)
            XCTAssertTrue(result.hadActiveContent, markup)
            XCTAssertTrue(result.html.hasSuffix("after"), markup)
        }
    }

    func testStyleElementSwallowed() {
        let result = sanitize(
            "<style>@import url(\"http://tracker.example/x\");</style><p>keep</p>"
        )
        XCTAssertEqual(result.html, "<p>keep</p>")
        XCTAssertTrue(result.hadActiveContent)
    }

    func testMetaRefreshBaseAndLinkDropped() {
        let result = sanitize(
            "<meta http-equiv=\"refresh\" content=\"0;url=http://tracker.example\">"
                + "<base href=\"http://tracker.example/\">"
                + "<link rel=\"stylesheet\" href=\"http://tracker.example/s.css\">"
                + "<p>keep</p>"
        )
        XCTAssertEqual(result.html, "<p>keep</p>")
        XCTAssertTrue(result.hadActiveContent)
    }

    func testFormTagsDroppedButTextKept() {
        let result = sanitize(
            "<form action=\"http://tracker.example\">Name: <input value=\"a\">"
                + "<button>Send</button></form>"
        )
        XCTAssertFalse(result.html.contains("<"), result.html)
        XCTAssertTrue(result.html.contains("Name:"), result.html)
        XCTAssertTrue(result.html.contains("Send"), result.html)
        XCTAssertTrue(result.hadActiveContent)
    }

    // MARK: link scheme checks

    func testJavaScriptHrefRefusedInAllEncodings() {
        let variants = [
            "javascript:alert(1)",
            "JAVASCRIPT:alert(1)",
            "java\tscript:alert(1)",
            "java\nscript:alert(1)",
            " javascript:alert(1)",
            "\u{0B}javascript:alert(1)",
            "&#106;avascript:alert(1)",
            "&#x6A;avascript:alert(1)",
            "&#106avascript:alert(1)",
            "java&colon;script:alert(1)",
            "java&NewLine;script:alert(1)",
            "vbscript:msgbox",
            "data:text/html,<script>alert(1)</script>",
            "file:///etc/passwd",
            "jAvAsCrIpT&colon;alert(1)",
        ]
        for href in variants {
            let result = sanitize("<a href=\"\(href)\">t</a>")
            XCTAssertFalse(result.html.contains("href"), "\(href) survived: \(result.html)")
            XCTAssertTrue(result.hadActiveContent, href)
        }
    }

    func testHttpsMailtoAndFragmentKeptAndReported() {
        let result = sanitize(
            "<a href=\"https://x.example/a\">one</a>"
                + "<a href=\"HTTP://Y.EXAMPLE/B\">two</a>"
                + "<a href=\"mailto:bob@example.org\">three</a>"
                + "<a href=\"#top\">four</a>"
        )
        XCTAssertEqual(result.links.count, 4)
        XCTAssertEqual(result.links[0].href, "https://x.example/a")
        XCTAssertTrue(result.links[0].isExternal)
        XCTAssertEqual(result.links[1].href, "HTTP://Y.EXAMPLE/B")
        XCTAssertTrue(result.links[1].isExternal)
        XCTAssertEqual(result.links[2].href, "mailto:bob@example.org")
        XCTAssertFalse(result.links[2].isExternal)
        XCTAssertEqual(result.links[3].href, "#top")
        XCTAssertFalse(result.links[3].isExternal)
        XCTAssertFalse(result.hadActiveContent)
    }

    func testHrefEntitiesDecodedThenReescaped() {
        let result = sanitize("<a href=\"http://x.example/?a=1&amp;b=2\">t</a>")
        XCTAssertEqual(result.html, "<a href=\"http://x.example/?a=1&amp;b=2\">t</a>")
        XCTAssertEqual(result.links.first?.href, "http://x.example/?a=1&b=2")
    }

    // MARK: images and remote content

    func testRemoteImageStrippedAndRecordedByDefault() {
        let result = sanitize(
            "<img src=\"http://tracker.example/pixel\" alt=\"n\">"
                + "<img src=\"https://tracker.example/q\">"
        )
        XCTAssertFalse(result.html.contains("src="), result.html)
        XCTAssertEqual(result.remoteResources, [
            "http://tracker.example/pixel", "https://tracker.example/q",
        ])
        XCTAssertEqual(result.html, "<img alt=\"n\"><img>")
    }

    func testRemoteImageKeptWhenAllowed() {
        let html = "<img src=\"http://tracker.example/pixel\">"
        let result = sanitize(html, allowRemote: true)
        XCTAssertEqual(result.html, "<img src=\"http://tracker.example/pixel\">")
        XCTAssertEqual(result.remoteResources, ["http://tracker.example/pixel"])
    }

    func testCidAndInlineDataImagesKept() {
        let result = sanitize(
            "<img src=\"cid:part1@example\" alt=\"logo\">"
                + "<img src=\"data:image/png;base64,AAAA\">"
        )
        XCTAssertEqual(
            result.html,
            "<img src=\"cid:part1@example\" alt=\"logo\"><img src=\"data:image/png;base64,AAAA\">"
        )
        XCTAssertTrue(result.remoteResources.isEmpty)
    }

    func testNonImageDataURLRefused() {
        let result = sanitize("<img src=\"data:text/html,<script>alert(1)</script>\">")
        XCTAssertFalse(result.html.contains("src="), result.html)
    }

    func testSrcsetDroppedAndRecorded() {
        let result = sanitize(
            "<img src=\"cid:a\" srcset=\"http://tracker.example/2x 2x\">"
        )
        XCTAssertFalse(result.html.contains("srcset"), result.html)
        XCTAssertEqual(result.remoteResources, ["http://tracker.example/2x"])
    }

    // MARK: CSS screening

    func testStyleAttributeScreened() {
        let hostile = [
            "background:url(http://tracker.example/b)",
            "background:URL (http://tracker.example/b)",
            "background:URL(http://tracker.example/b)",
            "background:url&#40;http://tracker.example/b&#41;",
            "behavior:url(default.html)",
            "-moz-binding:url(http://tracker.example/x)",
            "width:expression(alert(1))",
            "background:\\75rl(http://tracker.example/x)",
            "background:url&#40;//tracker.example/x&#41;",
        ]
        for style in hostile {
            let result = sanitize("<p style=\"\(style)\">x</p>")
            XCTAssertFalse(result.html.contains("style="), "\(style): \(result.html)")
        }
    }

    func testBenignStyleAttributeKept() {
        let result = sanitize("<p style=\"color:red;font-weight:bold\">x</p>")
        XCTAssertEqual(result.html, "<p style=\"color:red;font-weight:bold\">x</p>")
        XCTAssertFalse(result.hadActiveContent)
    }

    // MARK: comments and smuggling

    func testCommentsAndConditionalCommentsRemoved() {
        let result = sanitize(
            "<!-- secret -->a<!--[if IE]><script>alert(1)</script><![endif]-->b"
        )
        XCTAssertEqual(result.html, "ab")
        XCTAssertFalse(result.html.contains("secret"))
    }

    func testUnterminatedCommentSwallowsRest() {
        let result = sanitize("<p>ok</p><!--<script>alert(1)")
        XCTAssertEqual(result.html, "<p>ok</p>")
    }

    func testNestedTagSmugglingCannotBreakOut() {
        let result = sanitize("<img src=\"x\" title=\"a>b\" alt=y>")
        XCTAssertEqual(result.html, "<img src=\"x\" alt=\"y\">")
    }

    func testDuplicateAttributeKeepsFirst() {
        let result = sanitize("<a href=\"https://good.example\" href=\"http://tracker.example\">t</a>")
        XCTAssertEqual(result.html, "<a href=\"https://good.example\">t</a>")
    }

    func testMutationPairingCannotRebuildScript() {
        // The classic mXSS pairing trick: both halves are dropped, and no
        // output is ever produced from unparsed markup. Leftover "alert(1)"
        // is plain text, not markup.
        let result = sanitize("<scr<script>ipt>alert(1)</scr</script>ipt>")
        XCTAssertFalse(result.html.lowercased().contains("<script"), result.html)
        XCTAssertFalse(result.html.contains("<"), result.html)
    }

    // MARK: text tolerance

    func testLiteralAngleBracketInTextEscaped() {
        XCTAssertEqual(sanitize("i <3 mail").html, "i &lt;3 mail")
        XCTAssertEqual(sanitize("trailing <").html, "trailing &lt;")
        XCTAssertEqual(sanitize("a < b and 5>3").html, "a &lt; b and 5>3")
    }

    func testMultibyteTextPassesThrough() {
        let text = "Grüße aus München — こんにちは"
        let result = sanitize("<p>\(text)</p>")
        XCTAssertEqual(result.html, "<p>\(text)</p>")
    }

    // MARK: real-world shape

    func testTypicalNewsletterKeepsStructure() {
        let html = """
        <html><head><title>Week</title></head><body>
        <div align="center"><h2 style="color:#333">Weekly</h2>
        <table border="0" cellpadding="4"><tr><td colspan="2">A</td></tr></table>
        <p>Read <a href="https://news.example/post">more</a>.</p>
        <img src="cid:logo@news.example" width="120" alt="logo">
        </div></body></html>
        """
        let result = sanitize(html)
        XCTAssertTrue(result.html.contains("<h2 style=\"color:#333\">Weekly</h2>"), result.html)
        XCTAssertTrue(result.html.contains("<table border=\"0\" cellpadding=\"4\">"), result.html)
        XCTAssertTrue(result.html.contains("<td colspan=\"2\">A</td>"), result.html)
        XCTAssertTrue(result.html.contains("<a href=\"https://news.example/post\">more</a>"), result.html)
        XCTAssertTrue(result.html.contains("src=\"cid:logo@news.example\""), result.html)
        XCTAssertFalse(result.html.contains("<title"), result.html)
        XCTAssertFalse(result.hadActiveContent)
        XCTAssertEqual(result.links.count, 1)
        XCTAssertTrue(result.remoteResources.isEmpty)
    }

    // MARK: fuzz corpus

    func testHostileCorpusProducesNoExecutableMarkup() {
        let corpus = [
            "<script>alert(1)</script>",
            "<img src=x onerror=alert(1)>",
            "<img src=\"javascript:alert(1)\">",
            "<a href=\"jav&#x09;ascript:alert(1)\">x</a>",
            "<a href=\"&#14; javascript:alert(1)\">x</a>",
            "<iframe srcdoc=\"<script>alert(1)</script>\"></iframe>",
            "<body onload=alert(1)>",
            "<svg/onload=alert(1)>",
            "<video><source onerror=alert(1)></video>",
            "<form><button formaction=javascript:alert(1)>go</button></form>",
            "<input onfocus=alert(1) autofocus>",
            "<object data=\"data:text/html;base64,PHNjcmlwdD4=\"></object>",
            "<style>@keyframes x{}</style><b>keep</b>",
            "<!--<img src=\"--><img src=x onerror=alert(1)//\">",
            "<div style=\"background:url(&#106;avascript:alert(1))\">x</div>",
            "<div style=\"width:expression(alert(1))\">x</div>",
            "<a href=\"javascript&colon;alert(1)\">x</a>",
            "<a href=\"&Tab;javascript:alert(1)\">x</a>",
            "<meta http-equiv=refresh content=\"0;url=javascript:alert(1)\">",
            "<isindex action=javascript:alert(1) type=image>",
            "<math><mtext><table><mglyph><style><!--</style><img src=x onerror=alert(1)>",
            "<svg><animate onbegin=alert(1) attributeName=x></svg>",
            "<a href=\"http://good.example\" onclick=alert(1)>ok</a>",
            "<template><script>alert(1)</script></template>",
        ]
        let forbidden = [
            "<script", "<iframe", "<object", "<embed", "<svg", "<math",
            "<meta", "<base", "<form", "<input", "<isindex", "<template",
            "<link", "<style", "=\"javascript", "='javascript",
            "onclick=\"", "onerror=\"", "onload=\"", "onbegin=\"",
        ]
        for markup in corpus {
            let result = sanitize(markup)
            let lowered = result.html.lowercased()
            for needle in forbidden {
                XCTAssertFalse(lowered.contains(needle), "\(markup) -> \(result.html)")
            }
        }
    }

    // MARK: entity decoding

    func testDecodeEntitiesNumericAndNamed() {
        XCTAssertEqual(HTMLSanitizer.decodeEntities("&#106;&#x6A;&#x6a;"), "jjj")
        XCTAssertEqual(HTMLSanitizer.decodeEntities("&#106avascript"), "javascript")
        XCTAssertEqual(HTMLSanitizer.decodeEntities("java&colon;script"), "java:script")
        XCTAssertEqual(HTMLSanitizer.decodeEntities("a&amp;b&lt;c"), "a&b<c")
        XCTAssertEqual(HTMLSanitizer.decodeEntities("plain"), "plain")
        XCTAssertEqual(HTMLSanitizer.decodeEntities("&unknown;x"), "&unknown;x")
        XCTAssertEqual(HTMLSanitizer.decodeEntities("&#xZZ;"), "&#xZZ;")
        XCTAssertEqual(HTMLSanitizer.decodeEntities("&#0;"), "&#0;")
    }

    // MARK: benign mail stays quiet

    func testPlainMailRaisesNoFlags() {
        let result = sanitize(
            "<p>Hello <b>alice@example.com</b>,</p><p>See the <a href=\"https://docs.example/g\">guide</a>.</p>"
        )
        XCTAssertFalse(result.hadActiveContent)
        XCTAssertTrue(result.remoteResources.isEmpty)
        XCTAssertEqual(result.links.count, 1)
    }
}
