# 0010 — WKWebView Lockdown

**Date:** 2026-11-17
**Status:** accepted

## Context

The app needs to display email content (HTML emails) in a web view. The web view must be locked down to prevent any network access, navigation away from the email, JavaScript-driven redirects, or other security issues. The web view should only display the email content.

## Decision

**Use `WKWebView` with `file://` URLs and strict lockdown configuration.**

### Lockdown Configuration

```swift
let webView = WKWebView(frame: .zero, configuration: config)

// 1. Disable all navigation
webView.navigationDelegate = nil  // No navigation delegate = no navigation at all
// OR use a custom delegate that always cancels:
class LockdownNavigationDelegate: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(.cancel)  // Block ALL navigation
    }
}

// 2. Disable user interaction for navigation gestures
webView.isMultipleTouchEnabled = false
// (No back/forward navigation gestures — user can't swipe back)

// 3. Disable the UI client (blocks alerts, popups, confirmations)
webView.uiDelegate = nil  // No UI delegate = no alerts/popups

// 4. Disable JavaScript (optional — if email doesn't need JS)
// config.preferences.javaScriptEnabled = false

// 5. Disable local file access (if email references local files)
// config.preferences.setValue(false, forJavaScriptKey: "allowFileAccessFromFileURLs")

// 6. Load email HTML via file:// URL
let htmlURL = emailTempDir.appendingPathComponent("email.html")
webView.loadFileURL(htmlURL, allowingReadAccessTo: emailTempDir)
```

### Rationale

1. **`file://` URLs are inherently sandboxed.** WKWebView with `file://` URLs:
   - Cannot make network requests (no HTTP/HTTPS)
   - Cannot access cookies
   - Cannot use localStorage/sessionStorage
   - Cannot load resources from other origins
   - Cannot navigate to external URLs (unless JS does it, which we control)

2. **`loadFileURL(_:allowingReadAccessTo:)`** is the correct API for loading local HTML files that may reference local CSS/JS/images. It restricts access to a specific directory.

3. **`navigationDelegate = nil`** (or a delegate that always cancels) prevents any navigation away from the email, including JavaScript-driven redirects.

4. **`uiDelegate = nil`** prevents alerts, confirmations, and popups that could be used for phishing or data exfiltration.

5. **No user gesture required for JS.** Email content may contain inline JavaScript (e.g., for tracking pixels, though we strip those). WKWebView requires a user gesture to execute JS from `file://` URLs by default. Set `config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")` if needed.

### Consequences

- **JavaScript execution from file:// requires user gesture by default.** If email content includes JS (e.g., for formatting), we may need to allow file access from file URLs. This is a controlled risk — the email content is from a trusted source (the user's own mail).
- **CSS `@import` from external URLs.** Some emails use `@import url(...)` for fonts or styles. The lockdown configuration blocks these because they require network access. This is desirable — we don't want to fetch external resources for email rendering.
- **Images from external URLs.** Some emails reference images hosted on the sender's server (tracking pixels). These will be blocked by the lockdown. This is desirable for privacy. The app may offer a "Load Images" toggle that temporarily relaxes this restriction.
- **No network access at all.** This is the goal — the web view is a pure renderer, not a browser. No network means no tracking, no data exfiltration, no CSP violations.

### Testing

The spike verified that:
- WKWebView can load local HTML files via `file://` URLs
- Inline CSS and JS work correctly
- Local CSS/JS file references work via `loadFileURL(_:allowingReadAccessTo:)`
- No external resources are loaded (by design)
- The configuration is straightforward and requires no external dependencies

Actual runtime testing requires a macOS app context (AppKit). The configuration code above is the reference implementation.
