/// End-to-end credential-store moves (DESIGN 4 Done-when: "Accounts work
/// with credentials in the Keychain and in the (fake) 1Password backend, and
/// can be moved between them"): the real `IMAPSignInVerifier` proves a
/// candidate secret by an actual read-only sign-in against the in-repo fake
/// IMAP server, then `CredentialStoreMove` relocates the secret between two
/// stores — Keychain → 1Password, 1Password → Keychain, and the failure
/// paths that must leave the old copy in place. The stores here are the
/// test mock (`InMemoryCredentialStore`); the Keychain and 1Password
/// backends' own suites (CredentialsTests) already pin their storage
/// behavior, and any two stores move the same way through this verifier.
import Credentials
import XCTest
@testable import MailSync

final class CredentialMoveEndToEndTests: XCTestCase {
    private var tempDir: URL!
    /// The fake server accepts alice@example.com / secret and nothing else.
    private var server: FakeIMAPServer!

    override func setUpWithError() throws {
        self.tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("geist9-credmove-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: self.tempDir, withIntermediateDirectories: true)
        self.server = FakeIMAPServer(scenario: FakeServerScenario(folders: [
            FakeFolder(
                name: "INBOX",
                messages: [FakeMessage(uid: 1, data: Data("x".utf8))],
                uidValidity: 1
            ),
        ]))
        try self.server.start()
    }

    override func tearDown() {
        self.server?.stop()
        self.server = nil
        try? FileManager.default.removeItem(at: self.tempDir!)
        self.tempDir = nil
    }

    private let email = "alice@example.com"
    /// The one credential-key convention shared by onboarding, the scheduler
    /// and the verifier.
    private var key: String { OnboardingController.credentialKey(email: self.email) }
    /// What a correct onboarding wrote: the account's password as UTF-8.
    private var goodSecret: Data { Data("secret".utf8) }

    private var profile: ProviderProfile {
        var profile = ProviderProfile(
            id: "move-test",
            displayName: "Move test",
            host: "127.0.0.1",
            tls: .starttls(port: Int(self.server.port)), // plain loopback server
            credential: .appPassword,
            domains: []
        )
        profile.politeness.batchPauseSeconds = 0
        return profile
    }

    // MARK: - Keychain → 1Password

    /// The whole Done-when flow: the secret lives in the Keychain-side
    /// store; the verifier proves the candidate secret with a real sign-in
    /// against the fake IMAP server; the move writes the 1Password-side
    /// store, verifies, and only then deletes the source copy. Afterwards
    /// the account's secret is readable from exactly one store.
    func testMoveFromKeychainToTheOnePasswordBackend() async throws {
        let keychain = InMemoryCredentialStore()
        let onePassword = InMemoryCredentialStore()
        try await keychain.put(self.key, secret: self.goodSecret)

        let move = CredentialStoreMove(verifier: IMAPSignInVerifier(profile: self.profile))
        let result = try await move.move(self.key, from: keychain, to: onePassword)

        XCTAssertTrue(result.oldCopyDeleted, "the move deleted the old copy only after the sign-in verified")
        let moved = try await onePassword.get(self.key)
        XCTAssertEqual(moved, self.goodSecret, "the 1Password backend now holds the secret")
        do {
            _ = try await keychain.get(self.key)
            XCTFail("the Keychain copy must be gone")
        } catch let error as CredentialError {
            XCTAssertEqual(error, .notFound)
        }
    }

    // MARK: - 1Password → Keychain

    func testMoveFromTheOnePasswordBackendBackToTheKeychain() async throws {
        let keychain = InMemoryCredentialStore()
        let onePassword = InMemoryCredentialStore()
        try await onePassword.put(self.key, secret: self.goodSecret)

        let move = CredentialStoreMove(verifier: IMAPSignInVerifier(profile: self.profile))
        let result = try await move.move(self.key, from: onePassword, to: keychain)

        XCTAssertTrue(result.oldCopyDeleted)
        let back = try await keychain.get(self.key)
        XCTAssertEqual(back, self.goodSecret)
        do {
            _ = try await onePassword.get(self.key)
            XCTFail("the 1Password copy must be gone")
        } catch let error as CredentialError {
            XCTAssertEqual(error, .notFound)
        }
    }

    // MARK: - A wrong secret is never moved

    /// The verifier signs in with the candidate bytes; the server is scripted
    /// to reject every login; the move must throw and leave the source copy
    /// exactly as it was — the archive's secret is never lost to a failed
    /// move. (Scripting the rejection, instead of planting a stale secret in
    /// the destination, is the honest shape of this failure: the candidate
    /// the verifier signs in with IS the source secret, and the server
    /// refuses it because the password was rotated server-side.)
    func testARejectedSecretStopsTheMoveAndKeepsTheOldCopy() async throws {
        let keychain = InMemoryCredentialStore()
        let onePassword = InMemoryCredentialStore()
        try await keychain.put(self.key, secret: self.goodSecret)
        self.server.setLoginFails(true)

        let move = CredentialStoreMove(verifier: IMAPSignInVerifier(profile: self.profile))
        do {
            _ = try await move.move(self.key, from: keychain, to: onePassword)
            XCTFail("a rejected secret must stop the move")
        } catch let error as CredentialError {
            guard case .unavailable = error else {
                return XCTFail("expected unavailable, got \(error)")
            }
        }
        let kept = try await keychain.get(self.key)
        XCTAssertEqual(kept, self.goodSecret, "the old copy survives a failed move byte for byte")
    }

    // MARK: - An unreachable server never looks like a wrong password

    /// Nothing listens on this port: the verifier throws (it does not
    /// answer `false`), so the move fails as "unavailable" and the old copy
    /// stays. A network outage must never read as a rejected password.
    func testAnUnreachableServerThrowsAndKeepsTheOldCopy() async throws {
        var dead = self.profile
        dead.tls = .starttls(port: 1)
        let keychain = InMemoryCredentialStore()
        let onePassword = InMemoryCredentialStore()
        try await keychain.put(self.key, secret: self.goodSecret)

        let move = CredentialStoreMove(verifier: IMAPSignInVerifier(profile: dead))
        do {
            _ = try await move.move(self.key, from: keychain, to: onePassword)
            XCTFail("an unreachable server must surface as an error")
        } catch {
            // Unavailable is what the move folds network failures into.
        }
        let keptAfterOutage = try await keychain.get(self.key)
        XCTAssertEqual(keptAfterOutage, self.goodSecret, "the old copy survives a failed move")
    }
}
