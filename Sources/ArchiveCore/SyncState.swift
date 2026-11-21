// Sync-state persistence (DESIGN 5, ARCHIVE-FORMAT `sync_state`). The sync
// engine stores the last completed checkpoint per mailbox so a killed sync
// resumes from it and a forced UIDVALIDITY change resets the high-water UID
// to zero. The index is disposable by design; this is the one table whose
// value is not regenerable from the `.eml` files, so it lives in the index
// and is never dropped by a rebuild.

import Foundation
import GRDB

/// A resumable sync checkpoint for one mailbox (DESIGN 5 step 3/5).
///
/// The engine reads this before opening a folder and writes it after each
/// batch. `uidValidity` records the UIDVALIDITY the `highestUID` was measured
/// under: when the server reports a different UIDVALIDITY, the engine resets
/// `highestUID` to zero and re-fetches from the start (step 3), so a folder
/// is never fetched twice under the same validity and never skipped under a
/// new one. `highestModSeq` is the HIGHESTMODSEQ the CONDSTORE fetch returned;
/// it is `nil` when the server does not support CONDSTORE (plain UID-range
/// fetch).
public struct SyncState: Sendable, Equatable, Codable {
    /// The UIDVALIDITY the `highestUID` was measured under. A change
    /// invalidates the checkpoint (DESIGN 5 step 3).
    public var uidValidity: Int64?
    /// The highest UID fetched and stored so far. New mail is `UID > highestUID`.
    public var highestUID: Int64
    /// The HIGHESTMODSEQ the CONDSTORE fetch returned, or `nil` when the
    /// server does not support CONDSTORE.
    public var highestModSeq: Int64?
    /// When the checkpoint was written (UTC, `Timestamp` format).
    public var updatedAt: String

    public init(
        uidValidity: Int64?,
        highestUID: Int64,
        highestModSeq: Int64?,
        updatedAt: String
    ) {
        self.uidValidity = uidValidity
        self.highestUID = highestUID
        self.highestModSeq = highestModSeq
        self.updatedAt = updatedAt
    }
}

extension ArchiveStore {
    /// The last completed sync checkpoint for a mailbox, or `nil` when the
    /// account or mailbox has never been synced (a fresh full sync).
    public func syncState(account: AccountIdentity, mailbox: String) throws -> SyncState? {
        try db.read { db in
            guard let accountID = try Self.accountID(for: account, db: db) else { return nil }
            guard let mailboxID = try Self.mailboxID(accountID: accountID, name: mailbox, db: db) else {
                return nil
            }
            guard let json = try String.fetchOne(
                db,
                sql: "SELECT checkpointJSON FROM sync_state WHERE accountID = ? AND mailboxID = ?",
                arguments: [accountID, mailboxID]
            ) else { return nil }
            return try Self.decodeCheckpoint(json)
        }
    }

    /// Store the checkpoint for a mailbox, replacing any previous one. The
    /// account and mailbox rows are created if absent (the engine records a
    /// checkpoint for a folder even when it holds no new messages).
    public func setSyncState(_ state: SyncState, account: AccountIdentity, mailbox: String) throws {
        try db.write { db in
            let accountID = try Self.getOrCreateAccount(account, db: db)
            let mailboxID = try Self.getOrCreateMailbox(accountID: accountID, name: mailbox, db: db)
            let json = try Self.encodeCheckpoint(state)
            try db.execute(
                sql: """
                INSERT INTO sync_state (accountID, mailboxID, checkpointJSON)
                VALUES (?, ?, ?)
                ON CONFLICT (accountID, mailboxID) DO UPDATE SET
                    checkpointJSON = excluded.checkpointJSON
                """,
                arguments: [accountID, mailboxID, json]
            )
        }
    }

    /// Drop the checkpoint for a mailbox (e.g. when the person removes the
    /// account). A no-op when the account or mailbox does not exist.
    public func clearSyncState(account: AccountIdentity, mailbox: String) throws {
        try db.write { db in
            guard let accountID = try Self.accountID(for: account, db: db) else { return }
            guard let mailboxID = try Self.mailboxID(accountID: accountID, name: mailbox, db: db) else {
                return
            }
            try db.execute(
                sql: "DELETE FROM sync_state WHERE accountID = ? AND mailboxID = ?",
                arguments: [accountID, mailboxID]
            )
        }
    }

    // MARK: - Helpers

    private static func accountID(for account: AccountIdentity, db: Database) throws -> Int64? {
        try Int64.fetchOne(
            db,
            sql: "SELECT id FROM account WHERE email = ? AND providerKind = ?",
            arguments: [account.email.lowercased(), account.providerKind]
        )
    }

    private static func mailboxID(accountID: Int64, name: String, db: Database) throws -> Int64? {
        try Int64.fetchOne(
            db,
            sql: "SELECT id FROM mailbox WHERE accountID = ? AND name = ?",
            arguments: [accountID, name]
        )
    }

    private static func encodeCheckpoint(_ state: SyncState) throws -> String {
        let data = try JSONEncoder().encode(state)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ArchiveError.corruptLayout("sync_state checkpoint")
        }
        return json
    }

    private static func decodeCheckpoint(_ json: String) throws -> SyncState {
        do {
            return try JSONDecoder().decode(SyncState.self, from: Data(json.utf8))
        } catch {
            throw ArchiveError.corruptLayout("sync_state checkpoint")
        }
    }
}
