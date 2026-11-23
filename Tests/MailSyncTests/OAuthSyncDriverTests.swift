// The OAuth sync driver's contract (DESIGN 4): the engine reports a
// rejected token as authenticationFailed, the driver refreshes once
// through the token session and retries once; a second rejection (or an
// invalid_grant refresh) is needs-sign-in, and the stale in-memory token
// is dropped. Wired end-to-end: the fake IMAP server (OAuth-only) plus
// the local OAuth test server, the in-memory credential store.

import ArchiveCore
import Credentials
import Foundation
import Testing

@testable import MailSync

@Suite("OAuthSyncDriver")
struct OAuthSyncDriverTests {
    private let account = AccountIdentity(
        email: "alice@example.com", displayName: "Alice", providerKind: "imap"
    )

    // MARK: - Fixtures

    private func message(_ subject: String) -> Data {
        let head = "From: Bob <bob@example.org>\r\n"
            + "To: Alice <alice@example.com>\r\n"
            + "Subject: \(subject)\r\n"
            + "Date: Mon, 20 Jan 2026 10:00:00 +0000\r\n"
            + "Message-ID: <\(subject)@example.org>\r\n"
        return Data((head + "\r\n" + "hello\r\n").utf8)
    }

    private var tempDir: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("geist9-driver-tests-\(UUID().uuidString)")
    }

    private func profile(port: UInt16) -> ProviderProfile {
        Self.profile(port: port)
    }

    private static func profile(port: UInt16) -> ProviderProfile {
        ProviderProfile(
            id: "oauth-driver-test",
            displayName: "OAuth Driver Test",
            host: "127.0.0.1",
            tls: .starttls(port: Int(port)), // plain loopback server
            credential: .oauthToken,
            domains: []
        )
    }

    /// A driver wired to the two fakes: the fake IMAP server accepts the
    /// given access tokens; the local OAuth test server refreshes any
    /// stored token. `accepted` is shared mutable so a test can flip the
    /// server from rejecting to accepting mid-flight (the "token was
    /// rotated in" story).
    private func makeDriver(
        server: FakeIMAPServer,
        oauth: OAuthTestServer,
        store: InMemoryCredentialStore,
        accepted: Set<String>,
        tempDir: URL,
        email: String = "alice@example.com"
    ) throws -> (OAuthSyncDriver, ArchiveStore) {
        let session = OAuthTokenSession(
            configuration: .init(
                tokenEndpoint: oauth.tokenEndpoint,
                clientID: "bristlecone-test-client",
                redirectURI: "http://127.0.0.1/callback",
                scope: "mail"
            ),
            store: store,
            email: email,
            http: LocalHTTPClient(server: oauth)
        )
        let archive = try ArchiveStore.create(at: tempDir.appendingPathComponent("Test.emailarchive"), appVersion: "0.1.0")
        let port = server.port
        let credentials = email
        let driver = OAuthSyncDriver(
            session: session,
            credentials: credentials,
            makeEngine: { IMAPSyncEngine(profile: Self.profile(port: port), account: Self.account(email: email)) }
        )
        return (driver, archive)
    }
    private static func account(email: String) -> AccountIdentity {
        AccountIdentity(email: email, displayName: "Alice", providerKind: "imap")
    }

    // MARK: - Tests

    @Test func expiredTokenRefreshesOnceAndTheRetrySyncs() async throws {
        // The IMAP server rejects the stale in-memory token but accepts
        // the one the refresh hands out; the driver must recover without
        // the app seeing anything but a finished sync.
        let accepted = TokenBox(initial: ["at-stale"])
        let server = FakeIMAPServer(
            scenario: FakeServerScenario(
                folders: [FakeFolder(name: "INBOX", messages: [FakeMessage(uid: 1, data: self.message("driver-alpha"))], uidValidity: 7)],
                acceptedAccessTokens: accepted.current,
                xoauth2User: "alice@example.com"
            )
        )
        try server.start()
        defer { server.stop() }
        let oauth = OAuthTestServer()
        try oauth.start()
        defer { oauth.stop() }
        let store = InMemoryCredentialStore()
        let work = self.tempDir
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        var (driver, archive) = try self.makeDriver(
            server: server, oauth: oauth, store: store, accepted: accepted.current, tempDir: work
        )
        // Seed the session's state the way a completed sign-in left it:
        // the in-memory token is the now-stale one, the refresh token is
        // stored.
        try await store.put(OAuthTokenSession.refreshKey(email: "alice@example.com"), secret: Data("r1-original".utf8))
        _ = try await driver.session.accessTokenForSignIn()
        // The IMAP server now accepts only the refreshed token.
        accepted.rotate(to: ["at-refresh-1"])
        server.updateScenario { scenario in
            scenario.acceptedAccessTokens = accepted.current
        }
        try await driver.sync(store: archive)
        // The refresh happened exactly once, and the mail is stored.
        #expect(oauth.withScenario { $0.refreshCount } == 1)
        let subjects = try await archive.db.read { db in
            try String.fetchAll(db, sql: "SELECT subject FROM message")
        }
        #expect(subjects == ["driver-alpha"])
        _ = driver // silence unused-warning under some toolchains
    }

    @Test func revokedGrantEndsInNeedsSignInAndDropsTheToken() async throws {
        // The refresh token is itself dead (the person revoked access at
        // the provider): the refresh comes back invalid_grant, the stored
        // token is dropped, and the app must ask for a sign-in.
        let server = FakeIMAPServer(
            scenario: FakeServerScenario(
                folders: [FakeFolder(name: "INBOX", messages: [], uidValidity: 7)],
                acceptedAccessTokens: ["at-anything"],
                xoauth2User: "alice@example.com"
            )
        )
        try server.start()
        defer { server.stop() }
        let oauth = OAuthTestServer()
        try oauth.start()
        defer { oauth.stop() }
        // The grant is revoked: the stored refresh token is not one the
        // provider still honors, so the refresh answers invalid_grant.
        let store = InMemoryCredentialStore()
        let work = self.tempDir
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let (driver, archive) = try self.makeDriver(
            server: server, oauth: oauth, store: store, accepted: ["at-anything"], tempDir: work
        )
        // The app holds a stored refresh token whose grant is revoked.
        try await store.put(OAuthTokenSession.refreshKey(email: "alice@example.com"), secret: Data("r-dead".utf8))
        do {
            try await driver.sync(store: archive)
            Issue.record("a revoked grant must not sync")
        } catch is OAuthTokenSession.NeedsSignIn {
            // expected: the refresh already failed before any sign-in
        }
        // The dead refresh token was removed from the store.
        let stored = await driver.session.storedRefreshToken()
        #expect(stored == nil)
        // And the archive was never written to.
        let count = try await archive.db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message") ?? 0
        }
        #expect(count == 0)
    }

    @Test func secondRejectionAfterRefreshEndsInNeedsSignIn() async throws {
        // The IMAP server rejects every token it is offered: the driver
        // refreshes once, retries, is rejected again, and reports
        // needs-sign-in. Exactly one refresh must have happened.
        let server = FakeIMAPServer(
            scenario: FakeServerScenario(
                folders: [FakeFolder(name: "INBOX", messages: [], uidValidity: 7)],
                acceptedAccessTokens: [], // rejects everything
                xoauth2User: "alice@example.com"
            )
        )
        try server.start()
        defer { server.stop() }
        let oauth = OAuthTestServer()
        try oauth.start()
        defer { oauth.stop() }
        let store = InMemoryCredentialStore()
        let work = self.tempDir
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let (driver, archive) = try self.makeDriver(
            server: server, oauth: oauth, store: store, accepted: [], tempDir: work
        )
        try await store.put(OAuthTokenSession.refreshKey(email: "alice@example.com"), secret: Data("r1-original".utf8))
        do {
            try await driver.sync(store: archive)
            Issue.record("a server that rejects every token must end in needs-sign-in")
        } catch is OAuthTokenSession.NeedsSignIn {
            // expected
        }
        // The seeding refresh (no cached token yet) plus the one
        // recovery refresh: two total, never a loop.
        #expect(oauth.withScenario { $0.refreshCount } == 2)
        let count = try await archive.db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message") ?? 0
        }
        #expect(count == 0)
    }

    @Test func connectionTestFollowsTheSameContract() async throws {
        // The onboarding connection test refreshes once on a rejection,
        // then succeeds.
        let accepted = TokenBox(initial: ["at-stale"])
        let server = FakeIMAPServer(
            scenario: FakeServerScenario(
                folders: [
                    FakeFolder(name: "INBOX", messages: [], uidValidity: 7),
                    FakeFolder(name: "Work", messages: [], uidValidity: 7),
                ],
                acceptedAccessTokens: accepted.current,
                xoauth2User: "alice@example.com"
            )
        )
        try server.start()
        defer { server.stop() }
        let oauth = OAuthTestServer()
        try oauth.start()
        defer { oauth.stop() }
        let store = InMemoryCredentialStore()
        let work = self.tempDir
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let (driver, _) = try self.makeDriver(
            server: server, oauth: oauth, store: store, accepted: accepted.current, tempDir: work
        )
        try await store.put(OAuthTokenSession.refreshKey(email: "alice@example.com"), secret: Data("r1-original".utf8))
        _ = try await driver.session.accessTokenForSignIn()
        accepted.rotate(to: ["at-refresh-1"])
        server.updateScenario { scenario in
            scenario.acceptedAccessTokens = accepted.current
        }
        let mailboxes = try await driver.testConnection()
        #expect(Set(mailboxes) == ["INBOX", "Work"])
        #expect(oauth.withScenario { $0.refreshCount } == 1)
    }

    @Test func connectionTestSecondRejectionEndsInNeedsSignIn() async throws {
        let server = FakeIMAPServer(
            scenario: FakeServerScenario(
                folders: [FakeFolder(name: "INBOX", messages: [], uidValidity: 7)],
                acceptedAccessTokens: [],
                xoauth2User: "alice@example.com"
            )
        )
        try server.start()
        defer { server.stop() }
        let oauth = OAuthTestServer()
        try oauth.start()
        defer { oauth.stop() }
        let store = InMemoryCredentialStore()
        let work = self.tempDir
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let (driver, _) = try self.makeDriver(
            server: server, oauth: oauth, store: store, accepted: [], tempDir: work
        )
        try await store.put(OAuthTokenSession.refreshKey(email: "alice@example.com"), secret: Data("r1-original".utf8))
        do {
            _ = try await driver.testConnection()
            Issue.record("a server that rejects every token must end in needs-sign-in")
        } catch is OAuthTokenSession.NeedsSignIn {
            // expected
        }
        // The seeding refresh plus the one recovery refresh: two total,
        // never a loop.
        #expect(oauth.withScenario { $0.refreshCount } == 2)
    }
}

/// Shared mutable token sets: a test flips which access tokens the fake
/// IMAP server accepts between the seeding step and the drive under
/// test. Lock-guarded because the engine's sign-in runs on another task.
final class TokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: Set<String>
    init(initial: Set<String>) {
        self.tokens = initial
    }
    /// The tokens currently accepted.
    var current: Set<String> {
        self.lock.withLock { self.tokens }
    }
    /// Swaps the accepted set (the "fresh token rotated in" step).
    func rotate(to tokens: Set<String>) {
        self.lock.withLock { self.tokens = tokens }
    }
}
