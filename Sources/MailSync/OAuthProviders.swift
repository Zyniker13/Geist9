// The OAuth provider configurations (DESIGN 4 "OAuth Flow", PROVIDERS.md
// "Per-Provider Registration Work"): for each OAuth provider, the
// authorization and token endpoints, the requested scope, and whether a
// refresh token arrives at all. Client IDs are injected at build time
// from the build environment (never committed); an absent ID means the
// provider's OAuth entry point is off in this build and the app offers
// that provider's non-OAuth path. Tested in
// Tests/MailSyncTests/OAuthProvidersTests.swift (shape and endpoint
// correctness; the endpoints themselves are exercised end-to-end only
// against the local test server, never a live provider).

import Foundation

/// One provider's OAuth endpoints and scopes (RFC 8414-style metadata,
/// spelled out because mail providers rarely publish discovery).
public struct OAuthProviderConfig: Sendable, Equatable {
    /// Stable provider id, matching `ProviderProfile.id`.
    public var id: String
    /// The authorization endpoint (RFC 6749 §3.1).
    public var authorizeEndpoint: URL
    /// The token endpoint (RFC 6749 §3.2).
    public var tokenEndpoint: URL
    /// The revocation endpoint (RFC 7009 §2), when the provider offers one.
    public var revocationEndpoint: URL?
    /// The scope string sent with the authorize request.
    public var scope: String
    /// The environment variable the client ID is read from at build time.
    /// Empty value (or unset) disables this provider's OAuth entry point
    /// in the build; the app falls back to the profile's non-OAuth path.
    public var clientIDEnvironmentKey: String

    public init(
        id: String, authorizeEndpoint: URL, tokenEndpoint: URL,
        revocationEndpoint: URL? = nil, scope: String, clientIDEnvironmentKey: String
    ) {
        self.id = id
        self.authorizeEndpoint = authorizeEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.revocationEndpoint = revocationEndpoint
        self.scope = scope
        self.clientIDEnvironmentKey = clientIDEnvironmentKey
    }

    /// The client ID for this build, or nil when OAuth is off for the
    /// provider (no ID in the environment). Read once per call so a test
    /// or an app restart picks up a new value without restarting.
    public func clientID(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let value = environment[self.clientIDEnvironmentKey] ?? ""
        return value.trimmingCharacters(in: .whitespaces).isEmpty ? nil : value
    }
}

/// The OAuth providers, keyed by `ProviderProfile.id`.
public enum OAuthProviders {
    /// Microsoft (Outlook.com, Microsoft 365): OAuth is the only IMAP path
    /// for personal accounts (PROVIDERS row 4), so this is the one provider
    /// OAuth must exist for. Entra "public client" flow: PKCE, no secret,
    /// refresh tokens issued with `offline_access` (Microsoft rotates
    /// refresh tokens; the session writes the rotated one back, DESIGN 4).
    /// `IMAP.AccessAsUser.All` is the tenant-scoped IMAP scope; there is no
    /// read-only IMAP scope, which the privacy policy must explain.
    public static let microsoft = OAuthProviderConfig(
        id: "outlook",
        authorizeEndpoint: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!,
        tokenEndpoint: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!,
        revocationEndpoint: nil,
        scope: "https://outlook.office.com/IMAP.AccessAsUser.All offline_access",
        clientIDEnvironmentKey: "BRISTLECONE_MICROSOFT_CLIENT_ID"
    )

    /// Google (Gmail consumer, Google Workspace): desktop client type,
    /// loopback redirect (RFC 8252 §7), testing mode until verification
    /// (decision 0004 — built and tested, enabled only for a testing-mode
    /// client). The IMAP scope is the full-mailbox `mail.google.com`; the
    /// CASA Tier 2 assessment it triggers is deferred, reviewed May 2027.
    public static let google = OAuthProviderConfig(
        id: "gmail",
        authorizeEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
        tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!,
        revocationEndpoint: URL(string: "https://oauth2.googleapis.com/revoke")!,
        scope: "https://mail.google.com/",
        clientIDEnvironmentKey: "BRISTLECONE_GOOGLE_CLIENT_ID"
    )

