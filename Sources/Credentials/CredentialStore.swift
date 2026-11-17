/// One interface for every secret the app touches (DESIGN 4, "Credentials and 1Password").
///
/// Two backends, chosen per archive and mixable per account:
/// - **Keychain** (default): generic-password items, accessible after first unlock on
///   this device only, shared with the login item through a Keychain access group.
/// - **1Password**: a dedicated vault the person picks or creates; the app keeps only
///   the item's `op://` secret reference and non-secret settings (decision 0005).
///
/// Secrets are read at the start of a sync and held in memory only for that session.
/// Nothing from a credential store is ever written to disk, logs, the index, or exports
/// (DESIGN 10).
import Foundation

public protocol CredentialStore: Sendable {
    /// Reads the secret stored under `key`. Throws `CredentialError.notFound` when absent.
    func get(_ key: String) async throws -> Data

    /// Stores `secret` under `key`, replacing any existing value.
    func put(_ key: String, secret: Data) async throws

    /// Removes the secret under `key`. Removing an absent key is not an error.
    func delete(_ key: String) async throws

    /// Replaces the secret under `key` in one step, for providers that rotate OAuth
    /// refresh tokens on use (DESIGN 4). Throws `CredentialError.notFound` when absent.
    func rotate(_ key: String, to newSecret: Data) async throws
}

/// Errors every backend reports in the same shape, so callers never special-case a store.
public enum CredentialError: Error, Equatable, Sendable {
    /// No secret is stored under that key.
    case notFound
    /// The store refused the operation (locked vault, unwritable item, ...).
    case unavailable(String)
}

/// The mock every test uses instead of the Keychain or 1Password (TESTING, "Unit").
/// A test that needs a server it can't start fails; a test that needs credentials
/// uses this.
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: Data]

    public init(secrets: [String: Data] = [:]) {
        self.secrets = secrets
    }

    // Synchronous core: async methods call these so no lock is taken from async context.
    private func read(_ key: String) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard let secret = secrets[key] else { throw CredentialError.notFound }
        return secret
    }

    private func write(_ key: String, _ secret: Data) {
        lock.lock()
        defer { lock.unlock() }
        secrets[key] = secret
    }

    private func remove(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        secrets[key] = nil
    }

    private func replace(_ key: String, _ newSecret: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard secrets[key] != nil else { throw CredentialError.notFound }
        secrets[key] = newSecret
    }

    public func get(_ key: String) async throws -> Data {
        try read(key)
    }

    public func put(_ key: String, secret: Data) async throws {
        write(key, secret)
    }

    public func delete(_ key: String) async throws {
        remove(key)
    }

    public func rotate(_ key: String, to newSecret: Data) async throws {
        try replace(key, newSecret)
    }
}
