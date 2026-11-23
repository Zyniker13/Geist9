// The OAuth token session's contract (DESIGN 4): refresh token stored
// through a CredentialStore, access token in memory, one refresh per
// IMAP rejection, invalid_grant goes to needs-sign-in, rotation replaces
// the stored token at once. The client seam is the in-process
// LocalHTTPClient; the CredentialStore is the in-memory backend the
// CredentialsTests also use.

import Credentials
import Foundation
import Testing

@testable import MailSync

@Suite("OAuthTokenSession")
struct OAuthTokenSessionTests {
    private func makeConfiguration(server: OAuthTestServer) -> OAuthTokenClient.Configuration {
        .init(
            tokenEndpoint: server.tokenEndpoint,
            clientID: "bristlecone-test-client",
            redirectURI: server.currentScenario().redirectURI,
            scope: "mail"
        )
    }

    private func makeSession(server: OAuthTestServer, store: any CredentialStore, email: String = "alice@example.com") -> OAuthTokenSession {
        OAuthTokenSession(
            configuration: makeConfiguration(server: server),
            store: store, email: email,
            http: LocalHTTPClient(server: server)
        )
    }

    @Test func storesAndReturnsTheRefreshToken() async throws {
        let server = OAuthTestServer()
        try server.start()
        defer { server.stop() }
        let store = InMemoryCredentialStore()
        let session = makeSession(server: server, store: store)
        try await session.storeRefreshToken("r1-original")
        let stored = await session.storedRefreshToken()
        #expect(stored == "r1-original")
        // Under its own key, distinct from a password credential.
        let raw = try await store.get("account:alice@example.com:oauth-refresh")
        #expect(String(decoding: raw, as: UTF8.self) == "r1-original")
    }

    @Test func noStoredTokenMeansNeedsSignIn() async throws {
        let server = OAuthTestServer()
        try server.start()
        defer { server.stop() }
        let session = makeSession(server: server, store: InMemoryCredentialStore())
        do {
            _ = try await session.accessTokenForSignIn()
            Issue.record("no refresh token stored; must ask for sign-in")
        } catch is OAuthTokenSession.NeedsSignIn {
            // expected
        }
    }

    @Test func refreshHandsOutAnAccessTokenAndRotatesTheStoredToken() async throws {
        let server = OAuthTestServer()
        try server.start()
        defer { server.stop() }
        let store = InMemoryCredentialStore()
        let session = makeSession(server: server, store: store)
        try await session.storeRefreshToken("r1-original")
        let access = try await session.accessTokenForSignIn()
        #expect(access.hasPrefix("at-refresh-"))
        // Rotation: the server rotated, the session stored the new token.
        let stored = await session.storedRefreshToken()
        #expect(stored == "r-rotated-1")
        // A second sign-in reuses the in-memory access token (no new
        // refresh call): the server's refresh count stays at 1.
        let again = try await session.accessTokenForSignIn()
        #expect(again == access)
        #expect(server.withScenario { $0.refreshCount } == 1)
    }

    @Test func rejectionRefreshesOnceThenDemandsSignIn() async throws {
        let server = OAuthTestServer()
        try server.start()
        defer { server.stop() }
        server.update { scenario in
            scenario.rotatesRefreshToken = false  // same refresh token stays valid
        }
        let session = makeSession(server: server, store: InMemoryCredentialStore())
        try await session.storeRefreshToken("r1-original")

        // First sign-in fails on the IMAP server (stale access token):
        // recovery refreshes once and returns a new token.
        let recovered = try await session.recoverFromRejection()
        #expect(recovered.hasPrefix("at-refresh-"))

        // A second rejection right after a recovery is not refreshed
        // again: one refresh per rejection, never a loop (DESIGN 4).
        // (No successful sign-in happened in between, so nothing re-arms.)
        do {
            _ = try await session.recoverFromRejection()
            Issue.record("second consecutive rejection must not refresh again")
        } catch is OAuthTokenSession.NeedsSignIn {
            // expected
        }
        #expect(server.withScenario { $0.refreshCount } == 1)
    }

