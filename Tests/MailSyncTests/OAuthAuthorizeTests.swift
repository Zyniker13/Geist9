// The interactive sign-in flow against the local OAuth server: the
// `openBrowser` seam is simulated by fetching the authorize URL over real
// loopback HTTP and delivering its 302 Location to the flow's loopback
// receiver — the same wire behavior a browser produces. The browser step
// runs over NIO so it works on every CI leg; a test that needs no
// network speaks its redirect straight to the receiver.

import Foundation
import NIOCore
import NIOPosix
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
        // receiver then hears as a plain GET. Speak raw HTTP/1.1 over a
        // short-lived NIO socket so the browser step works identically on
        // every CI leg (URLSession is Apple-only and would compile away on
        // Linux, leaving the flow waiting for a redirect that never
        // comes).
        guard let first = await Self.rawGet(host: host, port: port, head: head),
              let status = first.components(separatedBy: "\r\n").first,
              status.hasPrefix("HTTP/1.1 30"),
              let location = first.components(separatedBy: "\r\n")
                  .first(where: { $0.lowercased().hasPrefix("location:") })?
                  .dropFirst("Location: ".count)
                  .trimmingCharacters(in: .whitespaces),
              let redirect = URL(string: location),
              let redirectHost = redirect.host, let redirectPort = redirect.port
        else { return }
        let followHead = "GET \(redirect.path.isEmpty ? "/" : redirect.path)?\(redirect.query ?? "") HTTP/1.1\r\nHost: \(redirectHost):\(redirectPort)\r\nConnection: close\r\n\r\n"
        _ = await Self.rawGet(host: redirectHost, port: redirectPort, head: followHead)
    }

    /// One raw HTTP GET over a short-lived NIO socket: sends `head`,
    /// collects the response until the server closes, and returns its
    /// text (nil when the connection fails). No platform-specific URL
    /// machinery — the same code runs on every CI leg.
    private static func rawGet(host: String, port: Int, head: String) async -> String? {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { group.shutdownGracefully { _ in } }
        return await withCheckedContinuation { continuation in
            ClientBootstrap(group: group)
                .connectTimeout(TimeAmount.seconds(5))
                .channelInitializer { channel in
                    channel.pipeline.addHandlers([
                        RawGetHandler(head: head, continuation: continuation),
                    ])
                }
                .connect(host: host, port: port)
                .whenFailure { _ in continuation.resume(returning: nil) }
        }
    }

    /// Sends the request head on connect, accumulates the response, and
    /// hands the text back once the server closes the connection.
    private final class RawGetHandler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer

        private let head: String
        private let continuation: CheckedContinuation<String?, Never>
        private var wrote = false
        private var buffer = ByteBuffer()
        private var resumed = false

        init(head: String, continuation: CheckedContinuation<String?, Never>) {
            self.head = head
            self.continuation = continuation
        }

        func channelActive(context: ChannelHandlerContext) {
            if !self.wrote {
                self.wrote = true
                var out = ByteBufferAllocator().buffer(capacity: self.head.utf8.count)
                out.writeString(self.head)
                context.writeAndFlush(self.wrapOutboundOut(out), promise: nil)
            }
            context.fireChannelActive()
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var chunk = self.unwrapInboundIn(data)
            self.buffer.writeBuffer(&chunk)
            // The test server answers but never closes the socket; end
            // the exchange once the response is complete: headers (the
            // blank line) plus Content-Length body bytes. Every response
            // both legs produce carries an exact Content-Length (0 for
            // the 302).
            let text = self.buffer.getString(at: self.buffer.readerIndex, length: self.buffer.readableBytes) ?? ""
            guard let headerEnd = text.range(of: "\r\n\r\n") else { return }
            let body = text[headerEnd.upperBound...]
            let header = text[..<headerEnd.lowerBound]
            var contentLength = 0
            for line in header.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("content-length:") {
                contentLength = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
            }
            guard body.utf8.count >= contentLength else { return }
            guard !self.resumed else { return }
            self.resumed = true
            self.continuation.resume(returning: text)
            context.close(promise: nil)
        }

        func errorCaught(context: ChannelHandlerContext, error: Error) {
            context.close(promise: nil)
        }

        func channelInactive(context: ChannelHandlerContext) {
            guard !self.resumed else { return }
            self.resumed = true
            let text = self.buffer.readString(length: self.buffer.readableBytes)
            self.continuation.resume(returning: text)
            context.fireChannelInactive()
        }
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
        ) { url, _ in
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
            ) { url, _ in
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
            ) { url, _ in
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

    /// A redirect that never arrives must end the flow, not park it: with
    /// a short timeout the flow throws `.timedOut` (this suite once hung
    /// the whole `swift test` run on a CI runner, where no browser exists
    /// to deliver the redirect).
    @Test func missingRedirectTimesOut() async throws {
        let server = try makeServer()
        defer { server.stop() }
        let oauth = client(for: server, redirect: "http://127.0.0.1:0/callback")
        do {
            _ = try await runAuthorizeFlow(
                authorizeEndpoint: server.authorizeEndpoint,
                configuration: oauth.configuration,
                client: oauth,
                timeout: 0.5
            ) { _, _ in
                // No browser: the authorize URL opens into the void, so
                // no redirect ever lands on the receiver.
            }
            Issue.record("expected timedOut")
        } catch let error as OAuthAuthorizeFlowError {
            #expect(error == .timedOut)
        }
    }

    /// Speaks the redirect straight to the receiver: GET
    /// `<path>?<query>`, parsed on the receiver's socket just as the
    /// browser's redirect would be. Used for the error path where no real
    /// provider redirect exists. NIO end to end, so it runs on both legs.
    static func deliverDirect(url: URL, query: String) async {
        // Parse the receiver's address out of the bound redirect URI in
        // the authorize URL's redirect_uri parameter.
        guard let redirectParam = url.query?.split(separator: "&").first(where: { $0.hasPrefix("redirect_uri=") }),
              let bound = String(redirectParam.dropFirst("redirect_uri=".count)).removingPercentEncoding,
              let redirect = URL(string: bound),
              let host = redirect.host, let port = redirect.port else {
            return
        }
        let target = redirect.path.isEmpty ? "/" : redirect.path
        let head = "GET \(target)?\(query) HTTP/1.1\r\nHost: \(host):\(port)\r\nConnection: close\r\n\r\n"
        _ = await Self.rawGet(host: host, port: port, head: head)
    }

    /// The person closing the browser sheet ends the sign-in at once —
    /// not after the timeout — and reports `.cancelled`, not an error
    /// worth alarming anyone with. The opener closure simulates the sheet:
    /// it waits a beat, then reports the close through the handle, exactly
    /// as `ASWebAuthenticationSession`'s completion handler would.
    @Test func personClosingTheSheetEndsTheFlowAtOnce() async throws {
        let server = try makeServer()
        defer { server.stop() }
        let oauth = client(for: server, redirect: "http://127.0.0.1:0/callback")
        let started = ContinuousClock.now
        do {
            _ = try await runAuthorizeFlow(
                authorizeEndpoint: server.authorizeEndpoint,
                configuration: oauth.configuration,
                client: oauth,
                timeout: 60
            ) { _, browser in
                // The sheet is up; the person closes it without going
                // through the consent screen.
                browser.personClosedSheet()
            }
            Issue.record("expected cancelled")
        } catch let error as OAuthAuthorizeFlowError {
            #expect(error == .cancelled)
        }
        // The close ended the flow in milliseconds, not at the 60 s
        // timeout: the sheet-close path must never park the flow.
        let elapsed = ContinuousClock.now - started
        #expect(elapsed < .seconds(10))
    }

    /// A sheet that can never be shown ends the flow at once with
    /// `.browserUnavailable`: the person saw nothing, so waiting for a
    /// redirect from a browser that does not exist is pointless.
    @Test func unopenableBrowserEndsTheFlowAtOnce() async throws {
        let server = try makeServer()
        defer { server.stop() }
        let oauth = client(for: server, redirect: "http://127.0.0.1:0/callback")
        let started = ContinuousClock.now
        do {
            _ = try await runAuthorizeFlow(
                authorizeEndpoint: server.authorizeEndpoint,
                configuration: oauth.configuration,
                client: oauth,
                timeout: 60
            ) { _, browser in
                // The opener could not present a sheet (no window): it
                // reports that through the handle and shows nothing.
                browser.openerCouldNotOpen()
            }
            Issue.record("expected browserUnavailable")
        } catch let error as OAuthAuthorizeFlowError {
            #expect(error == .browserUnavailable)
        }
        let elapsed = ContinuousClock.now - started
        #expect(elapsed < .seconds(10))
    }

    /// The flow cancels the browser when the sign-in ends: the handle's
    /// dismissal await resolves, so the sheet never outlives the
    /// exchange. (The success path's browser cancellation is what the
    /// adapter's `session.cancel()` is keyed to.) The sheet task must be
    /// forked outside the seam closure — the closure returning is itself
    /// one of the things the flow's end depends on, so an `async let`
    /// awaited inside it would deadlock.
    @Test func flowEndsTheBrowserOnSuccess() async throws {
        let server = try makeServer()
        defer { server.stop() }
        server.update { scenario in
            scenario.authorizeRedirectCode = "code-flow-1"
        }
        let oauth = client(for: server, redirect: "http://127.0.0.1:0/callback")
        let cancelledByFlow = SheetClosedBox()
        _ = try await runAuthorizeFlow(
            authorizeEndpoint: server.authorizeEndpoint,
            configuration: oauth.configuration,
            client: oauth
        ) { url, browser in
            let bound = url.query.flatMap { $0.split(separator: "&").first(where: { $0.hasPrefix("redirect_uri=") }) }
                .map { String($0.dropFirst("redirect_uri=".count)).removingPercentEncoding ?? "" } ?? ""
            server.update { scenario in
                scenario.redirectURI = bound
                scenario.authorizeRedirectCode = "code-flow-1"
            }
            // The adapter's sheet task, forked so it cannot block the
            // closure's return: on flow-done it would call
            // session.cancel(); here it records the resolution.
            Task {
                let done = await browser.waitUntilFlowDone()
                cancelledByFlow.set(done)
            }
            await self.browserStep(url: url)
        }
        // The flow resolves the waiter on its way out; give the detached
        // task a bounded beat to record it.
        for _ in 0..<100 {
            if cancelledByFlow.get() != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(cancelledByFlow.get() == true)
    }
}

/// A thread-safe box for the sheet-task's outcome.
final class SheetClosedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?
    func set(_ value: Bool) { self.lock.withLock { self.value = value } }
    func get() -> Bool? { self.lock.withLock { self.value } }
}
