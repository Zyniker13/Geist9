/// Moving an account's secret between stores (DESIGN 4, "Credentials and
/// 1Password").
///
/// The move is safe in one direction only: the new store is written and
/// verified with a test sign-in BEFORE the old copy is deleted. If the test
/// sign-in fails, the old copy stays and the error is returned — the secret
/// is never lost. The verifier is injectable: the app wires the real IMAP
/// sign-in (M4 task 1); tests use a fake.
import Foundation

/// Verifies that a secret actually works against the account's server.
/// The real implementation signs in over IMAP; it must not write anything
/// to the server (read-only, DESIGN 1).
public protocol SignInVerifier: Sendable {
    /// Returns `true` when the secret signs in successfully.
    func canSignIn(accountKey: String, secret: Data) async throws -> Bool
}

/// The result of a move, for the UI.
public struct MoveResult: Sendable, Equatable {
    public let oldKey: String
    public let newKey: String
    public let oldCopyDeleted: Bool
}

/// Moves one secret from one store to another.
public struct CredentialStoreMove {
    private let verifier: SignInVerifier

    public init(verifier: SignInVerifier) {
        self.verifier = verifier
    }

    /// Moves `key` from `source` to `destination`.
    ///
    /// - The secret is read from the source and written to the destination.
    /// - A test sign-in with the destination's copy must succeed before the
    ///   source copy is deleted.
    /// - If the source has no such key, the move is a no-op (`notFound`).
    /// - If the sign-in fails, the source copy is kept and the error is
    ///   thrown; the destination copy is left in place (the user can retry
    ///   or delete it).
    @discardableResult
    public func move(
        _ key: String,
        from source: CredentialStore,
        to destination: CredentialStore,
        newKey: String? = nil
    ) async throws -> MoveResult {
        let targetKey = newKey ?? key
        let secret = try await source.get(key)
        try await destination.put(targetKey, secret: secret)

        let works: Bool
        do {
            works = try await verifier.canSignIn(accountKey: targetKey, secret: secret)
        } catch {
            // Verification itself failed (network, timeout): the destination
            // copy exists but is unverified. Keep the source copy and report.
            throw CredentialError.unavailable("test sign-in failed: \(error)")
        }
        guard works else {
            throw CredentialError.unavailable("test sign-in rejected the secret; the old copy was kept")
        }

        try await source.delete(key)
        return MoveResult(oldKey: key, newKey: targetKey, oldCopyDeleted: true)
    }
}
