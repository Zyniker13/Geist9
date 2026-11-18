/// Minimal WebKit content-rule-list smoke test: adding a store-compiled
/// rule list with a nil identifier crashes WebKit's content controller on
/// this OS; a named identifier works. RuleListCache pins the named form.
import XCTest
import WebKit

@testable import ViewerKit

final class RuleListSmokeTests: XCTestCase {
    /// Store-compiled rule list, added to a fresh web view, then load.
    func testStoreCompileThenAddThenLoad() throws {
        let expectation = expectation(description: "done")
        let webViewConfiguration = WKWebViewConfiguration()
        webViewConfiguration.defaultWebpagePreferences.allowsContentJavaScript = false

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), configuration: webViewConfiguration)
        webView.loadHTMLString("<p>warm</p>", baseURL: nil)

        let json = "[{\"trigger\":{\"url-filter\":\"^https?://\"},\"action\":{\"type\":\"block\"}}]"
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "geist9-smoke-test-1", encodedContentRuleList: json
        ) { list, error in
            XCTAssertNil(error)
            XCTAssertNotNil(list)
            guard let list else { expectation.fulfill(); return }
            webView.configuration.userContentController.add(list)
            webView.loadHTMLString("<p>after rule</p>", baseURL: nil)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 10)
    }
}
