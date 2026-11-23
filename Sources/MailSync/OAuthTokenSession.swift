// The OAuth token session (DESIGN 4): one account's live token state.
// Access token in memory only; the refresh token stored through the
// CredentialStore under the account key; exactly one refresh-and-retry on
// an IMAP authentication rejection, then the account goes to
// "needs sign-in". Tested in Tests/MailSyncTests/OAuthSessionTests.swift.

import Credentials
import Foundation

/// One account's OAuth token lifecycle, against one provider's
/// configuration (DESIGN 4 "OAuth Flow").
///
/// Storage contract:
/// - the access token lives in memory for this session only;
/// - the refresh token is stored under `account:<email>:oauth-refresh`
///   through a `CredentialStore` (Keychain or 1Password backend);
/// - a rotated refresh token replaces the stored one at once — the old
///   one is assumed invalid after rotation (RFC 6749 §10.4 recommends
///   treating a rotation as invalidating the predecessor).
///
/// Refresh contract: on an IMAP `authenticationFailed` the session
/// refreshes once and the caller may retry; a second rejection (or an
/// `invalid_grant` from the token endpoint) raises `needsSignIn` and the
/// app marks the account. The engine never sees this machinery.
public actor OAuthTokenSession {
    /// Where a refresh token is stored, per account.
    public static func refreshKey(email: String) -> String { "account:\(email):oauth-refresh" }

    public struct NeedsSignIn: Error, Equatable, Sendable {}

    public let configuration: OAuthTokenClient.Configuration
    public let store: any CredentialStore
    public let email: String
    public let http: any OAuthHTTPClient

    /// Memory-only access token; nil before the first exchange/refresh.
    private var accessToken: String?
    /// Set once the refresh path has been tried this session since the
    /// last successful token; one refresh per rejection, never a loop.
    private var refreshedThisSession = false

    public init(
        configuration: OAuthTokenClient.Configuration,
        store: any CredentialStore,
        email: String,
        http: any OAuthHTTPClient
    ) {
        self.configuration = configuration
        self.store = store
        self.email = email
        self.http = http
    }

    private var client: OAuthTokenClient {
        OAuthTokenClient(configuration: self.configuration, http: self.http)
    }

    /// Stores the refresh token from a fresh sign-in (the browser flow
    /// finished and the code was exchanged elsewhere, or a test seeds a
    /// token). The old stored token, if any, is replaced.
    public func storeRefreshToken(_ token: String) async throws {
        try await self.store.put(Self.refreshKey(email: self.email), secret: Data(token.utf8))
    }

    /// The stored refresh token, if any. Reading must not fail hard on a
    /// locked backend: an unavailable store means "cannot refresh", which
    /// folds into the same needs-sign-in path, never a wrong-password
    /// story.
    public func storedRefreshToken() async -> String? {
        do {
            let data = try await self.store.get(Self.refreshKey(email: self.email))
            return String(decoding: data, as: UTF8.self)
        } catch {
            return nil
        }
    }

    /// An access token to sign in with: the in-memory one if it is still
    /// plausible, otherwise a fresh one from the stored refresh token.
    /// Throws `NeedsSignIn` when there is no stored refresh token (first
    /// run, or the person revoked access and the app removed it) or the
    /// refresh was already spent this session.
    public func accessTokenForSignIn(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let access = self.accessToken {
            return access
        }
        return try await self.refreshNow()
    }

    /// The engine reported the server rejected the sign-in. Refresh once;
    /// hand back a new access token, or declare the account needs a human
    /// sign-in. Idempotent per rejection: a second call without an
    /// intervening successful sign-in raises `NeedsSignIn` immediately (no
    /// refresh loop — DESIGN 4).
    public func recoverFromRejection() async throws -> String {
        if self.refreshedThisSession {
            throw NeedsSignIn()
        }
        // Mark first: whatever happens below, this rejection cycle has had
        // its one refresh. A failed refresh must not unlock another one.
        self.refreshedThisSession = true
        return try await self.refreshNow()
    }

    /// Marks the session healthy after a successful IMAP sign-in, so a
    /// later rejection (days later) may refresh once again.
    public func markSignInSucceeded() {
        self.refreshedThisSession = false
    }

    /// Removes the stored refresh token: the person signed out, or the
    /// provider revoked the grant (`invalid_grant`). The Keychain entry
    /// must not outlive the grant it represents (THREAT MODEL: tokens are
    /// credentials).
    public func forgetTokens() async {
        try? await self.store.delete(Self.refreshKey(email: self.email))
        self.accessToken = nil
        self.refreshedThisSession = false
    }

    private func refreshNow() async throws -> String {
        guard let stored = await self.storedRefreshToken() else {
            throw NeedsSignIn()
        }
        let client = self.client
        let tokens: OAuthTokens
        do {
            tokens = try await client.refresh(refreshToken: stored)
        } catch let error as OAuthError where error.kind == .invalidGrant {
            // The grant is gone (revoked, expired, rotated out): no point
            // keeping the stale refresh token around. Needs a human.
            await self.forgetTokens()
            throw NeedsSignIn()
        }
        self.accessToken = tokens.accessToken
        // Rotation (RFC 6749 §10.4): a new refresh token replaces the
        // stored one at once; keeping both invites replay of the old.
        if let rotated = tokens.refreshToken, rotated != stored {
            try await self.store.put(Self.refreshKey(email: self.email), secret: Data(rotated.utf8))
        }
        return tokens.accessToken
    }
}
