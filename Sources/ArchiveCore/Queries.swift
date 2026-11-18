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

public struct LabelSummary: Sendable, Equatable {
    public var name: String
    public var messageCount: Int
}

public struct AccountSummary: Sendable, Equatable {
    public var email: String
    public var displayName: String
    public var messageCount: Int
}

public struct SavedSearchSummary: Sendable, Equatable {
    public var id: Int64
    public var name: String
    public var query: String
    public var createdAt: Date
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

    /// Distinct labels of one account with the number of messages carrying
    /// each. Labels with no messages still appear, so the sidebar shows the
    /// full set an import laid down.
    public func listLabels(accountEmail: String) throws -> [LabelSummary] {
        try db.read { db in
            try LabelSummary.fetchAll(
                db,
                sql: """
                SELECT l.name, COALESCE(COUNT(ml.messageID), 0) AS messageCount
                FROM label l
                JOIN account a ON a.id = l.accountID
                LEFT JOIN message_label ml ON ml.labelID = l.id
                WHERE a.email = ?
                GROUP BY l.id
                ORDER BY l.name
                """,
                arguments: [accountEmail.lowercased()]
            )
        }
    }

    /// All accounts with message counts, for the sidebar. Accounts with no
    /// messages still appear.
    public func listAccounts() throws -> [AccountSummary] {
        try db.read { db in
            try AccountSummary.fetchAll(
                db,
                sql: """
                SELECT a.email, a.displayName,
                       COALESCE(COUNT(DISTINCT m.id), 0) AS messageCount
                FROM account a
                LEFT JOIN mailbox mb ON mb.accountID = a.id
                LEFT JOIN message_mailbox mm ON mm.mailboxID = mb.id
                LEFT JOIN message m ON m.id = mm.messageID
                GROUP BY a.id
                ORDER BY a.email
                """
            )
        }
    }

    /// Saved searches (DESIGN 12), by name. Opening one runs its stored
    /// query live over the current index.
    public func listSavedSearches() throws -> [SavedSearchSummary] {
        try db.read { db in
            try SavedSearchSummary.fetchAll(
                db,
                sql: "SELECT id, name, query, createdAt FROM saved_search ORDER BY name"
            )
        }
    }

    /// Save a named query. Saving under an existing name replaces its
    /// query — the save flow is "name what you are looking at".
    public func saveSearch(name: String, query: String) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw ArchiveError.invalidSavedSearchName }
        guard !trimmedQuery.isEmpty else { throw ArchiveError.invalidSavedSearchQuery }
        try db.write { db in
            try db.execute(
                sql: """
                INSERT INTO saved_search (name, query, createdAt)
                VALUES (?, ?, ?)
                ON CONFLICT(name) DO UPDATE SET query = excluded.query
                """,
                arguments: [trimmedName, trimmedQuery, Timestamp.string(Date())]
            )
        }
    }

    /// Delete one saved search. Affects only the saved_search table.
    public func deleteSavedSearch(id: Int64) throws {
        try db.write { db in
            try db.execute(
                sql: "DELETE FROM saved_search WHERE id = ?",
                arguments: [id]
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

extension LabelSummary: FetchableRecord {
    public init(row: Row) throws {
        self.init(
            name: row["name"],
            messageCount: row["messageCount"]
        )
    }
}

extension AccountSummary: FetchableRecord {
    public init(row: Row) throws {
        self.init(
            email: row["email"],
            displayName: row["displayName"],
            messageCount: row["messageCount"]
        )
    }
}

extension SavedSearchSummary: FetchableRecord {
    public init(row: Row) throws {
        self.init(
            id: row["id"],
            name: row["name"],
            query: row["query"],
            createdAt: Timestamp.date(row["createdAt"] as String) ?? Date(timeIntervalSince1970: 0)
        )
    }
}