    /// Yahoo Mail: OAuth only after Yahoo approves the Mail API access
    /// request (PROVIDERS row 6); until then app passwords cover the
    /// account. `mail-r` is the read-only scope.
    public static let yahoo = OAuthProviderConfig(
        id: "yahoo",
        authorizeEndpoint: URL(string: "https://api.login.yahoo.com/oauth2/request_auth")!,
        tokenEndpoint: URL(string: "https://api.login.yahoo.com/oauth2/get_token")!,
        revocationEndpoint: URL(string: "https://api.login.yahoo.com/oauth2/revoke")!,
        scope: "mail-r",
        clientIDEnvironmentKey: "BRISTLECONE_YAHOO_CLIENT_ID"
    )

    /// AOL Mail: Yahoo infrastructure, same endpoints and scope (PROVIDERS
    /// row 9); OAuth after the same approval, app passwords until then.
    public static let aol = OAuthProviderConfig(
        id: "aol",
        authorizeEndpoint: URL(string: "https://api.login.aol.com/oauth2/request_auth")!,
        tokenEndpoint: URL(string: "https://api.login.aol.com/oauth2/get_token")!,
        revocationEndpoint: URL(string: "https://api.login.aol.com/oauth2/revoke")!,
        scope: "mail-r",
        clientIDEnvironmentKey: "BRISTLECONE_AOL_CLIENT_ID"
    )

    /// Yandex Mail: optional OAuth (XOAUTH2) with a registered app;
    /// the app password is the dependable path (sanctions and payment
    /// issues can block registering a developer app, PROVIDERS row 11).
    public static let yandex = OAuthProviderConfig(
        id: "yandex",
        authorizeEndpoint: URL(string: "https://oauth.yandex.ru/authorize")!,
        tokenEndpoint: URL(string: "https://oauth.yandex.ru/token")!,
        revocationEndpoint: nil,
        scope: "mail:imap_login", // read-only IMAP login token
        clientIDEnvironmentKey: "BRISTLECONE_YANDEX_CLIENT_ID"
    )

    /// Zoho Mail: optional OAuth with a Zoho API client; data-center
    /// region decides the account server, but the OAuth endpoints are
    /// global (they redirect per region).
    public static let zoho = OAuthProviderConfig(
        id: "zoho",
        authorizeEndpoint: URL(string: "https://accounts.zoho.com/oauth/v2/auth")!,
        tokenEndpoint: URL(string: "https://accounts.zoho.com/oauth/v2/token")!,
        revocationEndpoint: URL(string: "https://accounts.zoho.com/oauth/v2/token/revoke")!,
        scope: "ZohoMail.messages.READ", // read-only
        clientIDEnvironmentKey: "BRISTLECONE_ZOHO_CLIENT_ID"
    )

    /// Fastmail: IMAP app passwords are the M4 path; OAuth for registered
    /// apps arrives with the JMAP work (M6) where the session scope also
    /// covers JMAP. Listed here so the provider database has one shape.
    public static let fastmail = OAuthProviderConfig(
        id: "fastmail",
        authorizeEndpoint: URL(string: "https://api.fastmail.com/oauth/authorize")!,
        tokenEndpoint: URL(string: "https://api.fastmail.com/oauth/token")!,
        revocationEndpoint: nil,
        scope: "imap mail.jmap.read", // read-only IMAP + JMAP session read
        clientIDEnvironmentKey: "BRISTLECONE_FASTMAIL_CLIENT_ID"
    )

    /// Every OAuth config, in PROVIDERS.md row order.
    public static let all: [OAuthProviderConfig] = [
        Self.microsoft, Self.google, Self.yahoo, Self.aol, Self.yandex, Self.zoho, Self.fastmail,
    ]

    /// The config for a provider id, or nil when the provider has no OAuth
    /// path (M4-only providers).
    public static func config(for id: String) -> OAuthProviderConfig? {
        self.all.first { $0.id == id }
    }
}
