// The engine's XOAUTH2 sign-in path end-to-end (DESIGN 4): against the
// in-repo fake IMAP server acting as an OAuth-only IMAP endpoint — the
// Gmail/Yahoo wire behavior — through sync and the onboarding connection
// test, including the SASL failure-report handshake and the read-only
// command audit.

import ArchiveCore
import XCTest
@testable import MailSync

final class OAuthEngineTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("geist9-oauth-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
    }

    // MARK: - Fixtures

    private let account = AccountIdentity(
        email: "alice@example.com", displayName: "Alice", providerKind: "imap"
    )

    private func message(_ subject: String) -> Data {
        let head = "From: Bob <bob@example.org>\r\n"
            + "To: Alice <alice@example.com>\r\n"
            + "Subject: \(subject)\r\n"
            + "Date: Mon, 20 Jan 2026 10:00:00 +0000\r\n"
            + "Message-ID: <\(subject)@example.org>\r\n"
        return Data((head + "\r\n" + "hello\r\n").utf8)
    }

    private func makeStore() throws -> ArchiveStore {
        try ArchiveStore.create(at: tempDir.appendingPathComponent("Test.emailarchive"), appVersion: "0.1.0")
    }

    private func profile(port: UInt16) -> ProviderProfile {
        ProviderProfile(
            id: "oauth-test",
            displayName: "OAuth Test",
            host: "127.0.0.1",
            tls: .starttls(port: Int(port)), // plain loopback server
            credential: .oauthToken,
            domains: []
        )
    }

    /// The read-only command set; AUTHENTICATE joins LOGIN in the audit.
    private static let readOnlyCommands: Set<String> = [
        "LOGIN", "AUTHENTICATE", "ID", "LIST", "STATUS", "SELECT", "UID FETCH", "UID SEARCH", "LOGOUT", "NOOP",
    ]

    private func assertReadOnly(_ server: FakeIMAPServer) {
        for command in server.seenCommands {
            XCTAssertTrue(
                Self.readOnlyCommands.contains(command),
                "engine sent a mutating or unexpected command: \(command)"
            )
        }
    }

    // MARK: - Sign-in paths

    func testSyncWithAValidAccessTokenAuthenticatesAndStores() async throws {
        let scenario = FakeServerScenario(
            folders: [
                FakeFolder(name: "INBOX", messages: [
                    FakeMessage(uid: 1, data: message("oauth-alpha")),
                ], uidValidity: 7),
            ],
            acceptedAccessTokens: ["at-valid"],
            xoauth2User: "alice@example.com"
        )
        let server = FakeIMAPServer(scenario: scenario)
        try server.start()
        defer { server.stop() }

        let engine = IMAPSyncEngine(profile: profile(port: server.port), account: account)
        let store = try makeStore()
        let progress = try await engine.sync(
            store: store, credentials: "alice@example.com", auth: .xoauth2(accessToken: "at-valid")
        )
        XCTAssertEqual(progress.foldersListed, 1)
        let subjects = try await store.db.read { db in
            try String.fetchAll(db, sql: "SELECT subject FROM message")
        }
        XCTAssertEqual(subjects, ["oauth-alpha"])
        self.assertReadOnly(server)
        // LOGIN must not appear: the OAuth-only server refuses it, and the
        // engine must have gone straight to AUTHENTICATE.
        XCTAssertFalse(server.seenCommands.contains("LOGIN"))
        XCTAssertTrue(server.seenCommands.contains("AUTHENTICATE"))
    }

    func testConnectionTestWithAValidTokenListsFolders() async throws {
        let scenario = FakeServerScenario(
            folders: [
                FakeFolder(name: "INBOX", messages: [], uidValidity: 7),
                FakeFolder(name: "Work", messages: [], uidValidity: 7),
            ],
            acceptedAccessTokens: ["at-valid"],
            xoauth2User: "alice@example.com"
        )
        let server = FakeIMAPServer(scenario: scenario)
        try server.start()
        defer { server.stop() }

        let engine = IMAPSyncEngine(profile: profile(port: server.port), account: account)
        let mailboxes = try await engine.testConnection(
            credentials: "alice@example.com", auth: .xoauth2(accessToken: "at-valid")
        )
        XCTAssertEqual(Set(mailboxes), ["INBOX", "Work"])
        self.assertReadOnly(server)
        XCTAssertFalse(server.seenCommands.contains("LOGIN"))
    }

    func testRejectedTokenSurfacesAsAuthenticationFailed() async throws {
        let scenario = FakeServerScenario(
            folders: [FakeFolder(name: "INBOX", messages: [], uidValidity: 7)],
            acceptedAccessTokens: ["at-valid"],
            xoauth2User: "alice@example.com"
        )
        let server = FakeIMAPServer(scenario: scenario)
        try server.start()
        defer { server.stop() }

        let engine = IMAPSyncEngine(profile: profile(port: server.port), account: account)
        do {
            _ = try await engine.testConnection(
                credentials: "alice@example.com", auth: .xoauth2(accessToken: "at-expired")
            )
            XCTFail("a rejected token must fail the connection test")
        } catch let error as SyncEngineError {
            guard case .authenticationFailed = error else {
                XCTFail("expected authenticationFailed, got \(error)")
                return
            }
        }
        self.assertReadOnly(server)
    }

    func testSyncWithARejectedTokenThrowsAuthenticationFailed() async throws {
        let scenario = FakeServerScenario(
            folders: [FakeFolder(name: "INBOX", messages: [], uidValidity: 7)],
            acceptedAccessTokens: ["at-valid"],
            xoauth2User: "alice@example.com"
        )
        let server = FakeIMAPServer(scenario: scenario)
        try server.start()
        defer { server.stop() }

        let engine = IMAPSyncEngine(profile: profile(port: server.port), account: account)
        let store = try makeStore()
        do {
            _ = try await engine.sync(
                store: store, credentials: "alice@example.com", auth: .xoauth2(accessToken: "at-revoked")
            )
            XCTFail("a revoked token must not sync")
        } catch let error as SyncEngineError {
            guard case .authenticationFailed = error else {
                XCTFail("expected authenticationFailed, got \(error)")
                return
            }
        }
        // Nothing was stored: the pass never got past sign-in.
        let count = try await store.db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message") ?? 0
        }
        XCTAssertEqual(count, 0)
    }

    func testPasswordPathUnchangedOnAnOAuthCapableServer() async throws {
        // A server that accepts BOTH passwords and tokens (the common
        // case while providers transition): the password path must keep
        // working through the same shared sign-in helper.
        let scenario = FakeServerScenario(
            folders: [FakeFolder(name: "INBOX", messages: [], uidValidity: 7)]
        )
        let server = FakeIMAPServer(scenario: scenario)
        try server.start()
        defer { server.stop() }

        let engine = IMAPSyncEngine(profile: profile(port: server.port), account: account)
        let mailboxes = try await engine.testConnection(
            credentials: "alice@example.com", auth: .password("secret")
        )
        XCTAssertEqual(mailboxes, ["INBOX"])
        XCTAssertTrue(server.seenCommands.contains("LOGIN"))
        XCTAssertFalse(server.seenCommands.contains("AUTHENTICATE"))
    }
}
