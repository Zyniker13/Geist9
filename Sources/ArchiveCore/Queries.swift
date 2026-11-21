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
    /// The conversation this message belongs to (nil when the message never
    /// joined a thread). Agent access uses it to walk from one hit to its
    /// whole conversation with get_thread.
    public var threadID: Int64?
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

/// One attachment row of one message as listings need it. `textState` is
/// the OCR queue state of the part (decision 0050): "done" for parts whose
/// text is settled, "pending" while the queue has not reached it.
public struct AttachmentSummary: Sendable, Equatable, Hashable {
    public var id: Int64
    public var partIndex: String
    public var filename: String?
    public var contentType: String
    public var size: Int
    public var textState: String
}

/// One address of the archive with how much mail involves it (DESIGN 9A
/// find_contacts). `name` is the most recent display name seen for the
/// address, or the address itself when no non-empty name was ever seen.
public struct ContactSummary: Sendable, Equatable, Hashable {
    public var email: String
    public var name: String
    public var messageCount: Int
    public var firstDate: Date?
    public var lastDate: Date?
}

/// Archive totals (DESIGN 9A archive_stats): messages per account, per
/// year, and per sender, for "how much mail from X per year"-shaped
/// questions without a search round-trip.
public struct ArchiveStats: Sendable, Equatable {
    public struct AccountCount: Sendable, Equatable {
        public var email: String
        public var displayName: String
        public var messageCount: Int
    }

    public struct YearCount: Sendable, Equatable {
        public var year: String
        public var messageCount: Int
    }

    public struct SenderCount: Sendable, Equatable {
        public var email: String
        public var name: String?
        public var messageCount: Int
        public var firstDate: Date?
        public var lastDate: Date?
    }

    public var byAccount: [AccountCount]
    public var byYear: [YearCount]
    public var bySender: [SenderCount]
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
                       m.dateSent, m.dateReceived, m.size, m.threadID
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
                       dateSent, dateReceived, size, threadID
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

    /// All messages of one thread, oldest first, as the MCP get_thread tool
    /// and any other client list them. Threads hold message ids, so this is
    /// one indexed lookup; ties on the same timestamp break by id, which is
    /// ingest order (the same rule the ranking uses for ties).
    public func threadMessages(threadID: Int64) throws -> [MessageSummary] {
        try db.read { db in
            try MessageSummary.fetchAll(
                db,
                sql: """
                SELECT id, hash, subject, fromName, fromEmail,
                       dateSent, dateReceived, size, threadID
                FROM message WHERE threadID = ?
                ORDER BY COALESCE(dateReceived, dateSent), id
                """,
                arguments: [threadID]
            )
        }
    }

