// The local OAuth 2.0 test server (TESTING.md row "OAuth test server"):
// authorization code + PKCE, refresh rotation, revocation, and the error
// paths. A raw-socket HTTP/1.1 server (NIO is already a test dependency;
// the package gains no product dependency for a test fixture). One client
// ID, one redirect URI; behavior is scripted per request by the test.
// Runs on 127.0.0.1 port 0; every response is exactly what a real
// provider's token endpoint would send.

import Crypto
import Foundation
import NIOCore
import NIOPosix

struct OAuthTestServerScenario: Sendable {
    /// The one client ID this server accepts.
    var clientID = "bristlecone-test-client"
    /// The redirect URI the code must carry.
    var redirectURI = "http://127.0.0.1:19876/callback"
    /// The PKCE challenge the authorization request must carry.
    var codeChallenge = "N_l8xE5cV3zS8wZ2KkP0nQ9tUvWxYz0a1B2c3D4e5F6"
    /// Issued codes, each remembered until exchanged (a code is single-use).
    var validCodes: [String: String] = [:]  // code -> scope
    /// Per-code PKCE challenges captured from the authorize request
    /// (code → S256 challenge), per RFC 7636 §4.6: the verifier presented
    /// at the exchange must hash to the challenge *that code's* authorize
    /// request carried. Codes seeded directly by a test (no /authorize)
    /// have no entry here and verify against the scenario `codeChallenge`
    /// as before.
    var codeChallenges: [String: String] = [:]
    /// The refresh token(s) that still answer a refresh.
    var validRefreshTokens: Set<String> = ["r1-original"]
    /// How many refreshes have happened (rotation bookkeeping).
    var refreshCount = 0
    /// When set, the token endpoint answers with this error code instead.
    var tokenError: String? = nil
    /// When true, the token endpoint answers a valid code exchange with a
    /// rotated refresh token; otherwise it returns the same one.
    var rotatesRefreshToken = true
    /// When set, the authorize endpoint answers a valid request with a
    /// 302 redirect carrying this code — the browser step the flow's
    /// `openBrowser` seam simulates by fetching the authorize URL and
    /// following the redirect to the loopback receiver.
    var authorizeRedirectCode: String? = nil
    /// When true, the redirect the authorize endpoint issues carries a
    /// wrong `state` (tampered or replayed); the flow must reject it.
    var tamperState = false
    /// Access tokens the IMAP fixture (a separate layer) would accept.
    var acceptedAccessTokens: Set<String> = []
    /// When true, the revocation endpoint invalidates the refresh token.
    var revocationWorks = true
}

/// One HTTP request parsed off the wire.
struct OAuthTestRequest: Sendable {
    var method: String
    var path: String
    var query: [String: String]
    var body: [String: String]
    var authorization: String?

    var parameter: (String) -> String? {
        { name in self.body[name] ?? self.query[name] }
    }
}

/// The local OAuth test server. See TESTING.md: authorization code with
/// PKCE, refresh rotation, revocation, error responses.
final class OAuthTestServer: @unchecked Sendable {
    private let lock = NSLock()
    private var scenario: OAuthTestServerScenario
    private var channel: Channel?
    private var group: EventLoopGroup?
    private(set) var port: UInt16 = 0
    /// Every request line, for assertions ("POST /token").
    private(set) var requests: [(method: String, path: String)] = []

    var tokenEndpoint: URL { URL(string: "http://127.0.0.1:\(self.port)/token")! }
    var authorizeEndpoint: URL { URL(string: "http://127.0.0.1:\(self.port)/authorize")! }
    var revocationEndpoint: URL { URL(string: "http://127.0.0.1:\(self.port)/revoke")! }

    init(scenario: OAuthTestServerScenario = OAuthTestServerScenario()) {
        self.scenario = scenario
    }

    /// The scenario seed the server starts with (read-only copy).
    func currentScenario() -> OAuthTestServerScenario {
        self.withScenario { $0 }
    }

    func start() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        self.group = group
        let channel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .childChannelInitializer { channel in
                channel.pipeline.addHandlers([
                    BackPressureHandler(),
                    OAuthTestServer.HTTPHandler(server: self),
                ])
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait()
        self.channel = channel
        self.port = UInt16(channel.localAddress!.port!)
    }

    /// Closes the listening socket and tears the group down without
    /// blocking the caller.
    ///
    /// The tests run under Swift concurrency (swift-testing), where a
    /// blocking `syncShutdownGracefully()` from twelve concurrent tests
    /// wedges the cooperative pool before the event-loop threads finish
    /// spawning — a hard deadlock. Fire the async shutdown instead and
    /// keep the group alive until it reports completion; nothing here
    /// blocks, so a test's `defer { server.stop() }` returns at once.
    /// Any request arriving after the close fails at the client, which
    /// the tests treat as a failure anyway.
    func stop() {
        guard let group = self.group else { return }
        self.channel?.close(promise: nil)
        self.channel = nil
        self.group = nil
        group.shutdownGracefully { _ in }
    }

    // MARK: scenario access

