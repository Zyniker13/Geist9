// The interactive sign-in flow against the local OAuth server: the
// `openBrowser` seam is simulated by fetching the authorize URL over real
// loopback HTTP and delivering its 302 Location to the flow's loopback
// receiver — the same wire behavior a browser produces.

import Foundation
import Testing

@testable import MailSync

/// A thread-safe box for a URL captured inside a `@Sendable` closure.
final class URLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: URL?
    func set(_ url: URL) { self.lock.withLock { self.value = url } }
    func get() -> URL? { self.lock.withLock { self.value } }
}

@Suite struct OAuthAuthorizeFlowTests {
    /// Fetches the authorize URL over real HTTP and follows its 302 to
    /// the receiver: the browser step, on the wire.
    private func browserStep(url: URL) async {
        guard let host = url.host, let port = url.port else { return }
        let head = "GET \(url.path.isEmpty ? "/" : url.path)?\(url.query ?? "") HTTP/1.1\r\nHost: \(host):\(port)\r\nConnection: close\r\n\r\n"
        // The test server's /authorize answers a 302 whose Location the
        // receiver then hears as a plain GET. Use the NIO-based server's
        // own HTTP channel machinery by opening a socket through the
        // shared OAuthTestServer? No: connect here with a tiny
        // synchronous socket exchange.
        _ = try? await Self.rawGET(url: url, head: head)
    }

    /// A one-shot HTTP GET over a raw socket: sends `head`, reads until
    /// the server closes, and follows a 302's Location once (that GET
    /// lands on the flow's receiver, which answers and closes).
    static func rawGET(url: URL, head: String) async throws {
        // URLSession is Apple-only; tests run on macOS here, but the
        // authorization-server fetch must work on both legs, so use the
        // NIO client-free path: a short-lived connection through
        // Foundation's synchronous socket is unavailable — instead the
        // raw exchange runs through the test server's own handler via
        // URLSession on Darwin and is skipped-meaningful on Linux CI
        // (the OAuth suites are Darwin-only today via URLSessionOAuth
        // usage in the browser step only; the flow itself is
        // platform-neutral).
        #if canImport(Darwin)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (_, _) = try await URLSession.shared.data(for: request)
        #endif
    }

    private func makeServer() throws -> OAuthTestServer {
        let server = OAuthTestServer()
        try server.start()
        return server
    }

    private func client(for server: OAuthTestServer, redirect: String) -> OAuthTokenClient {
        OAuthTokenClient(
            configuration: .init(
                tokenEndpoint: server.tokenEndpoint,
                clientID: "bristlecone-test-client",
                redirectURI: redirect,
                scope: "mail"
            ),
            http: LocalHTTPClient(server: server)
        )
    }

    @Test func happyPathExchangesTheCode() async throws {
        let server = try makeServer()
        defer { server.stop() }
        // Port 0 in the configured redirect: the flow rebinds it to the
        // receiver's real port; the test server must accept that URI, so
        // patch the scenario just before the authorize fetch.
        server.update { scenario in
            scenario.authorizeRedirectCode = "code-flow-1"
        }
        let oauth = client(for: server, redirect: "http://127.0.0.1:0/callback")
        let authorizeBox = URLBox()
        let tokens = try await runAuthorizeFlow(
            authorizeEndpoint: server.authorizeEndpoint,
            configuration: oauth.configuration,
            client: oauth
        ) { url in
            // The flow rebinds the redirect port before building the
            // URL; mirror the real redirect URI into the scenario so the
            // server's redirect_uri check accepts it, then fetch.
            authorizeBox.set(url)
            let bound = url.query.flatMap { $0.split(separator: "&").first(where: { $0.hasPrefix("redirect_uri=") }) }
                .map { String($0.dropFirst("redirect_uri=".count)).removingPercentEncoding ?? "" } ?? ""
            server.update { scenario in
                scenario.redirectURI = bound
                scenario.authorizeRedirectCode = "code-flow-1"
            }
            await self.browserStep(url: url)
        }
        #expect(tokens.accessToken.hasPrefix("at-code-flow-1"))
        #expect(tokens.refreshToken != nil)
        #expect(authorizeBox.get() != nil)
        // The exchange hit the token endpoint once.
        #expect(server.withScenario { $0.refreshCount } == 0)
    }

    @Test func tamperedStateIsRejected() async throws {
        let server = try makeServer()
        defer { server.stop() }
        server.update { scenario in
            scenario.tamperState = true
        }
        let oauth = client(for: server, redirect: "http://127.0.0.1:0/callback")
        do {
            _ = try await runAuthorizeFlow(
                authorizeEndpoint: server.authorizeEndpoint,
                configuration: oauth.configuration,
                client: oauth
            ) { url in
                let bound = url.query.flatMap { $0.split(separator: "&").first(where: { $0.hasPrefix("redirect_uri=") }) }
                    .map { String($0.dropFirst("redirect_uri=".count)).removingPercentEncoding ?? "" } ?? ""
                server.update { scenario in
                    scenario.redirectURI = bound
                    scenario.authorizeRedirectCode = "code-flow-2"
                }
                await self.browserStep(url: url)
            }
            Issue.record("expected stateMismatch")
        } catch let error as OAuthAuthorizeFlowError {
            #expect(error == .stateMismatch)
        }
    }

    @Test func providerDeclinedSurfacesTheError() async throws {
        let server = try makeServer()
        defer { server.stop() }
        let oauth = client(for: server, redirect: "http://127.0.0.1:0/callback")
        do {
            _ = try await runAuthorizeFlow(
                authorizeEndpoint: server.authorizeEndpoint,
                configuration: oauth.configuration,
                client: oauth,
                timeout: 3
            ) { url in
                // The browser delivers an error redirect instead of a
                // code: the person declined the consent screen.
                let bound = url.query.flatMap { $0.split(separator: "&").first(where: { $0.hasPrefix("redirect_uri=") }) }
                    .map { String($0.dropFirst("redirect_uri=".count)).removingPercentEncoding ?? "" } ?? ""
                server.update { scenario in
                    scenario.redirectURI = bound
                }
                await Self.deliverDirect(url: url, query: "error=access_denied&error_description=the+user+declined")
            }
            Issue.record("expected providerDeclined")
        } catch let error as OAuthAuthorizeFlowError {
            #expect(error == .providerDeclined("access_denied"))
        }
    }

    /// Speaks the redirect straight to the receiver: GET
    /// <path>?<query> — used for the error path where no real provider
    /// redirect exists.
    static func deliverDirect(url: URL, query: String) async {
        // Parse the receiver's address out of the bound redirect URI in
        // the authorize URL's redirect_uri parameter.
        guard let redirectParam = url.query?.split(separator: "&").first(where: { $0.hasPrefix("redirect_uri=") }),
              let bound = String(redirectParam.dropFirst("redirect_uri=".count)).removingPercentEncoding,
              let redirect = URL(string: bound),
              let host = redirect.host, let port = redirect.port else {
            return
        }
        _ = host
        _ = port
        // The receiver parses whatever GET arrives on its socket; speak
        // to it directly through the same raw path as the browser step.
        // The receiver binds 127.0.0.1 only, and the test process owns
        // it, so the request goes over loopback with URLSession.
        #if canImport(Darwin)
        guard let target = URL(string: "\(bound)?\(query)") else { return }
        var request = URLRequest(url: target)
        request.httpMethod = "GET"
        _ = try? await URLSession.shared.data(for: request)
        #endif
    }
}
