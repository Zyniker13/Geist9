// Read-side queries over the index (DESIGN 6). Search ranking lives in
// ArchiveSearch (6A); these are the plain SQL listings every client shares.

import Foundation
import GRDB

/// A message row as the message list and MCP listing need it.
public struct MessageSummary: Sendable, Equatable {
    public var id: Int64
    public var hash: MessageHash
    public var subject: String?
    public var fromName: String?
    public var fromEmail: String?
    public var dateSent: Date?
    public var dateReceived: Date?
    public var size: Int
}

public struct MailboxSummary: Sendable, Equatable {
    public var id: Int64
    public var accountID: Int64
    public var name: String
    public var role: String?
    public var messageCount: Int
}

extension ArchiveStore {
    /// Messages in one mailbox, newest first by dateReceived (then id).
    public func listMessages(mailbox: String, newestFirst: Bool = true, limit: Int = 100, offset: Int = 0) throws -> [MessageSummary] {
        let direction = newestFirst ? "DESC" : "ASC"
        return try db.read { db in
            try MessageSummary.fetchAll(
                db,
                sql: """
                SELECT m.id, m.hash, m.subject, m.fromName, m.fromEmail,
                       m.dateSent, m.dateReceived, m.size
                FROM message m
                JOIN message_mailbox mm ON mm.messageID = m.id
                JOIN mailbox mb ON mb.id = mm.mailboxID
                WHERE mb.name = ?
                ORDER BY m.dateReceived \(direction), m.id \(direction)
                LIMIT ? OFFSET ?
                """,
                arguments: [mailbox, limit, offset]
            )
        }
    }

    public func countMessages() throws -> Int {
        try db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message") ?? 0
        }
    }

    /// One message row by its index id — the id search hits and the viewer
    /// carry. nil when no row has that id.
    public func message(id: Int64) throws -> MessageSummary? {
        try db.read { db in
            try MessageSummary.fetchOne(
                db,
                sql: """
                SELECT id, hash, subject, fromName, fromEmail,
                       dateSent, dateReceived, size
                FROM message WHERE id = ?
                """,
                arguments: [id]
            )
        }
    }

    /// All mailboxes of one account, with message counts.
    public func listMailboxes(accountEmail: String) throws -> [MailboxSummary] {
        try db.read { db in
            try MailboxSummary.fetchAll(
                db,
                sql: """
                SELECT mb.id, mb.accountID, mb.name, mb.role,
                       COALESCE(COUNT(mm.messageID), 0) AS messageCount
                FROM mailbox mb
                JOIN account a ON a.id = mb.accountID
                LEFT JOIN message_mailbox mm ON mm.mailboxID = mb.id
                WHERE a.email = ?
                GROUP BY mb.id
                ORDER BY mb.name
                """,
                arguments: [accountEmail.lowercased()]
            )
        }
    }
}

/// GRDB row mapping.
extension MessageSummary: FetchableRecord {
    public init(row: Row) throws {
        self.init(
            id: row["id"],
            hash: MessageHash(bytes: row["hash"] as Data),
            subject: row["subject"],
            fromName: row["fromName"],
            fromEmail: row["fromEmail"],
            dateSent: (row["dateSent"] as String?).flatMap(Timestamp.date),
            dateReceived: (row["dateReceived"] as String?).flatMap(Timestamp.date),
            size: row["size"]
        )
    }
}

extension MailboxSummary: FetchableRecord {
    public init(row: Row) throws {
        self.init(
            id: row["id"],
            accountID: row["accountID"],
            name: row["name"],
            role: row["role"],
            messageCount: row["messageCount"]
        )
    }
}
