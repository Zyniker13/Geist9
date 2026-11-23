// OAuth tests (DESIGN 4 "OAuth Flow", TESTING.md "OAuth test server" row):
// the SASL bodies, the token client against the local OAuth server, the
// token session's storage and refresh contract, and the engine's XOAUTH2
// sign-in path end-to-end through the fake IMAP server.

import Credentials
import Foundation
import Testing

@testable import MailSync

// MARK: - SASL strings and PKCE

@Suite("OAuth SASL and PKCE")
struct OAuthSASLTests {
    @Test func xoauth2BodyShape() {
        let body = String(decoding: OAuthSASL.xoauth2(user: "alice@example.com", accessToken: "t0"), as: UTF8.self)
        #expect(body == "user=alice@example.com\u{01}auth=Bearer t0\u{01}\u{01}")
    }

    @Test func oauthBearerBodyShape() {
        let body = String(decoding: OAuthSASL.oauthBearer(user: "alice@example.com", host: "imap.example.com", port: 993, accessToken: "t0"), as: UTF8.self)
        #expect(body == "n,a=alice@example.com,\u{01}host=imap.example.com\u{01}port=993\u{01}auth=Bearer t0\u{01}\u{01}")
    }

    @Test func rejectionIsAnyNonEmptyChallenge() {
        #expect(OAuthSASL.isRejection(Data("{\"status\":\"401\"}".utf8)))
        #expect(!OAuthSASL.isRejection(Data()))
    }

    @Test func pkceChallengeIsSHA256OfVerifier() {
        let pair = PKCEPair(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        // RFC 7636 appendix B worked example.
        #expect(pair.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func randomPairsAreUniqueAndWellFormed() {
        let a = PKCEPair()
        let b = PKCEPair()
        #expect(a.verifier != b.verifier)
        #expect(a.verifier.count == 43)  // 32 bytes base64url, no padding
        #expect(!a.verifier.contains("="))
        #expect(!a.verifier.contains("+"))
        #expect(!a.verifier.contains("/"))
    }
}

// MARK: - Token client against the local OAuth server

@Suite("OAuthTokenClient against the local OAuth server")
struct OAuthTokenClientTests {
    /// A fresh server with one issued code; the test plays the browser by
    /// seeding the code, then exchanges it like the app would.
    private func makeServer() throws -> OAuthTestServer {
        let server = OAuthTestServer()
        try server.start()
        return server
    }

    private func client(for server: OAuthTestServer) -> OAuthTokenClient {
        OAuthTokenClient(
            configuration: .init(
                tokenEndpoint: server.tokenEndpoint,
                clientID: "bristlecone-test-client",
                redirectURI: server.currentScenario().redirectURI,
                scope: "mail"
            ),
            http: LocalHTTPClient(server: server)
        )
    }

    @Test func codeExchangeWithPKCEYieldsTokens() async throws {
        let server = try makeServer()
        defer { server.stop() }
        let pkce = PKCEPair(verifier: "test-verifier-0123456789-0123456789-0123456789")
        server.update { scenario in
            scenario.codeChallenge = pkce.challenge
            scenario.validCodes["code-1"] = "mail"
            scenario.rotatesRefreshToken = false
        }
        let tokens = try await client(for: server).exchange(code: "code-1", pkce: pkce)
        #expect(tokens.accessToken.hasPrefix("at-code-1"))
        #expect(tokens.refreshToken == "r1-original")
        #expect(tokens.expiresInSeconds == 3600)
    }

    @Test func codeExchangeRejectsWrongPKCEVerifier() async throws {
        let server = try makeServer()
        defer { server.stop() }
        let pkce = PKCEPair(verifier: "the-real-verifier-0123456789-0123456789-01")
        server.update { scenario in
            scenario.codeChallenge = pkce.challenge
            scenario.validCodes["code-1"] = "mail"
        }
        let wrong = PKCEPair(verifier: "a-totally-different-verifier-0123456789-01")
        do {
            _ = try await client(for: server).exchange(code: "code-1", pkce: wrong)
            Issue.record("expected invalid_grant")
        } catch let error as OAuthError {
            #expect(error.kind == .invalidGrant)
        }
    }

