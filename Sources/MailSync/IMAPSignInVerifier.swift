/// The real sign-in verifier for credential-store moves (DESIGN 4,
/// "Credentials and 1Password"): proves a secret works by signing in and
/// listing the folders — the same read-only probe the onboarding connection
/// test uses, never a sync pass and never a write.
///
/// `CredentialStoreMove` (Credentials) writes the secret to the destination
/// store, asks this verifier to sign in with it, and deletes the source copy
/// only on success — so a verifier that reports honestly is what keeps a
/// move from ever losing the archive's secret.
import ArchiveCore
import Credentials
import Foundation

/// Signs in over IMAP with the candidate secret. Reports `false` only when
/// the server actively rejected the credentials; an unreachable server (or
/// any other failure) throws, which `CredentialStoreMove` folds into
/// "unavailable" and keeps the old copy — a network outage must never look
/// like a wrong password, and neither outcome may delete the source secret.
public struct IMAPSignInVerifier: SignInVerifier {
    /// The account's provider profile: host, port, TLS, quirks.
    public let profile: ProviderProfile

    public init(profile: ProviderProfile) {
        self.profile = profile
    }

    public func canSignIn(accountKey: String, secret: Data) async throws -> Bool {
        guard let email = Self.email(fromKey: accountKey) else {
            throw CredentialError.unavailable("credential key does not name an account")
        }
        let engine = IMAPSyncEngine(
            profile: self.profile,
            account: AccountIdentity(email: email, displayName: email, providerKind: "imap")
        )
        do {
            _ = try await engine.testConnection(
                credentials: email,
                password: String(decoding: secret, as: UTF8.self)
            )
            return true
        } catch let error as SyncEngineError {
            // Only an active rejection answers "no". Everything else
            // (unreachable, lost mid-handshake) propagates: the caller
            // distinguishes "the secret is wrong" from "try again later".
            if case .authenticationFailed = error { return false }
            throw error
        }
    }

    /// The reverse of `OnboardingController.credentialKey`:
    /// `account:<email>:password` → the email. One convention across
    /// backends, shared with the sync scheduler's reads.
    public static func email(fromKey key: String) -> String? {
        let prefix = "account:"
        let suffix = ":password"
        guard key.hasPrefix(prefix), key.hasSuffix(suffix) else { return nil }
        let email = key.dropFirst(prefix.count).dropLast(suffix.count)
        return email.isEmpty ? nil : String(email)
    }
}