    func update(_ mutate: @Sendable (inout OAuthTestServerScenario) -> Void) {
        self.lock.lock()
        defer { self.lock.unlock() }
        mutate(&self.scenario)
    }

    func withScenario<T>(_ body: (OAuthTestServerScenario) -> T) -> T {
        self.lock.lock()
        defer { self.lock.unlock() }
        return body(self.scenario)
    }

    // MARK: HTTP plumbing

    private final class HTTPHandler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer

        private let server: OAuthTestServer
        private var buffer = ByteBuffer()

        init(server: OAuthTestServer) {
            self.server = server
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var chunk = self.unwrapInboundIn(data)
            self.buffer.writeBuffer(&chunk)
            // Respond once a complete request is here. URLSession may
            // pipeline, so answer every complete request found.
            while let request = OAuthTestServer.parseRequest(&self.buffer) {
                let response = self.server.respond(request)
                var out = ByteBufferAllocator().buffer(capacity: response.utf8.count)
                out.writeString(response)
                context.writeAndFlush(self.wrapOutboundOut(out), promise: nil)
            }
        }

        func errorCaught(context: ChannelHandlerContext, error: Error) {
            context.close(promise: nil)
        }
    }

    /// Parses one complete HTTP/1.1 request from the front of `buffer`,
    /// consuming it; returns nil until a full request has arrived.
    static func parseRequest(_ buffer: inout ByteBuffer) -> OAuthTestRequest? {
        // Find the \r\n\r\n that ends the headers.
        guard let headerEnd = Self.findDoubleCRLF(in: buffer) else { return nil }
        let headerLength = headerEnd + 4 - buffer.readerIndex
        guard var headerText = buffer.readString(length: headerLength) else { return nil }
        // We consumed the header including the final CRLF of the terminator.
        headerText = String(headerText.dropLast(4))
        var lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let target = String(parts[1])
        var contentLength = 0
        var authorization: String?
        for line in lines {
            let lowered = line.lowercased()
            if lowered.hasPrefix("content-length:") {
                contentLength = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
            } else if lowered.hasPrefix("authorization:") {
                authorization = line.dropFirst("authorization:".count).trimmingCharacters(in: .whitespaces)
            }
        }
        guard buffer.readableBytes >= contentLength else { return nil }
        let bodyText = buffer.readString(length: contentLength) ?? ""
        var query: [String: String] = [:]
        var path = target
        if let questionMark = target.firstIndex(of: "?") {
            path = String(target[..<questionMark])
            let queryString = target[target.index(after: questionMark)...]
            for pair in queryString.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if kv.count == 2 {
                    query[String(kv[0])] = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                }
            }
        }
        var body: [String: String] = [:]
        for pair in bodyText.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if kv.count == 2 {
                body[String(kv[0])] = String(kv[1]).removingPercentEncoding ?? String(kv[1])
            }
        }
        return OAuthTestRequest(
            method: method, path: path, query: query, body: body,
            authorization: authorization
        )
    }

    /// The offset of the first `\r\n\r\n` within the readable region.
    static func findDoubleCRLF(in buffer: ByteBuffer) -> Int? {
        var result: Int?
        buffer.withUnsafeReadableBytes { raw in
            let bytes = Data(raw)
            result = bytes.range(of: Data("\r\n\r\n".utf8))?.lowerBound
        }
        guard let offset = result else { return nil }
        return buffer.readerIndex + offset
    }

    // MARK: the OAuth behavior

    /// Answers one request against the scripted scenario.
    func respond(_ request: OAuthTestRequest) -> String {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.requests.append((request.method, request.path))

        switch (request.path, request.method) {
        case ("/authorize", "GET"):
            // The authorize endpoint validates client, redirect, and PKCE
            // presence. When the scenario issues a code, it answers with
            // a 302 redirect to the redirect URI — exactly what the
            // browser delivers to the loopback receiver — recording the
            // issued code so the exchange consumes it (single-use).
            guard request.parameter("client_id") == self.scenario.clientID,
                  request.parameter("redirect_uri") == self.scenario.redirectURI,
                  request.parameter("code_challenge") != nil,
                  request.parameter("code_challenge_method") == "S256"
            else {
                return Self.http(400, "{\"error\": \"invalid_request\"}")
            }
            if let code = self.scenario.authorizeRedirectCode {
                self.scenario.validCodes[code] = "mail"
                // Bind the challenge the authorize request actually
                // carried to this code (RFC 7636 §4.6).
                self.scenario.codeChallenges[code] = request.parameter("code_challenge")
                var state = request.parameter("state") ?? ""
                if self.scenario.tamperState { state += "-tampered" }
                let location = "\(self.scenario.redirectURI)?code=\(code)&state=\(state)"
                return "HTTP/1.1 302 Found\r\nContent-Type: text/plain\r\nContent-Length: 0\r\nLocation: \(location)\r\nConnection: close\r\n\r\n"
            }
            return Self.http(200, "{\"ok\": true}")

        case ("/token", "POST"):
            return self.respondToken(request)

        case ("/revoke", "POST"):
            guard self.scenario.revocationWorks else {
                return Self.http(200, "{}")
            }
            let token = request.parameter("token") ?? ""
            self.scenario.validRefreshTokens.remove(token)
            self.scenario.acceptedAccessTokens.remove(token)
            return Self.http(200, "{}")

        default:
            return Self.http(404, "{\"error\": \"not_found\"}")
        }
    }

    private func respondToken(_ request: OAuthTestRequest) -> String {
        if let error = self.scenario.tokenError {
            let status = error == "invalid_client" ? 401 : 400
            return Self.http(status, "{\"error\": \"\(error)\"}")
        }
        let grant = request.parameter("grant_type") ?? ""
        switch grant {
        case "authorization_code":
            return self.respondCodeExchange(request)
        case "refresh_token":
            return self.respondRefresh(request)
        default:
            return Self.http(400, "{\"error\": \"unsupported_grant_type\"}")
        }
    }

    private func respondCodeExchange(_ request: OAuthTestRequest) -> String {
        // RFC 6749 §4.1.3: client authentication first.
        guard self.clientAuthenticated(request) else {
            return Self.http(401, "{\"error\": \"invalid_client\"}")
        }
        let code = request.parameter("code") ?? ""
        guard let scope = self.scenario.validCodes[code] else {
            return Self.http(400, "{\"error\": \"invalid_grant\"}")
        }
        // A code is single-use (RFC 6749 §4.1.2): the first exchange
        // consumes it; a replay is invalid_grant.
        self.scenario.validCodes.removeValue(forKey: code)
        // PKCE: the verifier must hash to the challenge the authorize
        // request carried (RFC 7636 §4.6). The server hashes like the
        // client does; the test seeds challenges with the same function.
        let verifier = request.parameter("code_verifier") ?? ""
        // The challenge this code's authorize request carried, if the
        // code came through /authorize; seeded codes fall back to the
        // scenario challenge.
        let challenge = self.scenario.codeChallenges[code] ?? self.scenario.codeChallenge
        if !self.pkceMatches(verifier: verifier, challenge: challenge) {
            return Self.http(400, "{\"error\": \"invalid_grant\"}")
        }
        let access = "at-\(code)-\(self.scenario.refreshCount)"
        let refresh = self.scenario.rotatesRefreshToken
            ? "r-\(code)-rotated"
            : "r1-original"
        self.scenario.validRefreshTokens.insert(refresh)
        self.scenario.acceptedAccessTokens.insert(access)
        return Self.http(200, Self.tokensJSON(access: access, refresh: refresh, expires: 3600))
    }

    private func respondRefresh(_ request: OAuthTestRequest) -> String {
        guard self.clientAuthenticated(request) else {
            return Self.http(401, "{\"error\": \"invalid_client\"}")
        }
        let token = request.parameter("refresh_token") ?? ""
        guard self.scenario.validRefreshTokens.contains(token) else {
            return Self.http(400, "{\"error\": \"invalid_grant\"}")
        }
        self.scenario.refreshCount += 1
        let access = "at-refresh-\(self.scenario.refreshCount)"
        self.scenario.acceptedAccessTokens.insert(access)
        if self.scenario.rotatesRefreshToken {
            let rotated = "r-rotated-\(self.scenario.refreshCount)"
            self.scenario.validRefreshTokens.remove(token)
            self.scenario.validRefreshTokens.insert(rotated)
            return Self.http(200, Self.tokensJSON(access: access, refresh: rotated, expires: 3600))
        }
        return Self.http(200, Self.tokensJSON(access: access, refresh: token, expires: 3600))
    }

    private func clientAuthenticated(_ request: OAuthTestRequest) -> Bool {
        // Two forms, per provider convention: HTTP Basic (RFC 6749 §2.3.1)
        // or the parameters in the body.
        if let authorization = request.authorization {
            guard authorization.hasPrefix("Basic ") else { return false }
            let decoded = Data(base64Encoded: String(authorization.dropFirst(6))) ?? Data()
            let pair = String(decoding: decoded, as: UTF8.self)
            return pair == "\(self.scenario.clientID):"
        }
        return request.parameter("client_id") == self.scenario.clientID
    }

    private func pkceMatches(verifier: String, challenge: String) -> Bool {
        // RFC 7636 §4.6: BASE64URL(SHA256(verifier)) == challenge. The
        // server does the real hash, never a stand-in comparison.
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let computed = Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return computed == challenge
    }

    /// Issues an authorization code the way a completed consent would
    /// (the test plays the browser): seed the code, carry its challenge.
    func issueCode(code: String) {
        self.update { scenario in
            scenario.validCodes[code] = "mail"
        }
    }

    static func tokensJSON(access: String, refresh: String, expires: Int) -> String {
        """
        {"access_token": "\(access)", "refresh_token": "\(refresh)", "expires_in": \(expires), "token_type": "Bearer"}
        """
    }

    static func http(_ status: Int, _ body: String) -> String {
        let reason = status == 200 ? "OK" : (status == 400 ? "Bad Request" : (status == 401 ? "Unauthorized" : "Error"))
        return "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: keep-alive\r\n\r\n\(body)"
    }
}
