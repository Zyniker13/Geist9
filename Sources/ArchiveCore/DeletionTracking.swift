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
}
