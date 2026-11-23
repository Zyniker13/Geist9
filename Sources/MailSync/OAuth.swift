// OAuth 2.0 for IMAP (DESIGN 4 "OAuth Flow"): SASL strings, PKCE, token
// client. Tested in Tests/MailSyncTests/OAuthTests.swift.

import Crypto
import Foundation

/// The SASL initial-response strings for IMAP OAuth (RFC 7628 XOAUTH2;
/// OAUTHBEARER carries the same body under its own scheme).
public enum OAuthSASL {
    /// `user=<user>\x01auth=Bearer <token>\x01\x01` — the XOAUTH2 body.
    public static func xoauth2(user: String, accessToken: String) -> Data {
        Data("user=\(user)\u{01}auth=Bearer \(accessToken)\u{01}\u{01}".utf8)
    }

    /// `n,a=<user>,\x01host=<host>\x01port=<port>\x01auth=Bearer <token>\x01\x01`
    /// — the OAUTHBEARER body (RFC 7628 §3.2.1).
    public static func oauthBearer(user: String, host: String, port: Int, accessToken: String) -> Data {
        Data("n,a=\(user),\u{01}host=\(host)\u{01}port=\(port)\u{01}auth=Bearer \(accessToken)\u{01}\u{01}".utf8)
    }

    /// Any non-empty server challenge after our initial response is the
    /// SASL failure report; an empty challenge means success. The text is
    /// used only for the retry decision, never shown as-is (DESIGN 4).
    public static func isRejection(_ data: Data) -> Bool {
        !data.isEmpty
    }
}

/// A PKCE verifier/challenge pair (RFC 7636, S256): 32 random bytes
/// base64url, and the SHA-256 challenge of the verifier.
public struct PKCEPair: Sendable, Equatable {
    public let verifier: String
    public let challenge: String

    public init() {
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        if status != errSecSuccess {
            fatalError("SecRandomCopyBytes failed: \(status)")
        }
        self.verifier = Self.base64URL(bytes)
        let digest = SHA256.hash(data: Data(self.verifier.utf8))
        self.challenge = Self.base64URL(Data(digest))
    }

    /// Deterministic initializer for tests: a fixed verifier string.
    public init(verifier: String) {
        self.verifier = verifier
        let digest = SHA256.hash(data: Data(verifier.utf8))
        self.challenge = Self.base64URL(Data(digest))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// The token response for a code exchange or a refresh (RFC 6749 §5.1,
/// §4.1.4). `refreshToken` is nil on a refresh that did not rotate.
public struct OAuthTokens: Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresInSeconds: Int?

    public init(accessToken: String, refreshToken: String?, expiresInSeconds: Int?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresInSeconds = expiresInSeconds
    }

    public init?(json: Data) {
        guard
            let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
            let access = object["access_token"] as? String
        else { return nil }
        self.accessToken = access
        self.refreshToken = object["refresh_token"] as? String
        self.expiresInSeconds = object["expires_in"] as? Int
    }
}

/// The OAuth endpoint error (RFC 6749 §5.2).
public enum OAuthErrorKind: Sendable, Equatable {
    /// The refresh token is no longer valid (revoked, expired, rotated out):
    /// the account goes to "needs sign-in" (DESIGN 4).
    case invalidGrant
    /// The client configuration is wrong (client ID/secret, redirect).
    case invalidClient
    /// Anything else; the raw code is carried for the log.
    case other(String)

    public init(code: String?) {
        switch code {
        case "invalid_grant": self = .invalidGrant
        case "invalid_client": self = .invalidClient
        case .some(let other): self = .other(other)
        case .none: self = .other("no error code")
        }
    }
}

public struct OAuthError: Error, Sendable, Equatable {
    public let kind: OAuthErrorKind
    public init(kind: OAuthErrorKind) { self.kind = kind }
}

/// The HTTP seam for token endpoints. Production uses `URLSession`; the
/// tests drive this seam directly against the local OAuth test server.
public protocol OAuthHTTPClient: Sendable {
    /// POSTs an `application/x-www-form-urlencoded` body; returns the raw
    /// body and the status code.
    func postForm(url: URL, body: [String: String], headers: [String: String]) async throws -> (status: Int, body: Data)
}

public struct URLSessionOAuthHTTPClient: OAuthHTTPClient {
    public init() {}

