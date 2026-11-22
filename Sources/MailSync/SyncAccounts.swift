import ArchiveCore
import Foundation
import GRDB

/// The typed profile wrappers over the account row's stored profile
/// (decision 0062). `ArchiveCore` stays free of `MailSync` types: it keeps
/// the JSON column, this file decodes it.
extension ArchiveStore {
    /// An account the scheduler can sync: its identity plus the provider
    /// profile the person confirmed at onboarding.
    public struct SyncableAccount: Sendable, Equatable {
        public var identity: AccountIdentity
        public var profile: ProviderProfile
    }

    /// The stored profile for an account, decoded from the account row.
    /// `nil` when the account is unknown or has no stored profile (imports,
    /// pre-0062 rows) — such accounts are never scheduled.
    /// A row that holds undecodable JSON is a corrupt archive, not a skip:
    /// throw `corruptLayout` so it surfaces, mirroring checkpoint handling.
    public func accountProfile(identity: AccountIdentity) throws -> ProviderProfile? {
        guard let json = try accountProfileJSON(account: identity) else { return nil }
        do {
            return try JSONDecoder().decode(ProviderProfile.self, from: Data(json.utf8))
        } catch {
            throw ArchiveError.corruptLayout("account provider profile")
        }
    }

    /// Every account the scheduler may sync: IMAP accounts with a stored
    /// profile, in stable row order. Import pseudo-accounts are excluded.
    public func syncableAccounts() throws -> [SyncableAccount] {
        let rows: [(identity: AccountIdentity, json: String?)] = try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT email, displayName, providerKind, providerJSON FROM account
                WHERE providerKind = 'imap'
                ORDER BY id
                """)
            return rows.map { row in
                (
                    AccountIdentity(
                        email: row["email"] ?? "",
                        displayName: row["displayName"] ?? "",
                        providerKind: row["providerKind"] ?? "imap"
                    ),
                    row["providerJSON"] as String?
                )
            }
        }
        return try rows.compactMap { identity, json in
            guard let json else { return nil }
            do {
                return SyncableAccount(
                    identity: identity,
                    profile: try JSONDecoder().decode(ProviderProfile.self, from: Data(json.utf8))
                )
            } catch {
                throw ArchiveError.corruptLayout("account provider profile")
            }
        }
    }
}