    /// The stored subject of one thread, nil when no thread has that id.
    public func threadSubject(threadID: Int64) throws -> String? {
        try db.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT rootSubject FROM thread WHERE id = ?",
                arguments: [threadID]
            )
        }
    }

    /// The attachments of one message, in MIME part order, with their OCR
    /// queue state (decision 0050). `get_attachment_text` needs the part
    /// path; viewers need the rest.
    public func messageAttachments(messageID: Int64) throws -> [AttachmentSummary] {
        try db.read { db in
            try AttachmentSummary.fetchAll(
                db,
                sql: """
                SELECT id, partIndex, filename, contentType, size, textState
                FROM attachment WHERE messageID = ?
                ORDER BY partIndex
                """,
                arguments: [messageID]
            )
        }
    }

    /// The labels one message carries, sorted. Empty for most messages:
    /// only imports that laid labels down have any.
    public func messageLabels(messageID: Int64) throws -> [String] {
        try db.read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT l.name
                FROM label l
                JOIN message_label ml ON ml.labelID = l.id
                WHERE ml.messageID = ?
                ORDER BY l.name
                """,
                arguments: [messageID]
            )
        }
    }

    /// Addresses and names seen in the archive (DESIGN 9A find_contacts),
    /// most-recent messages first by count. A message counts for an address
    /// once, whatever roles (from, to, cc, bcc, reply-to) it carries the
    /// address in. Counts and dates come from the message rows, so a
    /// deleted message leaves the counts too.
    public func findContacts(limit: Int = 50) throws -> [ContactSummary] {
        let capped = max(1, min(limit, 10_000))
        return try db.read { db in
            try ContactSummary.fetchAll(
                db,
                sql: """
                SELECT a.email, a.name,
                       COUNT(DISTINCT ma.messageID) AS messageCount,
                       MIN(COALESCE(m.dateReceived, m.dateSent)) AS firstDate,
                       MAX(COALESCE(m.dateReceived, m.dateSent)) AS lastDate
                FROM address a
                JOIN message_address ma ON ma.addressID = a.id
                JOIN message m ON m.id = ma.messageID
                GROUP BY a.id
                ORDER BY messageCount DESC, a.email
                LIMIT ?
                """,
                arguments: [capped]
            )
        }
    }

    /// Archive totals by account, year, and sender (DESIGN 9A
    /// archive_stats), for questions like "how much mail from X per year".
    /// `senderLimit` caps the sender list; the year and account lists are
    /// always complete.
    public func archiveStats(senderLimit: Int = 50) throws -> ArchiveStats {
        let cappedSenders = max(1, min(senderLimit, 10_000))
        let accounts = try listAccounts().map {
            ArchiveStats.AccountCount(
                email: $0.email,
                displayName: $0.displayName,
                messageCount: $0.messageCount
            )
        }
        let years = try db.read { db in
            try ArchiveStats.YearCount.fetchAll(
                db,
                sql: """
                SELECT substr(COALESCE(dateReceived, dateSent, 'none'), 1, 4) AS year,
                       COUNT(*) AS messageCount
                FROM message
                GROUP BY year
                ORDER BY year
                """
            )
        }
        .filter { $0.year.count == 4 }
        let senders = try db.read { db in
            try ArchiveStats.SenderCount.fetchAll(
                db,
                sql: """
                SELECT m.fromEmail AS email,
                       (SELECT m2.fromName FROM message m2
                        WHERE m2.fromEmail = m.fromEmail AND m2.fromName != ''
                        ORDER BY COALESCE(m2.dateReceived, m2.dateSent) DESC, m2.id DESC
                        LIMIT 1) AS name,
                       COUNT(*) AS messageCount,
                       MIN(COALESCE(m.dateReceived, m.dateSent)) AS firstDate,
                       MAX(COALESCE(m.dateReceived, m.dateSent)) AS lastDate
                FROM message m
                GROUP BY m.fromEmail
                ORDER BY messageCount DESC, email
                LIMIT ?
                """,
                arguments: [cappedSenders]
            )
        }
        return ArchiveStats(
            byAccount: accounts,
            byYear: years,
            bySender: senders
        )
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
            size: row["size"],
            threadID: row["threadID"]
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

extension AttachmentSummary: FetchableRecord {
    public init(row: Row) throws {
        self.init(
            id: row["id"],
            partIndex: row["partIndex"],
            filename: row["filename"],
            contentType: row["contentType"],
            size: row["size"],
            textState: row["textState"]
        )
    }
}

extension ContactSummary: FetchableRecord {
    public init(row: Row) throws {
        self.init(
            email: row["email"],
            // No non-empty name ever seen for the address: show the
            // address itself, so the listing never shows a blank name.
            name: row["name"] ?? row["email"] ?? "",
            messageCount: row["messageCount"],
            firstDate: (row["firstDate"] as String?).flatMap(Timestamp.date),
            lastDate: (row["lastDate"] as String?).flatMap(Timestamp.date)
        )
    }
}

extension ArchiveStats.YearCount: FetchableRecord {
    public init(row: Row) throws {
        self.init(
            year: row["year"],
            messageCount: row["messageCount"]
        )
    }
}

extension ArchiveStats.SenderCount: FetchableRecord {
    public init(row: Row) throws {
        self.init(
            email: row["email"],
            name: row["name"],
            messageCount: row["messageCount"],
            firstDate: (row["firstDate"] as String?).flatMap(Timestamp.date),
            lastDate: (row["lastDate"] as String?).flatMap(Timestamp.date)
        )
    }
}
