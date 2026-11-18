// Ingest (DESIGN 6): store bytes, then index the message and its memberships,
// labels, addresses and attachments in ONE transaction. Re-importing the same
// bytes adds nothing twice (content addressing + UNIQUE constraints); a later
// copy in a different mailbox adds only the new membership row.

import Foundation
import GRDB

extension ArchiveStore {
    /// Ingests one message: content-addressed storage + index rows, atomically.
    ///
    /// The file write happens first and is idempotent; if the process dies
    /// between file and index, scrub finds an unindexed file and a later
    /// re-import re-records it. The index never leads the files.
    @discardableResult
    public func ingest(_ message: IngestedMessage, into account: AccountIdentity, now: Date = Date()) throws -> IngestResult {
        let hash = try putMessage(message.data)
        let nowString = Timestamp.string(now)

        let result: IngestResult = try db.write { db in
            let accountID = try Self.getOrCreateAccount(account, db: db)

            var messageID = try Int64.fetchOne(
                db, sql: "SELECT id FROM message WHERE hash = ?", arguments: [hash.bytes]
            )
            let isNew = messageID == nil
            if messageID == nil {
                try db.execute(
                    sql: """
                    INSERT INTO message
                        (hash, size, subject, normalizedSubject, dateSent, dateReceived,
                         messageID, inReplyTo, referencesIDs, fromName, fromEmail, listID,
                         importSource, providerThreadID)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        hash.bytes,
                        message.data.count,
                        message.record.subject,
                        message.record.normalizedSubject,
                        message.record.dateSent.map(Timestamp.string),
                        message.record.dateReceived.map(Timestamp.string),
                        message.record.messageID,
                        Self.joinedIDs(message.record.inReplyTo),
                        Self.joinedIDs(message.record.references),
                        message.record.from?.name,
                        message.record.from?.email,
                        message.record.listID,
                        message.importSource,
                        message.providerThreadID,
                    ]
                )
                messageID = db.lastInsertedRowID
            }
            let messageRowID = messageID!

            for membership in message.memberships {
                let mailboxID = try Self.getOrCreateMailbox(
                    accountID: accountID, name: membership.mailbox, db: db
                )
                // Merge flags: a re-fetch may carry more keywords than before.
                let existingFlags = try String.fetchOne(
                    db, sql: "SELECT flags FROM message_mailbox WHERE messageID = ? AND mailboxID = ?",
                    arguments: [messageRowID, mailboxID]
                )
                let flags = Self.normalizedFlags(existingFlags, membership.flags)
                try db.execute(
                    sql: """
                    INSERT INTO message_mailbox
                        (messageID, mailboxID, uid, flags, firstSeen, lastSeen, removedFromServer)
                    VALUES (?, ?, ?, ?, ?, ?, 0)
                    ON CONFLICT(messageID, mailboxID) DO UPDATE SET
                        uid = excluded.uid,
                        flags = excluded.flags,
                        lastSeen = excluded.lastSeen
                    """,
                    arguments: [messageRowID, mailboxID, membership.uid, flags, nowString, nowString]
                )
            }

            for label in message.labels {
                let labelID = try Self.getOrCreateLabel(accountID: accountID, name: label.name, db: db)
                try db.execute(
                    sql: "INSERT OR IGNORE INTO message_label (messageID, labelID) VALUES (?, ?)",
                    arguments: [messageRowID, labelID]
                )
            }

            let kinds: [(String, [Recipient])] = [
                ("from", message.record.from.map { [$0] } ?? []),
                ("to", message.record.to),
                ("cc", message.record.cc),
                ("bcc", message.record.bcc),
                ("reply-to", message.record.replyTo),
            ]
            for (kind, recipients) in kinds {
                for recipient in recipients {
                    let addressID = try Self.getOrCreateAddress(recipient, db: db)
                    try db.execute(
                        sql: "INSERT OR IGNORE INTO message_address (messageID, addressID, kind) VALUES (?, ?, ?)",
                        arguments: [messageRowID, addressID, kind]
                    )
                }
            }

            for attachment in message.attachments {
                try db.execute(
                    sql: """
                    INSERT INTO attachment
                        (messageID, partIndex, filename, contentType, contentID, size, textState)
                    VALUES (?, ?, ?, ?, ?, ?, 'pending')
                    ON CONFLICT(messageID, partIndex) DO UPDATE SET
                        filename = excluded.filename,
                        contentType = excluded.contentType,
                        contentID = excluded.contentID,
                        size = excluded.size
                    """,
                    arguments: [
                        messageRowID,
                        attachment.partIndex,
                        attachment.filename,
                        attachment.contentType,
                        attachment.contentID,
                        attachment.size,
                    ]
                )
            }

            return isNew ? .created(messageID: messageRowID) : .duplicate(messageID: messageRowID)
        }
        return result
    }

    // MARK: Helpers (static, db passed in)

    static func getOrCreateAccount(_ identity: AccountIdentity, db: Database) throws -> Int64 {
        let email = identity.email.lowercased()
        if let id = try Int64.fetchOne(
            db, sql: "SELECT id FROM account WHERE email = ? AND providerKind = ?",
            arguments: [email, identity.providerKind]
        ) { return id }
        try db.execute(
            sql: "INSERT INTO account (email, displayName, providerKind) VALUES (?, ?, ?)",
            arguments: [email, identity.displayName, identity.providerKind]
        )
        return db.lastInsertedRowID
    }

    static func getOrCreateMailbox(accountID: Int64, name: String, db: Database) throws -> Int64 {
        if let id = try Int64.fetchOne(
            db, sql: "SELECT id FROM mailbox WHERE accountID = ? AND name = ?",
            arguments: [accountID, name]
        ) { return id }
        try db.execute(
            sql: "INSERT INTO mailbox (accountID, name, role) VALUES (?, ?, ?)",
            arguments: [accountID, name, Self.role(for: name)]
        )
        return db.lastInsertedRowID
    }

    static func getOrCreateLabel(accountID: Int64, name: String, db: Database) throws -> Int64 {
        if let id = try Int64.fetchOne(
            db, sql: "SELECT id FROM label WHERE accountID = ? AND name = ?",
            arguments: [accountID, name]
        ) { return id }
        try db.execute(
            sql: "INSERT INTO label (accountID, name) VALUES (?, ?)",
            arguments: [accountID, name]
        )
        return db.lastInsertedRowID
    }

    static func getOrCreateAddress(_ recipient: Recipient, db: Database) throws -> Int64 {
        let email = recipient.email.lowercased()
        if let id = try Int64.fetchOne(
            db, sql: "SELECT id FROM address WHERE email = ? AND name IS ?",
            arguments: [email, recipient.name]
        ) { return id }
        try db.execute(
            sql: "INSERT INTO address (name, email) VALUES (?, ?)",
            arguments: [recipient.name, email]
        )
        return db.lastInsertedRowID
    }

    /// Flags normalized: lower-case, trimmed, de-duplicated, stable order.
    static func normalizedFlags(_ existing: String?, _ additional: [String]) -> String {
        var seen = Set<String>()
        var order = [String]()
        for flag in (existing?.split(separator: " ").map(String.init) ?? []) + additional {
            let lowered = flag.lowercased()
            if !lowered.isEmpty, seen.insert(lowered).inserted {
                order.append(lowered)
            }
        }
        return order.joined(separator: " ")
    }

    static func joinedIDs(_ ids: [String]) -> String? {
        ids.isEmpty ? nil : ids.joined(separator: " ")
    }

    /// Coarse mailbox role from its name; refined per-provider in MailSync.
    static func role(for name: String) -> String? {
        let lowered = name.lowercased()
        let leaf = lowered.split(separator: "/").last.map(String.init) ?? lowered
        switch leaf {
        case "inbox": return "inbox"
        case "sent", "sent messages", "sent items": return "sent"
        case "drafts": return "drafts"
        case "trash", "deleted messages", "deleted items": return "trash"
        case "junk", "spam", "junk e-mail": return "junk"
        case "archive", "all mail": return "archive"
        default: return nil
        }
    }
}
