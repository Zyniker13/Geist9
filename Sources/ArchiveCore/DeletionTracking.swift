// Deletion tracking (DESIGN 5 step 6, DESIGN 6). Server-side deletions
// never delete from the archive: after each sync pass the engine marks the
// memberships it did not see this pass, the index shows those messages as
// "no longer on the server" with the date, and the person decides what
// happens to them (default: keep forever). This is the only API that flips
// `message_mailbox.removedFromServer`, and it never touches message rows or
// stored bytes.

import Foundation
import GRDB

/// The result of one `markUnseenMemberships` pass.
public struct DeletionReport: Sendable, Equatable {
    /// Message rows (per account+mailbox pair) whose only membership is now
    /// marked removed: they vanished from the server this pass.
    public var newlyRemoved: Int
    /// Memberships marked removed this pass (messages still present in
    /// another mailbox are counted here, not in `newlyRemoved`).
    public var membershipsMarked: Int

    public init(newlyRemoved: Int, membershipsMarked: Int) {
        self.newlyRemoved = newlyRemoved
        self.membershipsMarked = membershipsMarked
    }
}

extension ArchiveStore {
    /// One pass-level helper the sync engine calls after LIST: every mailbox
    /// of `account` NOT among `presentMailboxes` (the folders this pass's
    /// LIST named) has vanished from the server — mark all its live
    /// memberships removed. Nothing is ever deleted; the message row, its
    /// bytes, and its search text all stay.
    public func markMembershipsInVanishedFolders(
        account: AccountIdentity, presentMailboxes: [String]
    ) throws -> DeletionReport {
        let now = Timestamp.string(Date())
        return try db.write { db in
            guard let accountID = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM account WHERE email = ? AND providerKind = ?",
                arguments: [account.email.lowercased(), account.providerKind]
            ) else {
                return DeletionReport(newlyRemoved: 0, membershipsMarked: 0)
            }
            let presentIDs: [Int64] = try presentMailboxes.map { name in
                try Int64.fetchOne(
                    db,
                    sql: "SELECT id FROM mailbox WHERE accountID = ? AND name = ?",
                    arguments: [accountID, name]
                ) ?? -1
            }
            let vanishedIDs = try Int64.fetchAll(
                db,
                sql: "SELECT id FROM mailbox WHERE accountID = ?",
                arguments: [accountID]
            ).filter { !presentIDs.contains($0) }
            guard !vanishedIDs.isEmpty else {
                return DeletionReport(newlyRemoved: 0, membershipsMarked: 0)
            }
            let placeholders = vanishedIDs.map { _ in "?" }.joined(separator: ", ")
            var args: [any GRDB.DatabaseValueConvertible] = [now]
            args.append(contentsOf: vanishedIDs)
            let changed = try Int.fetchAll(
                db,
                sql: """
                UPDATE message_mailbox
                SET removedFromServer = 1, lastSeen = ?
                WHERE mailboxID IN (\(placeholders))
                  AND removedFromServer = 0
                RETURNING messageID
                """,
                arguments: StatementArguments(args)
            ).count
            let newlyRemoved = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM message m
                WHERE m.id IN (SELECT messageID FROM message_mailbox WHERE mailboxID IN (\(placeholders)))
                  AND NOT EXISTS (
                    SELECT 1 FROM message_mailbox mm
                    WHERE mm.messageID = m.id AND mm.removedFromServer = 0
                  )
                """,
                arguments: StatementArguments(vanishedIDs)
            ) ?? 0
            return DeletionReport(newlyRemoved: newlyRemoved, membershipsMarked: changed)
        }
    }

    /// Marks every membership of `account` in `mailbox` whose `uid` is NOT
    /// in `serverUIDs` — the UIDs the folder's UID SEARCH reported this
    /// pass — as removed from the server.
    ///
    /// The engine calls this once per folder per pass with the folder's
    /// live UID set. A message that exists but sits above the checkpoint
    /// keeps its membership (its UID is in the set); only a UID the server
    /// no longer has is marked. Nothing is ever deleted.
    public func markMembershipsAbsentFrom(
        account: AccountIdentity, mailbox: String, serverUIDs: Set<Int64>
    ) throws -> DeletionReport {
        let now = Timestamp.string(Date())
        return try db.write { db in
            guard let accountID = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM account WHERE email = ? AND providerKind = ?",
                arguments: [account.email.lowercased(), account.providerKind]
            ), let mailboxID = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM mailbox WHERE accountID = ? AND name = ?",
                arguments: [accountID, mailbox]
            ) else {
                return DeletionReport(newlyRemoved: 0, membershipsMarked: 0)
            }
            // A membership is gone when the server's live set no longer
            // contains its uid. The live UIDs go into a temp table so the
            // comparison works for folders of any size (no IN-list cap).
            var changed = 0
            try db.execute(sql: "CREATE TEMP TABLE liveUIDs (uid INTEGER PRIMARY KEY)")
            defer { try? db.execute(sql: "DROP TABLE IF EXISTS temp.liveUIDs") }
            for uid in serverUIDs {
                try db.execute(
                    sql: "INSERT INTO temp.liveUIDs (uid) VALUES (?)",
                    arguments: [uid]
                )
            }
            changed = try Int.fetchAll(
                db,
                sql: """
                UPDATE message_mailbox
                SET removedFromServer = 1, lastSeen = ?
                WHERE mailboxID = ? AND removedFromServer = 0
                  AND uid IS NOT NULL
                  AND uid NOT IN (SELECT uid FROM temp.liveUIDs)
                RETURNING messageID
                """,
                arguments: [now, mailboxID]
            ).count
            // A message is "gone from the server" when EVERY membership that
            // named it is now removed (it may live in several folders).
            let newlyRemoved = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM message m
                WHERE m.id IN (SELECT messageID FROM message_mailbox WHERE mailboxID = ?)
                  AND NOT EXISTS (
                    SELECT 1 FROM message_mailbox mm
                    WHERE mm.messageID = m.id AND mm.removedFromServer = 0
                  )
                """,
                arguments: [mailboxID]
            ) ?? 0
            return DeletionReport(newlyRemoved: newlyRemoved, membershipsMarked: changed)
        }
    }

    /// Marks every membership of `accountID` in the given mailboxes that was
    /// NOT seen in this sync pass, as judged by `lastSeen < cutoff`.
    ///
    /// The engine calls this once per sync with `cutoff` = the timestamp it
    /// stamped every seen membership with (`now` of that pass). A membership
    /// the pass refreshed has `lastSeen == cutoff` and stays; one the pass did
    /// not touch (message gone from the server, or folder no longer synced)
    /// has an older `lastSeen` and is marked `removedFromServer = 1` with the
    /// pass time.
    ///
    /// Per the data-safety rules the message row and its bytes are never
    /// touched; a message removed from every server mailbox stays fully
    /// searchable, now carrying the fact that the server no longer has it.
    public func markUnseenMemberships(
        accountID: Int64, mailboxIDs: [Int64], cutoff: String, now: String
    ) throws -> DeletionReport {
        guard !mailboxIDs.isEmpty else { return DeletionReport(newlyRemoved: 0, membershipsMarked: 0) }
        return try db.write { db in
            let placeholders = mailboxIDs.map { _ in "?" }.joined(separator: ", ")
            var updateArgs: [any GRDB.DatabaseValueConvertible] = [now]
            updateArgs.append(contentsOf: mailboxIDs)
            updateArgs.append(cutoff)
            let changed = try Int.fetchAll(
                db,
                sql: """
                UPDATE message_mailbox
                SET removedFromServer = 1, lastSeen = ?
                WHERE mailboxID IN (\(placeholders))
                  AND lastSeen < ?
                  AND removedFromServer = 0
                RETURNING messageID
                """,
                arguments: StatementArguments(updateArgs)
            ).count
            // A message is "gone from the server" when EVERY membership that
            // named it is now removed (it may live in several folders).
            let newlyRemoved = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM message m
                WHERE m.id IN (SELECT messageID FROM message_mailbox WHERE mailboxID IN (\(placeholders)))
                  AND NOT EXISTS (
                    SELECT 1 FROM message_mailbox mm
                    WHERE mm.messageID = m.id AND mm.removedFromServer = 0
                  )
                """,
                arguments: StatementArguments(mailboxIDs)
            ) ?? 0
            _ = placeholders
            return DeletionReport(newlyRemoved: newlyRemoved, membershipsMarked: changed)
        }
    }

    /// JMAP deletion tracking (DESIGN 5 "JMAP"): the server's
    /// `Email/changes.destroyed` names JMAP email ids, not UIDs, so this
    /// marks the membership whose stored external id matches. JMAP
    /// memberships carry the JMAP id in `uid`'s place (they are nil-UID
    /// memberships otherwise), keyed in `message_mailbox` the same way.
    /// Nothing is ever deleted; the message row, its bytes, and its search
    /// text all stay.
    ///
    /// The external id lives in the membership's uid column as a negative
    /// stable hash of the JMAP id string: the uid column is NOT NULL in the
    /// schema and the store keeps no separate column for it (decision 0066:
    /// no schema change for M6 — a JMAP id hashed into the same column the
    /// IMAP engine uses stays unique per server id and never collides with
    /// a real IMAP UID because JMAP memberships are negative).
    public func markJMAPMembershipsDestroyed(
        account: AccountIdentity, mailbox: String, jmapIDs: [String]
    ) throws -> DeletionReport {
        guard !jmapIDs.isEmpty else {
            return DeletionReport(newlyRemoved: 0, membershipsMarked: 0)
        }
        let now = Timestamp.string(Date())
        let hashed = jmapIDs.map(Self.jmapMembershipUID)
        return try db.write { db in
            guard let accountID = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM account WHERE email = ? AND providerKind = ?",
                arguments: [account.email.lowercased(), account.providerKind]
            ), let mailboxID = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM mailbox WHERE accountID = ? AND name = ?",
                arguments: [accountID, mailbox]
            ) else {
                return DeletionReport(newlyRemoved: 0, membershipsMarked: 0)
            }
            var marked = 0
            for uid in hashed {
                marked += try Int.fetchAll(
                    db,
                    sql: """
                    UPDATE message_mailbox
                    SET removedFromServer = 1, lastSeen = ?
                    WHERE mailboxID = ? AND uid = ? AND removedFromServer = 0
                    RETURNING messageID
                    """,
                    arguments: [now, mailboxID, uid]
                ).count
            }
            // A message is "gone from the server" when EVERY membership that
            // named it is now removed (it may live in several mailboxes).
            let newlyRemoved = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM message m
                WHERE m.id IN (
                    SELECT messageID FROM message_mailbox
                    WHERE mailboxID = ? AND removedFromServer = 1
                      AND lastSeen = ?
                  )
                  AND NOT EXISTS (
                    SELECT 1 FROM message_mailbox mm
                    WHERE mm.messageID = m.id AND mm.removedFromServer = 0
                  )
                """,
                arguments: [mailboxID, now]
            ) ?? 0
            return DeletionReport(newlyRemoved: newlyRemoved, membershipsMarked: marked)
        }
    }

    /// The stable, non-colliding uid-column value for a JMAP email id:
    /// the low 62 bits of the id's SHA-256, negated (never a real IMAP UID).
    public static func jmapMembershipUID(_ jmapID: String) -> Int64 {
        let digest = MessageHash.sha256(Data(jmapID.utf8)).bytes
        var value: UInt64 = 0
        for byte in digest.prefix(8) {
            value = (value << 8) | UInt64(byte)
        }
        let positive = Int64(value & 0x3FFF_FFFF_FFFF_FFFF)
        return positive == 0 ? -1 : -positive
    }
}