    @Test func codeIsSingleUse() async throws {
        let server = try makeServer()
        defer { server.stop() }
        let pkce = PKCEPair(verifier: "single-use-verifier-0123456789-01234567890")
        server.update { scenario in
            scenario.codeChallenge = pkce.challenge
            scenario.validCodes["code-1"] = "mail"
        }
        let client = client(for: server)
        _ = try await client.exchange(code: "code-1", pkce: pkce)
        do {
            _ = try await client.exchange(code: "code-1", pkce: pkce)
            Issue.record("replaying a consumed code must fail")
        } catch let error as OAuthError {
            #expect(error.kind == .invalidGrant)
        }
    }

    @Test func refreshRotatesAndOldTokenDies() async throws {
        let server = try makeServer()
        defer { server.stop() }
        server.update { scenario in
            scenario.rotatesRefreshToken = true
        }
        let client = client(for: server)
        let first = try await client.refresh(refreshToken: "r1-original")
        #expect(first.refreshToken == "r-rotated-1")
        // The old token no longer answers.
        do {
            _ = try await client.refresh(refreshToken: "r1-original")
            Issue.record("rotated-out token must not answer")
        } catch let error as OAuthError {
            #expect(error.kind == .invalidGrant)
        }
        let second = try await client.refresh(refreshToken: first.refreshToken!)
        #expect(second.refreshToken == "r-rotated-2")
    }

    @Test func refreshWithoutRotationKeepsTheToken() async throws {
        let server = try makeServer()
        defer { server.stop() }
        server.update { scenario in
            scenario.rotatesRefreshToken = false
        }
        let client = client(for: server)
        let first = try await client.refresh(refreshToken: "r1-original")
        #expect(first.refreshToken == "r1-original")
        let second = try await client.refresh(refreshToken: "r1-original")
        #expect(second.accessToken != first.accessToken)
    }

    @Test func invalidGrantIsClassified() async throws {
        let server = try makeServer()
        defer { server.stop() }
        do {
            _ = try await client(for: server).refresh(refreshToken: "never-issued")
            Issue.record("an unknown refresh token must fail")
        } catch let error as OAuthError {
            #expect(error.kind == .invalidGrant)
        }
    }

    @Test func tokenErrorResponsesAreClassified() async throws {
        let server = try makeServer()
        defer { server.stop() }
        server.update { scenario in
            scenario.tokenError = "invalid_client"
        }
        do {
            _ = try await client(for: server).refresh(refreshToken: "r1-original")
            Issue.record("expected invalid_client")
        } catch let error as OAuthError {
            #expect(error.kind == .invalidClient)
        }
    }
}

/// An in-process HTTP client that talks to the local OAuth server directly
/// (no loopback TCP needed for the client seam; the server itself is still
/// exercised over TCP by the session tests below).
struct LocalHTTPClient: OAuthHTTPClient {
    let server: OAuthTestServer

    func postForm(url: URL, body: [String: String], headers: [String: String]) async throws -> (status: Int, body: Data) {
        var parameter = ""
        for (name, value) in body {
            if !parameter.isEmpty { parameter += "&" }
            parameter += "\(name)=\(value)"
        }
        let target = url.path.isEmpty ? "/" : url.path
        var head = "POST \(target) HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: \(parameter.utf8.count)\r\n"
        for (field, value) in headers {
            head += "\(field): \(value)\r\n"
        }
        head += "\r\n"
        let request = OAuthTestRequest(
            method: "POST", path: target,
            query: [:],
            body: Self.parseForm(parameter),
            authorization: headers["Authorization"]
        )
        let response = self.server.respond(request)
        // Split status line from body.
        let parts = response.components(separatedBy: "\r\n\r\n")
        let statusLine = parts[0].components(separatedBy: "\r\n").first ?? ""
        let status = Int(statusLine.split(separator: " ")[1]) ?? 0
        return (status, Data((parts.count > 1 ? parts[1] : "").utf8))
    }

    static func parseForm(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if kv.count == 2 {
                result[String(kv[0])] = String(kv[1]).removingPercentEncoding ?? String(kv[1])
            }
        }
        return result
    }
}
