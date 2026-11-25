// The app-side browser seam (DESIGN 4 "OAuth Flow"): `ASWebAuthenticationSession`
// behind `runAuthorizeFlow`'s `openBrowser` closure. Lives in the app target,
// not the package: AuthenticationServices is an Apple framework, and the core
// packages build and test on Linux as well (AGENTS.md).
//
// Ownership: the flow opens the browser and must close it again — the sheet
// is the flow's UI, not a fire-and-forget window. The handle the flow passes
// carries both directions:
//
// - the flow's `BrowserSession.waitUntilFlowDone()` resolves when the sign-in
//   ends (success, decline, timeout, mismatch); the adapter then calls
//   `session.cancel()` so the sheet never outlives the exchange;
// - the person closing the sheet fires the session's completion handler with
//   no callback URL; the adapter reports that through the handle
//   (`personClosedSheet`), which ends the redirect wait at once — the sheet
//   was the redirect's only source — and the flow reports `.cancelled`.
//
// `prefersEphemeralWebBrowserSession` is on: the OAuth consent page is a
// credential-adjacent surface, and nothing from it should persist in the
// person's normal browsing session (DESIGN 4, threat model: the browser is
// untrusted).
//
// The loopback redirect URI (`http://127.0.0.1:<port>…`) is not a custom
// scheme; the session is built with an empty custom scheme, which keeps
// `ASWebAuthenticationSession`'s navigation interception active without
// claiming a scheme in the Info.plist. A provider-configured custom scheme
// keeps working the same way.

import AppKit
import AuthenticationServices
import Foundation
import MailSync

/// The `openBrowser` closure for `runAuthorizeFlow`, driving
/// `ASWebAuthenticationSession`. One sign-in at a time; constructed per
/// sign-in through `opener()`.
@MainActor
final class OAuthBrowserOpener: NSObject {
    /// The seam closure for `runAuthorizeFlow(openBrowser:)`.
    static func opener() -> @Sendable (URL, BrowserSession) async -> Void {
        { url, browser in
            await Self.present(url: url, browser: browser)
        }
    }

    /// Presents the sheet and waits for exactly one of the two endings.
    private static func present(url: URL, browser: BrowserSession) async {
        guard let anchor = Self.anchor() else {
            // No window to present in: the person never sees a consent
            // screen, so the flow must end now, not after the timeout.
            browser.openerCouldNotOpen()
            return
        }
        let opener = OAuthBrowserOpener()
        await opener.run(url: url, browser: browser, anchor: anchor)
    }

    /// The key window of the foreground app; the sheet's presentation
    /// anchor.
    private static func anchor() -> NSWindow? {
        NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible }
    }

    private func run(url: URL, browser: BrowserSession, anchor: NSWindow) async {
        // The completion closure captures the handle directly: the handle
        // is Sendable, resolves exactly once, and outlives this actor only
        // as long as the flow or the sheet needs it.
        //
        // The loopback redirect URI is not a custom scheme, so the
        // callback scheme is nil: the session then intercepts any final
        // navigation and hands the callback URL to the completion handler
        // — the AppAuth-proven pattern for RFC 8252 loopback redirects
        // (the newer Callback class has no "any URL" shape; its
        // `.https(host:path:)` variant requires associated domains, which
        // 127.0.0.1 cannot have). The deprecation warning is accepted
        // deliberately; a comment marks the reason.
        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: nil,
            completionHandler: { callbackURL, error in
                if callbackURL != nil {
                    // The redirect arrived: the flow's loopback receiver
                    // owns it; the flow proceeds and cancels the session
                    // when the sign-in ends. The handle stays untouched.
                    return
                }
                // No callback URL: the sheet went away without delivering
                // a redirect — the person closed it (the expected shape),
                // or the system killed it. Either way no redirect can
                // arrive now.
                if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                    || error == nil {
                    browser.personClosedSheet()
                } else {
                    browser.openerCouldNotOpen()
                }
            }
        )
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = true
        let started = session.start()
        guard started else {
            browser.openerCouldNotOpen()
            return
        }
        // Wait for exactly one ending: the flow finishing the sign-in
        // (cancel the sheet), or the person closing it (the completion
        // handler already reported it through the handle).
        let flowDone = await browser.waitUntilFlowDone()
        if flowDone {
            // The sign-in ended on the flow side. Dismiss the sheet; the
            // completion handler then fires with a cancellation error,
            // which the closure folds into the already-resolved handle.
            session.cancel()
        }
    }
}

extension OAuthBrowserOpener: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        Self.anchor() ?? ASPresentationAnchor()
    }
}
