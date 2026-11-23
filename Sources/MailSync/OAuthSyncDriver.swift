// The OAuth sync driver (DESIGN 4 "OAuth Flow"): the app-layer glue
// between the token session and the sync engine. The engine stays
// refresh-free (its sign-in maps a rejected XOAUTH2 token to
// `SyncEngineError.authenticationFailed` and nothing more); the driver
// owns the token lifecycle around it — obtain an access token, sign in,
// on a rejection refresh once and retry once, and only then declare the
// account in need of a human sign-in. Tested in
// Tests/MailSyncTests/OAuthSyncDriverTests.swift against the fake IMAP
// server and the local OAuth test server.

import ArchiveCore
import Credentials
import Foundation

/// Drives a sync (or a connection test) with OAuth token lifecycle around
/// the engine: at most one refresh-and-retry per call, per DESIGN 4.
public struct OAuthSyncDriver: Sendable {
    /// The session to obtain and recover tokens through.
    public let session: OAuthTokenSession
    /// Builds an engine for one attempt. Rebuilt per attempt so a fresh
    /// engine signs in with the new token; the closure captures whatever
    /// the call needs (profile, account, store, credentials).
    public let makeEngine: @Sendable () async throws -> IMAPSyncEngine
    /// The credentials identifier passed to the engine (the account's
    /// email; the engine uses it in the SASL body).
    public let credentials: String

    public init(
        session: OAuthTokenSession,
        credentials: String,
        makeEngine: @escaping @Sendable () async throws -> IMAPSyncEngine
    ) {
        self.session = session
        self.credentials = credentials
        self.makeEngine = makeEngine
    }

    /// Runs one full sync with the retry contract. Throws
    /// `OAuthTokenSession.NeedsSignIn` when the human must sign in again.
    public func sync(store: ArchiveStore) async throws {
        var token = try await self.session.accessTokenForSignIn()
        do {
            let engine = try await self.makeEngine()
            let progress = try await engine.sync(
                store: store, credentials: self.credentials, auth: .xoauth2(accessToken: token)
            )
            await self.session.markSignInSucceeded()
            _ = progress
        } catch let error as SyncEngineError {
            guard case .authenticationFailed = error else { throw error }
            // One refresh, one retry (DESIGN 4). A second rejection is
            // final: the account needs a human.
            token = try await self.session.recoverFromRejection()
            let engine = try await self.makeEngine()
            do {
                _ = try await engine.sync(
                    store: store, credentials: self.credentials, auth: .xoauth2(accessToken: token)
                )
                await self.session.markSignInSucceeded()
            } catch let retryError as SyncEngineError {
                guard case .authenticationFailed = retryError else { throw retryError }
                // The fresh token was also rejected: the grant itself is
                // dead, not the cached access token. Drop it so the next
                // sign-in attempt does not reuse it, and ask for a human.
                await self.session.forgetTokens()
                throw OAuthTokenSession.NeedsSignIn()
            }
        }
    }

    /// Runs the onboarding connection test under the same contract.
    /// Returns the folder list on success.
    @discardableResult
    public func testConnection() async throws -> [String] {
        var token = try await self.session.accessTokenForSignIn()
        do {
            let engine = try await self.makeEngine()
            let mailboxes = try await engine.testConnection(
                credentials: self.credentials, auth: .xoauth2(accessToken: token)
            )
            await self.session.markSignInSucceeded()
            return mailboxes
        } catch let error as SyncEngineError {
            guard case .authenticationFailed = error else { throw error }
            token = try await self.session.recoverFromRejection()
            let engine = try await self.makeEngine()
            do {
                let mailboxes = try await engine.testConnection(
                    credentials: self.credentials, auth: .xoauth2(accessToken: token)
                )
                await self.session.markSignInSucceeded()
                return mailboxes
            } catch let retryError as SyncEngineError {
                guard case .authenticationFailed = retryError else { throw retryError }
                await self.session.forgetTokens()
                throw OAuthTokenSession.NeedsSignIn()
            }
        }
    }
}
