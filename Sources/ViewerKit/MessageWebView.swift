// WKWebView lockdown (DESIGN 8, decision 0011, decision 0019): the viewer
// runs with content JavaScript disabled, a content-rule list that blocks
// every network scheme (with allow rules ahead of the block for the hosts a
// granted message may fetch), and a navigation delegate that turns link
// clicks into a callback for the interface to confirm.

import AppKit
import SwiftUI
import WebKit

/// Navigation decision for a click inside the viewer, computed as a pure
/// function so it is unit-testable without a running web view.
public enum NavigationDecision: Equatable, Sendable {
    /// Same-document (fragment) navigation: let WebKit handle it.
    case allow
    /// An external link the person chose: hand it to the interface, which
    /// confirms and opens it outside the webview.
    case open(URL)
    /// Everything else: silently cancel.
    case cancel
}

/// Compiles and caches content rule lists: one block-everything list, and
/// one allow-listed-hosts list per host set. Compilation is asynchronous;
/// callers load documents only once the list is in hand.
final class RuleListCache: @unchecked Sendable {
    static let shared = RuleListCache()
    private let lock = NSLock()
    private var cache: [String: WKContentRuleList] = [:]

    static func json(allowHosts: [String]) -> String {
        var rules: [String] = []
        for scheme in ["https", "http", "wss", "ws", "ftp"] {
            rules.append("""
            {"trigger":{"url-filter":"^\(scheme)://"},"action":{"type":"block"}}
            """)
        }
        // Whitelists come after the block rules: `ignore-previous-rules`
        // exempts the matching load from everything before it. The match is
        // by host (`if-domain`), because WebKit's url-filter regexes reject
        // constructs like `([/:?#]|$)`.
        for host in allowHosts {
            let lower = jsonEscaped(host.lowercased())
            rules.append("""
            {"trigger":{"url-filter":"^https?://","if-domain":["\(lower)","*.\(lower)"]},"action":{"type":"ignore-previous-rules"}}
            """)
        }
        return "[" + rules.joined(separator: ",") + "]"
    }

    func ruleList(allowHosts: [String]) async throws -> WKContentRuleList {
        let key = allowHosts.map { $0.lowercased() }.sorted().joined(separator: ",")
        if let cached = cachedRuleList(key: key) { return cached }
        let json = Self.json(allowHosts: allowHosts)
        let identifier = Self.identifier(for: key)
        let list: WKContentRuleList = try await withCheckedThrowingContinuation { continuation in
            // The completion-handler form: the string bridge happens here,
            // in the caller's context, before anything is sent across.
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: identifier, encodedContentRuleList: json
            ) { list, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let list {
                    continuation.resume(returning: list)
                } else {
                    continuation.resume(throwing: ViewerKitError.ruleListCompileFailed)
                }
            }
        }
        storeRuleList(list, key: key)
        return list
    }

    /// Escape a string for embedding inside a JSON string literal.
    private static func jsonEscaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Rule lists need a named identifier: adding a list compiled with a
    /// nil identifier crashes WebKit's content controller on this OS
    /// (RuleListSmokeTests pins that). The identifier is derived from the
    /// host-set key, so the same grant set reuses one compiled list, and
    /// WebKit's persistent store can too.
    static func identifier(for key: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return String(format: "bc-rules-%016llx", hash)
    }

    private func cachedRuleList(key: String) -> WKContentRuleList? {
        lock.lock(); defer { lock.unlock() }
        return cache[key]
    }

    private func storeRuleList(_ list: WKContentRuleList, key: String) {
        lock.lock(); defer { lock.unlock() }
        cache[key] = list
    }
}

public enum ViewerKitError: Error {
    case ruleListCompileFailed
}

/// The viewer's web view, ready for documents from `MessageDocument.render`.
/// The rules: no content JavaScript, no navigation this class does not
/// decide, no network except the attachment scheme and granted hosts.
public final class MessageWebViewCore: NSObject, WKNavigationDelegate, WKUIDelegate {
    public struct Configuration: Sendable {
        public var attachmentSource: AttachmentSource
        /// Called on the main actor when the person activates an external
        /// link. The interface confirms before handing it to the system.
        public var onOpenLink: @Sendable (URL) -> Void

        public init(
            attachmentSource: AttachmentSource,
            onOpenLink: @escaping @Sendable (URL) -> Void = { _ in }
        ) {
            self.attachmentSource = attachmentSource
            self.onOpenLink = onOpenLink
        }
    }

    public let webView: WKWebView
    private let configuration: Configuration
    private var loadedHostsKey: String?
    private var pendingDocument: (html: String, rowID: Int64)?
    private var pendingURL: URL?

