// Index schema. core-v1 (DESIGN 6) laid down accounts, mailboxes, messages,
// memberships, labels, threads, addresses, attachments; later milestones
// append their own migrations (search tables in 6A, provider metadata for
// MailSync) — they must never rewrite what an earlier migration recorded.
// Dates are ISO 8601 UTC TEXT so the index is readable by third-party tools
// and TEXT comparison sorts correctly.

import Foundation
import GRDB

public enum IndexSchema {
    /// Matches ArchiveManifest.currentFormatVersion; bump together.
    public static let version = 2

    /// The ordered, named migrations. Kept as a list so tests can build a
    /// database at an older schema version (`migrator(through:)`) and verify
    /// that opening it migrates forward without touching stored rows.
    static let steps: [(name: String, apply: @Sendable (Database) throws -> Void)] = [
        ("core-v1", coreV1),
        ("core-v2", coreV2),
    ]

    /// Migrator applying every step, or only those up to and including
    /// `lastName` (tests use a prefix to simulate an older archive).
    public static func migrator(through lastName: String? = nil) -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        for step in steps {
            migrator.registerMigration(step.name, migrate: step.apply)
            if step.name == lastName { break }
        }
        return migrator
    }

    /// core-v1: accounts, mailboxes, messages, memberships, labels, threads,
    /// addresses, attachments.
    private static func coreV1(_ db: Database) throws {
        try db.create(table: "account") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("email", .text).notNull()
            t.column("displayName", .text).notNull()
            t.column("providerKind", .text).notNull()
            t.uniqueKey(["email", "providerKind"])
        }

        try db.create(table: "mailbox") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("accountID", .integer).notNull().references("account", onDelete: .cascade)
            t.column("name", .text).notNull()
            t.column("delimiter", .text)
            t.column("uidValidity", .integer)
            t.column("role", .text)
            t.uniqueKey(["accountID", "name"])
        }

        try db.create(table: "thread") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("rootSubject", .text)
        }

        try db.create(table: "message") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("hash", .blob).notNull().unique()
            t.column("size", .integer).notNull()
            t.column("subject", .text)
            t.column("normalizedSubject", .text)
            t.column("dateSent", .text).indexed()
            t.column("dateReceived", .text).indexed()
            t.column("messageID", .text).indexed()
            t.column("inReplyTo", .text)
            t.column("referencesIDs", .text)
            t.column("fromName", .text)
            t.column("fromEmail", .text).indexed()
            t.column("listID", .text)
            t.column("threadID", .integer).references("thread", onDelete: .setNull)
        }

        try db.create(table: "message_mailbox") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("messageID", .integer).notNull().references("message", onDelete: .cascade)
            t.column("mailboxID", .integer).notNull().references("mailbox", onDelete: .cascade)
            t.column("uid", .integer)
            t.column("flags", .text)
            t.column("firstSeen", .text).notNull()
            t.column("lastSeen", .text).notNull()
            t.column("removedFromServer", .boolean).notNull().defaults(to: false)
            t.uniqueKey(["messageID", "mailboxID"])
        }
        // Mailbox listings scan by mailbox, not message.
        try db.create(index: "idx_message_mailbox_mailbox", on: "message_mailbox", columns: ["mailboxID", "uid"])

        try db.create(table: "label") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("accountID", .integer).notNull().references("account", onDelete: .cascade)
            t.column("name", .text).notNull()
            t.uniqueKey(["accountID", "name"])
        }

        try db.create(table: "message_label") { t in
            t.column("messageID", .integer).notNull().references("message", onDelete: .cascade)
            t.column("labelID", .integer).notNull().references("label", onDelete: .cascade)
            t.primaryKey(["messageID", "labelID"])
        }

        try db.create(table: "address") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("name", .text)
            t.column("email", .text).notNull()
            t.uniqueKey(["email", "name"])
        }

        try db.create(table: "message_address") { t in
            t.column("messageID", .integer).notNull().references("message", onDelete: .cascade)
            t.column("addressID", .integer).notNull().references("address", onDelete: .cascade)
            // "from", "to", "cc", "bcc", "reply-to"
            t.column("kind", .text).notNull()
            t.primaryKey(["messageID", "addressID", "kind"])
        }
        // Address lookups (find_contacts) scan by address.
        try db.create(index: "idx_message_address_address", on: "message_address", columns: ["addressID"])

        try db.create(table: "attachment") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("messageID", .integer).notNull().references("message", onDelete: .cascade)
            t.column("partIndex", .text).notNull()
            t.column("filename", .text)
            t.column("contentType", .text).notNull()
            t.column("contentID", .text)
            t.column("size", .integer).notNull()
            // Extraction state for the background queue: pending | done | noText | failed
            t.column("textState", .text).notNull().defaults(to: "pending")
            t.column("textVersion", .integer)
            t.uniqueKey(["messageID", "partIndex"])
        }
        try db.create(index: "idx_attachment_filename", on: "attachment", columns: ["filename"])
    }

    /// core-v2: import provenance and provider thread ids (DESIGN 9, M1.10).
    private static func coreV2(_ db: Database) throws {
        try db.alter(table: "message") { t in
            t.add(column: "importSource", .text)
            t.add(column: "providerThreadID", .text)
        }
    }

    public static func openDatabase(at url: URL) throws -> DatabasePool {
        var configuration = Configuration()
        configuration.busyMode = .timeout(10)
        // WAL mode: readers (search, MCP helper) never block the ingest writer.
        configuration.journalMode = .wal
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(path: url.path, configuration: configuration)
        try migrator().migrate(pool)
        return pool
    }
}
