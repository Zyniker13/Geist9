import XCTest
@testable import MailSync
@testable import Credentials
import ArchiveCore

/// The onboarding controller: discovery → setup steps → connection test →
/// stored credential + account row. Pure logic with injected seams (the
/// SwiftUI sheet only renders it); every seam is faked here. Nothing touches
/// a real account or the Keychain — the store is the in-memory one, and the
/// connection test runs against the in-process fake server.
final class OnboardingTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("geist9-onboard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
    }

    private let account = AccountIdentity(
        email: "alice@example.com", displayName: "Alice", providerKind: "imap"
    )

    private static func knownProvider() -> ProviderProfile {
        ProviderProfile(
            id: "example-mail",
            displayName: "Example Mail",
            host: "imap.example-mail.test",
            tls: .implicit(port: 993),
            credential: .appPassword,
            setupSteps: ["Open the security page.", "Create an app password."],
            helpURL: URL(string: "https://example-mail.test/help"),
            domains: ["example-mail.test"]
        )
    }

    private func makeStore() throws -> ArchiveStore {
        try ArchiveStore.create(
            at: tempDir.appendingPathComponent("Test.emailarchive"), appVersion: "0.1.0"
        )
    }

    // MARK: - Discovery

    func testResolveUsesTheInjectedChainForAKnownDomain() {
        let controller = OnboardingController(resolver: { _ in .provider(Self.knownProvider()) })
        let resolved = controller.resolve(address: "Alice@Example-Mail.test")
        guard case .provider(let profile) = resolved else {
            return XCTFail("expected the provider candidate, got \(resolved)")
        }
        XCTAssertEqual(profile.id, "example-mail")
        XCTAssertEqual(profile.setupSteps.count, 2)
        XCTAssertNotNil(profile.helpURL)
    }

    func testResolveReportsManualForAnUnknownDomain() {
        let controller = OnboardingController(resolver: { _ in .manual })
        XCTAssertEqual(controller.resolve(address: "alice@nowhere.example"), .manual)
    }

    func testManualProfileIsEditableAndDistinctFromBundledProviders() {
        let profile = OnboardingController.manualProfile(host: "imap.manual.test")
        XCTAssertEqual(profile.host, "imap.manual.test")
        XCTAssertEqual(profile.id, "manual")
    }

    // MARK: - Connection test through the controller

    func testConnectionTestReturnsFolderCountAndClearsErrors() async throws {
        let scenario = FakeServerScenario(folders: [
            FakeFolder(name: "INBOX", messages: [], uidValidity: 1),
            FakeFolder(name: "Archive/2025", messages: [], uidValidity: 1),
        ])
        let server = FakeIMAPServer(scenario: scenario)
        try server.start()
        defer { server.stop() }

        let engine = IMAPSyncEngine(
            profile: self.profile(host: "127.0.0.1", port: Int(server.port)),
            account: account
        )
        let controller = OnboardingController(resolver: { _ in .manual })
        let outcome = await controller.testConnection(
            engine: engine, user: "alice@example.com", password: "secret"
        )
        guard case .connected(let folders) = outcome else {
            return XCTFail("expected connected, got \(outcome)")
        }
        XCTAssertTrue(folders.contains("INBOX"))
        XCTAssertTrue(folders.contains("Archive/2025"))
    }

    func testConnectionTestSurfacesWrongPasswordAsFriendlyErrorWithoutTheSecret() async throws {
        let scenario = FakeServerScenario(folders: [
            FakeFolder(name: "INBOX", messages: [], uidValidity: 1),
        ])
        let server = FakeIMAPServer(scenario: scenario)
        try server.start()
        defer { server.stop() }

        let engine = IMAPSyncEngine(
            profile: self.profile(host: "127.0.0.1", port: Int(server.port)),
            account: account
        )
        let controller = OnboardingController(resolver: { _ in .manual })
        let outcome = await controller.testConnection(
            engine: engine, user: "alice@example.com", password: "wrong-password"
        )
        guard case .failed(let text) = outcome else {
            return XCTFail("expected failed, got \(outcome)")
        }
        XCTAssertFalse(text.isEmpty)
        XCTAssertFalse(text.lowercased().contains("wrong-password"))
    }

    func testConnectionTestSurfacesUnreachableServerAsFriendlyError() async throws {
        let engine = IMAPSyncEngine(
            profile: self.profile(host: "127.0.0.1", port: 1),
            account: account
        )
        let controller = OnboardingController(resolver: { _ in .manual })
        let outcome = await controller.testConnection(
            engine: engine, user: "alice@example.com", password: "x"
        )
        guard case .failed = outcome else {
            return XCTFail("expected failed, got \(outcome)")
        }
    }

    // MARK: - Adding the account

    func testAddAccountStoresCredentialAndCreatesTheAccountRow() async throws {
        let store = try makeStore()
        let credentials = InMemoryCredentialStore()
        let controller = OnboardingController(resolver: { _ in .manual })

        try await controller.addAccount(
            store: store,
            credentials: credentials,
            identity: account,
            profile: self.profile(host: "imap.example-mail.test", port: 993),
            password: "app-password-1"
        )

        // The credential is stored under the account's key and readable.
        let stored = String(decoding: try await credentials.get("account:alice@example.com:password"), as: UTF8.self)
        XCTAssertEqual(stored, "app-password-1")
        // The account row exists.
        let count = try await store.db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM account") ?? 0
        }
        XCTAssertEqual(count, 1)
    }

    func testAddAccountRejectsAnEmptyPasswordWithoutStoringAnything() async throws {
        let store = try makeStore()
        let credentials = InMemoryCredentialStore()
        let controller = OnboardingController(resolver: { _ in .manual })

        do {
            _ = try await controller.addAccount(
                store: store,
                credentials: credentials,
                identity: account,
                profile: self.profile(host: "imap.example-mail.test", port: 993),
                password: "   "
            )
            XCTFail("an empty password must be rejected")
        } catch {
            // expected
        }
        var stored: String?
        do {
            stored = String(decoding: try await credentials.get("account:alice@example.com:password"), as: UTF8.self)
        } catch CredentialError.notFound {
            stored = nil
        }
        XCTAssertNil(stored, "nothing must be stored for a rejected password")
    }

    func testAddAccountIsIdempotentForTheSameAddress() async throws {
        let store = try makeStore()
        let credentials = InMemoryCredentialStore()
        let controller = OnboardingController(resolver: { _ in .manual })
        let profile = self.profile(host: "imap.example-mail.test", port: 993)

        _ = try await controller.addAccount(
            store: store, credentials: credentials, identity: account,
            profile: profile, password: "first"
        )
        _ = try await controller.addAccount(
            store: store, credentials: credentials, identity: account,
            profile: profile, password: "second"
        )
        let count = try await store.db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM account") ?? 0
        }
        XCTAssertEqual(count, 1, "re-adding the same address updates, never duplicates")
        let stored = String(decoding: try await credentials.get("account:alice@example.com:password"), as: UTF8.self)
        XCTAssertEqual(stored, "second", "the newer secret replaces the older one")
    }

    // MARK: - Helpers

    private func profile(host: String, port: Int) -> ProviderProfile {
        ProviderProfile(
            id: "test",
            displayName: "Test",
            host: host,
            tls: port == 993 ? .implicit(port: port) : .starttls(port: port),
            credential: .appPassword,
            domains: []
        )
    }
}