    public init(configuration: Configuration) {
        let webViewConfiguration = WKWebViewConfiguration()
        webViewConfiguration.defaultWebpagePreferences.allowsContentJavaScript = false
        webViewConfiguration.preferences.javaScriptEnabled = false
        webViewConfiguration.preferences.isElementFullscreenEnabled = false
        webViewConfiguration.allowsAirPlayForMediaPlayback = false
        webViewConfiguration.mediaTypesRequiringUserActionForPlayback = .all
        webViewConfiguration.setURLSchemeHandler(
            AttachmentSchemeHandler(source: configuration.attachmentSource),
            forURLScheme: AttachmentScheme.name
        )
        self.webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), configuration: webViewConfiguration)
        self.configuration = configuration
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    /// Load a rendered document. Remote hosts listed are the hosts the
    /// person granted for this message; an empty list means no network.
    public func load(_ document: MessageDocument.Output, rowID: Int64, allowRemoteHosts: [String] = []) {
        pendingDocument = (document.html, rowID)
        armRuleList(hosts: allowRemoteHosts) { [weak self] in
            guard let self, let pending = self.pendingDocument else { return }
            self.webView.loadHTMLString(pending.html, baseURL: MessageDocument.baseURL(messageRowID: pending.rowID))
        }
    }

    /// Navigate to a URL with the same lockdown (used by tests and by any
    /// future in-app page; messages themselves load via `load`).
    public func load(from url: URL, allowRemoteHosts: [String] = []) {
        pendingURL = url
        armRuleList(hosts: allowRemoteHosts) { [weak self] in
            guard let self, let url = self.pendingURL else { return }
            self.webView.load(URLRequest(url: url))
        }
    }

    /// Compile (or reuse) the rule list for this host set and then perform
    /// the load. A web process must exist before a rule list is added, so
    /// the list is armed after a warm-up load.
    private func armRuleList(hosts: [String], then perform: @escaping @MainActor () -> Void) {
        let key = hosts.map { $0.lowercased() }.sorted().joined(separator: ",")
        guard loadedHostsKey != key else {
            perform()
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // Create the web process first: adding a content rule list
                // needs a live page, and a web view that has not loaded
                // anything has none yet.
                self.webView.loadHTMLString("", baseURL: nil)
                let list = try await RuleListCache.shared.ruleList(allowHosts: hosts)
                self.loadedHostsKey = key
                self.webView.configuration.userContentController.removeAllContentRuleLists()
                self.webView.configuration.userContentController.add(list)
                perform()
            } catch {
                // Without a rule list nothing may load: render nothing.
                self.loadedHostsKey = nil
                self.webView.loadHTMLString("", baseURL: nil)
            }
        }
    }

    /// The pure policy for one navigation. External link activations become
    /// `.open`; anything outside the message's own scheme is cancelled; only
    /// same-document moves are allowed to proceed in the webview.
    public static func policy(
        forNavigationURL url: URL?, type: WKNavigationType, linkActivated: Bool
    ) -> NavigationDecision {
        guard let url else { return .cancel }
        if url.scheme?.lowercased() == MessageDocument.attachmentSchemeName {
            return .allow
        }
        guard linkActivated, navigationTypeAllowsOpening(type) else { return .cancel }
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" || scheme == "mailto"
        else { return .cancel }
        return .open(url)
    }

    private static func navigationTypeAllowsOpening(_ type: WKNavigationType) -> Bool {
        type == .linkActivated || type == .formSubmitted
    }

    public func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        switch Self.policy(
            forNavigationURL: navigationAction.request.url,
            type: navigationAction.navigationType,
            linkActivated: navigationAction.navigationType == .linkActivated
        ) {
        case .allow:
            decisionHandler(.allow)
        case .open(let url):
            decisionHandler(.cancel)
            configuration.onOpenLink(url)
        case .cancel:
            decisionHandler(.cancel)
        }
    }

    public func webView(
        _ webView: WKWebView, createWebViewWith webViewConfiguration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // No new windows or tabs from a message. Treat a target=_blank link
        // activation like an ordinary one: the interface confirms.
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" || scheme == "mailto"
        {
            self.configuration.onOpenLink(url)
        }
        return nil
    }
}

/// SwiftUI wrapper around `MessageWebViewCore`.
public struct MessageWebView: NSViewRepresentable {
    public var configuration: MessageWebViewCore.Configuration
    public var document: MessageDocument.Output?
    public var rowID: Int64
    public var allowRemoteHosts: [String]

    public init(
        configuration: MessageWebViewCore.Configuration,
        document: MessageDocument.Output?, rowID: Int64, allowRemoteHosts: [String] = []
    ) {
        self.configuration = configuration
        self.document = document
        self.rowID = rowID
        self.allowRemoteHosts = allowRemoteHosts
    }

    public final class Coordinator {
        var core: MessageWebViewCore?
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> NSView {
        let core = MessageWebViewCore(configuration: configuration)
        context.coordinator.core = core
        if let document { core.load(document, rowID: rowID, allowRemoteHosts: allowRemoteHosts) }
        return core.webView
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        guard let document else { return }
        context.coordinator.core?.load(document, rowID: rowID, allowRemoteHosts: allowRemoteHosts)
    }
}