    @Test func successfulSignInReArmsTheNextRejection() async throws {
        let server = OAuthTestServer()
        try server.start()
        defer { server.stop() }
        server.update { scenario in
            scenario.rotatesRefreshToken = false  // same refresh token stays valid
        }
        let session = makeSession(server: server, store: InMemoryCredentialStore())
        try await session.storeRefreshToken("r1-original")

        // Rejection one: one refresh.
        _ = try await session.recoverFromRejection()
        // The retry with the fresh token SUCCEEDS on the IMAP server:
        // the session is healthy again.
        await session.markSignInSucceeded()
        // Days later, a new rejection may refresh once again.
        let second = try await session.recoverFromRejection()
        #expect(second.hasPrefix("at-refresh-"))
        #expect(server.withScenario { $0.refreshCount } == 2)
    }

    @Test func invalidGrantForgetsTheTokenAndDemandsSignIn() async throws {
        let server = OAuthTestServer()
        try server.start()
        defer { server.stop() }
        let store = InMemoryCredentialStore()
        let session = makeSession(server: server, store: store)
        try await session.storeRefreshToken("r1-original")
        // The provider revoked the grant: the stored token stops working.
        server.update { scenario in
            scenario.validRefreshTokens = []
        }
        do {
            _ = try await session.accessTokenForSignIn()
            Issue.record("revoked grant must demand sign-in")
        } catch is OAuthTokenSession.NeedsSignIn {
            // expected
        }
        // The stale refresh token was removed from the store (a revoked
        // token must not sit in the Keychain, THREAT MODEL). Absence
        // reads as `.notFound`, which is the point.
        let stillThere = await session.storedRefreshToken()
        #expect(stillThere == nil)
        do {
            _ = try await store.get("account:alice@example.com:oauth-refresh")
            Issue.record("the revoked refresh token must be gone from the store")
        } catch CredentialError.notFound {
            // expected
        }
    }

    @Test func forgetTokensRemovesTheStoredToken() async throws {
        let server = OAuthTestServer()
        try server.start()
        defer { server.stop() }
        let session = makeSession(server: server, store: InMemoryCredentialStore())
        try await session.storeRefreshToken("r1-original")
        await session.forgetTokens()
        let gone = await session.storedRefreshToken()
        #expect(gone == nil)
        // And a later sign-in attempt asks for sign-in again.
        do {
            _ = try await session.accessTokenForSignIn()
            Issue.record("tokens were forgotten; must ask for sign-in")
        } catch is OAuthTokenSession.NeedsSignIn {
            // expected
        }
    }

    @Test func lockedStoreFoldsIntoNeedsSignInNotAWrongPassword() async throws {
        let server = OAuthTestServer()
        try server.start()
        defer { server.stop() }
        let session = makeSession(server: server, store: ReadRefusingCredentialStore())
        do {
            _ = try await session.accessTokenForSignIn()
            Issue.record("locked store cannot refresh; must ask for sign-in")
        } catch is OAuthTokenSession.NeedsSignIn {
            // expected — never a crash, never a false "wrong password".
        }
    }

    @Test func unavailableStoreFoldsIntoNeedsSignIn() async throws {
        let server = OAuthTestServer()
        try server.start()
        defer { server.stop() }
        // A store that can write but not read back: the realistic
        // degraded vault (item exists, read refused).
        let session = makeSession(server: server, store: ReadRefusingCredentialStore())
        try await session.storeRefreshToken("r1-original")
        do {
            _ = try await session.accessTokenForSignIn()
            Issue.record("unavailable store cannot refresh; must ask for sign-in")
        } catch is OAuthTokenSession.NeedsSignIn {
            // expected
        }
    }
}

/// A credential store whose reads are refused but writes land (the
/// degraded-vault shape: the item is there, the backend refuses to hand
/// it over — a locked 1Password vault after a partial unlock).
struct ReadRefusingCredentialStore: CredentialStore {
    func get(_ key: String) async throws -> Data { throw CredentialError.unavailable("test store refuses reads") }
    func put(_ key: String, secret: Data) async throws {}
    func delete(_ key: String) async throws {}
    func rotate(_ key: String, to newSecret: Data) async throws {}
}
