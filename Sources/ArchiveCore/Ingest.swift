// Ingest (DESIGN 6): store bytes, then index the message and its memberships,
// labels, addresses and attachments in ONE transaction. Re-importing the same
// bytes adds nothing twice (content addressing + UNIQUE constraints); a later
// copy in a different mailbox adds only the new membership row.

import ArchiveSearch
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

            // Search index and thread assignment stay in the same
            // transaction as the message row, so search never shows a
            // message the list lacks, and vice versa.
            if isNew {
                try Self.indexSearchText(message, messageRowID: messageRowID, db: db)
            }
            try Self.assignThread(
                message, accountEmail: account.email,
                messageRowID: messageRowID, db: db
            )

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

    // MARK: Search + threading (run inside the ingest transaction)

    /// Writes the pre-tokenized text columns into the FTS5 table (DESIGN 6A).
    /// The rowid is the message row's id, which is what makes MATCH results
    /// joinable to `message` without a mapping table.
    static func indexSearchText(
        _ message: IngestedMessage, messageRowID: Int64, db: Database
    ) throws {
        let search = message.searchText ?? SearchText(body: nil, quoted: nil)
        func tokens(_ text: String?, _ field: TextField) -> String {
            guard let text, !text.isEmpty else { return "" }
            return TokenPipeline.tokens(for: text, field: field).joined(separator: " ")
        }
        var recipients: [String] = []
        for recipient in message.record.to + message.record.cc + message.record.bcc {
            if let name = recipient.name, !name.isEmpty { recipients.append(name) }
            if !recipient.email.isEmpty { recipients.append(recipient.email) }
        }
        let attachmentNames = message.attachments
            .compactMap { (attachment: AttachmentInfo) -> String? in attachment.filename }
            .joined(separator: " ")
        try db.execute(
            sql: """
            INSERT INTO message_text
                (rowid, subject, from_name, from_addr, recipients, body, quoted, attachments)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                messageRowID,
                tokens(message.record.subject, .subject),
                tokens(message.record.from?.name, .sender),
                // The address is stored folded but raw: unicode61 splits it on
                // '@' and '.', which yields exactly the address-aware tokens
                // DESIGN 6A wants, and phrase queries (`from:a@b.c`) reassemble
                // them (same pattern as the FTS5 spike).
                message.record.from.map { TokenPipeline.folded($0.email) } ?? "",
                tokens(recipients.joined(separator: " "), .recipient),
                tokens(search.body, .body),
                tokens(search.quoted, .quoted),
                tokens(attachmentNames, .attachment),
            ]
        )
    }

    /// Joins the message to its thread (DESIGN 7). Order: provider thread id
    /// first (exact), then the parent through References (nearest first) and
    /// In-Reply-To, then the normalized subject; otherwise its own thread.
    static func assignThread(
        _ message: IngestedMessage, accountEmail: String, messageRowID: Int64, db: Database
    ) throws {
        func attach(_ threadID: Int64) throws {
            try db.execute(
                sql: "UPDATE message SET threadID = ? WHERE id = ?",
                arguments: [threadID, messageRowID]
            )
        }

        // 1. Provider thread id, keyed per account: X-GM-THRID values are
        //    only unique within one account, so the key carries the address.
        if let provider = message.providerThreadID?.trimmingCharacters(in: .whitespaces), !provider.isEmpty {
            let key = "\(accountEmail.lowercased())/\(provider.lowercased())"
            if let threadID = try Int64.fetchOne(
                db, sql: "SELECT id FROM thread WHERE providerKey = ?", arguments: [key]
            ) {
                try attach(threadID)
                return
            }
            try attach(Self.createThread(
                subject: message.record.normalizedSubject, providerKey: key, db: db
            ))
            return
        }

        // 2. Parent lookup: the References chain newest first, then
        //    In-Reply-To (which some clients set alone).
        let parents = Array(message.record.references.reversed()) + message.record.inReplyTo
        for parent in parents {
            if let threadID = try Int64.fetchOne(
                db, sql: "SELECT threadID FROM message WHERE messageID = ?",
                arguments: [parent]
            ) {
                try attach(threadID)
                return
            }
        }

        // 3. Same normalized subject joins the existing thread.
        if let subject = message.record.normalizedSubject, !subject.isEmpty {
            if let threadID = try Int64.fetchOne(
                db, sql: """
                SELECT t.id FROM thread t
                JOIN message m ON m.threadID = t.id
                WHERE m.normalizedSubject = ?
                LIMIT 1
                """,
                arguments: [subject]
            ) {
                try attach(threadID)
                return
            }
            try attach(Self.createThread(subject: subject, providerKey: nil, db: db))
            return
        }

        // 4. Nothing to hang it on: its own thread.
        try attach(Self.createThread(subject: nil, providerKey: nil, db: db))
    }

    static func createThread(subject: String?, providerKey: String?, db: Database) throws -> Int64 {
        try db.execute(
            sql: "INSERT INTO thread (rootSubject, providerKey) VALUES (?, ?)",
            arguments: [subject, providerKey]
        )
        return db.lastInsertedRowID
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
