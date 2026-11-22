// Onboarding (ROADMAP M4): turn an email address into a working, tested,
// stored mail account. The controller carries the decisions; the SwiftUI
// sheet only renders them. Steps in order:
//
// 1. `resolve` runs the discovery chain (bundled database → network
//    sources → manual) and reports a `DiscoveryCandidate`.
// 2. The candidate decides the setup screen: a known provider shows its
//    `setupSteps` and `helpURL` verbatim (DESIGN 4: "create an app
//    password" is the step people get stuck on); manual entry shows
//    editable host/port/TLS fields.
// 3. `testConnection` signs in and lists folders — nothing more — and
//    turns every failure into one clear sentence for the screen.
// 4. `addAccount` stores the secret in the chosen credential store and
//    creates the account row. An empty secret is rejected before anything
//    is stored; re-adding an address updates the credential instead of
//    duplicating the row.
//
// The connection test and the store writes are the only side effects, and
// both are read-only toward the mail server (LOGIN/ID/LIST/LOGOUT —
// asserted on the wire by IMAPSyncEngineTests).

import ArchiveCore
import Credentials
import Foundation

public final class OnboardingController: Sendable {
    /// The discovery chain, injected so tests swap the database and the
    /// network sources; production wires `ProviderDiscovery` over the
    /// bundled database.
    private let resolver: @Sendable (String) -> DiscoveryCandidate

    public init(
        resolver: @escaping @Sendable (String) -> DiscoveryCandidate = {
            ProviderDiscovery().resolve($0)
        }
    ) {
        self.resolver = resolver
    }

    // MARK: - Step 1: discovery

    /// The discovery result for an email address.
    public func resolve(address: String) -> DiscoveryCandidate {
        self.resolver(address)
    }

    /// The profile for manual entry: conservative defaults, fully editable.
    public static func manualProfile(host: String, port: Int = 993, useTLS: Bool = true) -> ProviderProfile {
        ProviderProfile(
            id: "manual",
            displayName: "Manual IMAP",
            host: host,
            tls: useTLS ? .implicit(port: port) : .starttls(port: port),
            credential: .appPassword,
            domains: []
        )
    }

    // MARK: - Step 3: connection test

    /// What the connection test reports to the screen.
    public enum ConnectionOutcome: Sendable, Equatable {
        /// Signed in; `folders` are the selectable mailbox paths.
        case connected(folders: [String])
        /// One clear sentence for the screen; never echoes the secret.
        case failed(String)
    }

    /// Runs the engine's connection probe and folds every error into one
    /// sentence. The engine maps protocol failures already; this adds the
    /// friendly wording without ever suggesting the secret was at fault
    /// when it wasn't (an unreachable server is not a wrong password).
    public func testConnection(
        engine: IMAPSyncEngine,
        user: String,
        password: String
    ) async -> ConnectionOutcome {
        do {
            let folders = try await engine.testConnection(credentials: user, password: password)
            return .connected(folders: folders)
        } catch let error as SyncEngineError {
            switch error {
            case .authenticationFailed:
                return .failed("The server rejected the sign-in. Check the address and the app password.")
            case .connectionLost:
                return .failed("Could not reach the mail server. Check the address, the port, and the network.")
            case .commandFailed(let message):
                return .failed("The server refused the connection test: \(message)")
            }
        } catch {
            return .failed("The connection test failed: \(error)")
        }
    }

    // MARK: - Step 4: add the account

    public enum AddAccountError: Error, Equatable {
        /// The password field was empty or whitespace-only; nothing stored.
        case emptyPassword
    }

    /// Stores the secret under the account's key and creates (or updates)
    /// the account row. Returns the account's address as stored.
    @discardableResult
    public func addAccount(
        store: ArchiveStore,
        credentials: any CredentialStore,
        identity: AccountIdentity,
        profile: ProviderProfile,
        password: String
    ) async throws -> String {
        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AddAccountError.emptyPassword }
        let key = Self.credentialKey(email: identity.email)
        try await credentials.put(key, secret: Data(trimmed.utf8))
        _ = try store.getOrCreateAccount(identity)
        return identity.email.lowercased()
    }

    /// The credential-store key for an account's password. One convention
    /// across backends, shared with the sync scheduler's reads.
    public static func credentialKey(email: String) -> String {
        "account:\(email.lowercased()):password"
    }
}