    public func postForm(url: URL, body: [String: String], headers: [String: String]) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        request.httpBody = Data(
            body.map { field, value in
                "\(Self.formEscape(field))=\(Self.formEscape(value))"
            }.joined(separator: "&").utf8
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        return (status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
    }

    static func formEscape(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

/// The token client: exchanges an authorization code and refreshes a token
/// (RFC 6749 §4.1.3, §6) with PKCE and the client authentication the
/// provider's config requires. Client secrets arrive from the build
/// environment, never from the repository (DESIGN 4).
public struct OAuthTokenClient: Sendable {
    public struct Configuration: Sendable, Equatable {
        /// The token endpoint (https for real providers; the local test
        /// server in tests).
        public var tokenEndpoint: URL
        public var clientID: String
        /// Only for providers requiring a client secret at the token
        /// endpoint (HTTP Basic, RFC 6749 §2.3.1).
        public var clientSecret: String?
        public var redirectURI: String
        public var scope: String

        public init(
            tokenEndpoint: URL, clientID: String, clientSecret: String? = nil,
            redirectURI: String, scope: String
        ) {
            self.tokenEndpoint = tokenEndpoint
            self.clientID = clientID
            self.clientSecret = clientSecret
            self.redirectURI = redirectURI
            self.scope = scope
        }
    }

    public let configuration: Configuration
    public let http: any OAuthHTTPClient

    public init(configuration: Configuration, http: any OAuthHTTPClient) {
        self.configuration = configuration
        self.http = http
    }

    /// Exchanges the authorization code the browser flow returned.
    public func exchange(code: String, pkce: PKCEPair) async throws -> OAuthTokens {
        var body: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": self.configuration.redirectURI,
            "client_id": self.configuration.clientID,
            "code_verifier": pkce.verifier,
        ]
        if let scope = Self.nonEmpty(self.configuration.scope) { body["scope"] = scope }
        return try await self.send(body)
    }

    /// Refreshes the access token. A rotated refresh token comes back in
    /// the response and MUST replace the stored one (DESIGN 4).
    public func refresh(refreshToken: String) async throws -> OAuthTokens {
        var body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": self.configuration.clientID,
        ]
        if let secret = self.configuration.clientSecret { body["client_secret"] = secret }
        if let scope = Self.nonEmpty(self.configuration.scope) { body["scope"] = scope }
        return try await self.send(body)
    }

    /// Revokes the token (RFC 7009) where the provider offers the endpoint.
    /// Best effort: a failed revocation never blocks removing the account.
    public func revoke(token: String, endpoint: URL?) async {
        guard let endpoint else { return }
        _ = try? await self.http.postForm(
            url: endpoint,
            body: ["token": token, "client_id": self.configuration.clientID],
            headers: [:]
        )
    }

    private func send(_ body: [String: String]) async throws -> OAuthTokens {
        var headers: [String: String] = [:]
        if let secret = self.configuration.clientSecret {
            let pair = Data("\(self.configuration.clientID):\(secret)".utf8).base64EncodedString()
            headers["Authorization"] = "Basic \(pair)"
        }
        let (status, data) = try await self.http.postForm(url: self.configuration.tokenEndpoint, body: body, headers: headers)
        if status == 200, let tokens = OAuthTokens(json: data) {
            return tokens
        }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            throw OAuthError(kind: OAuthErrorKind(code: object["error"] as? String))
        }
        throw OAuthError(kind: .other("HTTP \(status)"))
    }

    static func nonEmpty(_ value: String) -> String? {
        value.trimmingCharacters(in: .whitespaces).isEmpty ? nil : value
    }
}

/// The authorize URL the browser session opens (RFC 6749 §4.1.1 with PKCE
/// §4.3 and `state`). Built per attempt: fresh PKCE pair, fresh state.
public func makeAuthorizeURL(
    endpoint: URL, configuration: OAuthTokenClient.Configuration,
    pkce: PKCEPair, state: String
) -> URL {
    var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
    var query = components.queryItems ?? []
    let items: [(String, String)] = [
        ("response_type", "code"),
        ("client_id", configuration.clientID),
        ("redirect_uri", configuration.redirectURI),
        ("scope", configuration.scope),
        ("state", state),
        ("code_challenge", pkce.challenge),
        ("code_challenge_method", "S256"),
        // Offline access: the refresh token the rotation flow needs.
        ("access_type", "offline"),
        ("prompt", "consent"),
    ]
    for (name, value) in items where appendable(name: name, value: value) {
        query.append(URLQueryItem(name: name, value: value))
    }
    components.queryItems = query
    return components.url!
}

private func appendable(name: String, value: String) -> Bool {
    if name == "scope" || name == "access_type" || name == "prompt" {
        return OAuthTokenClient.nonEmpty(value) != nil
    }
    return !value.isEmpty
}
