// Ingest (DESIGN 6): store bytes, then index the message and its memberships,
// labels, addresses and attachments in ONE transaction. Re-importing the same
// bytes adds nothing twice (content addressing + UNIQUE constraints); a later
// copy in a different mailbox adds only the new membership row.

import ArchiveSearch
import Foundation
import GRDB

// MARK: Search token precompute (pure CPU, safe to run in parallel)

/// The seven pre-tokenized FTS5 column strings for one message. Computing
/// them is pure CPU with no database access, so batch ingest computes them
/// in parallel before the index transaction and the transaction only inserts.
struct SearchTokens: Sendable {
    var subject = ""
    var fromName = ""
    var fromAddr = ""
    var recipients = ""
    var body = ""
    var quoted = ""
    var attachments = ""

    init() {}

    init(_ message: IngestedMessage) {
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
        self.subject = tokens(message.record.subject, .subject)
        self.fromName = tokens(message.record.from?.name, .sender)
        // The address is stored folded but raw: unicode61 splits it on
        // '@' and '.', which yields exactly the address-aware tokens
        // DESIGN 6A wants, and phrase queries (`from:a@b.c`) reassemble
        // them (same pattern as the FTS5 spike).
        self.fromAddr = message.record.from.map { TokenPipeline.folded($0.email) } ?? ""
        self.recipients = tokens(recipients.joined(separator: " "), .recipient)
        self.body = tokens(search.body, .body)
        self.quoted = tokens(search.quoted, .quoted)
        self.attachments = tokens(attachmentNames, .attachment)
    }
}

extension ArchiveStore {
    /// Ingests one message: content-addressed storage + index rows, atomically.
    ///
    /// The file write happens first and is idempotent; if the process dies
    /// between file and index, scrub finds an unindexed file and a later
    /// re-import re-records it. The index never leads the files.
    @discardableResult
    public func ingest(_ message: IngestedMessage, into account: AccountIdentity, now: Date = Date()) throws -> IngestResult {
        try ingest([message], into: account, now: now)[0]
    }

    /// Ingests a batch of messages with the same durability contract as the
    /// single-message form: every file is fsync'd before its rename, every
    /// touched directory is fsync'd, and the index rows commit only after all
    /// files are durable — so the index never leads the files, and a crash
    /// anywhere leaves only complete files and (at most) an unindexed set that
    /// scrub and rebuildIndex repair.
    ///
    /// The work is restructured for throughput, not for weaker durability:
    /// file writes run in parallel (fsync latency is wait time), the directory
    /// flushes are gathered into one pass, and the whole batch's index rows
    /// commit in ONE transaction. Messages whose exact bytes are already
    /// stored, or repeated inside the batch, cost only index lookups.
    ///
    /// Returns one result per input, in input order.
    @discardableResult
    public func ingest(_ messages: [IngestedMessage], into account: AccountIdentity, now: Date = Date()) throws -> [IngestResult] {
        let nowString = Timestamp.string(now)

        // Stage 1: hash every message, dedupe within the batch (first
        // occurrence wins), and skip files already stored. All cheap, so it
        // stays sequential and gives the parallel stage a plain list.
        var firstIndexByHash: [String: Int] = [:]
        var ordered: [(message: IngestedMessage, url: URL, hash: MessageHash)] = []
        var resultSlotByInput: [Int] = Array(repeating: -1, count: messages.count)
        for (index, message) in messages.enumerated() {
            let hash = MessageHash.sha256(message.data)
            if let slot = firstIndexByHash[hash.hex] {
                resultSlotByInput[index] = slot
                continue
            }
            firstIndexByHash[hash.hex] = ordered.count
            resultSlotByInput[index] = ordered.count
            ordered.append((message, fileURL(for: hash), hash))
        }

        // Stage 2: durable file writes in parallel. Each write fsyncs its own
        // file before the rename (the bytes are complete on disk the moment
        // the name appears); directory flushes are deferred to stage 3 so a
        // batch pays one flush per directory, not per file. A failure here
        // aborts the batch; files already renamed stay — they are complete
        // and merely unindexed until a re-import records them.
        var renames: [(data: Data, url: URL)] = []
        renames.reserveCapacity(ordered.count)
        for item in ordered where !FileManager.default.fileExists(atPath: item.url.path) {
            renames.append((item.message.data, item.url))
        }
        try runParallel(renames.count) { index in
            try AtomicWrite.writeDurableFile(renames[index].data, to: renames[index].url)
        }
        Self.crashHook?("files-written")

        // Stage 1.5: compute the search-index tokens in parallel (pure CPU);
        // the index transaction then only inserts the precomputed columns.
        var tokenBuffer = [SearchTokens](repeating: SearchTokens(), count: ordered.count)
        try tokenBuffer.withUnsafeMutableBufferPointer { buffer -> Void in
            let base = buffer.baseAddress!
            try runParallel(ordered.count) { index in
                base[index] = SearchTokens(ordered[index].message)
            }
        }

        // Stage 3: flush every touched directory once, so all of this batch's
        // renames are durable before any index row commits.
        var touchedDirectories = Set<String>()
        for rename in renames {
            touchedDirectories.insert(rename.url.deletingLastPathComponent().path)
        }
        let directoryPaths = Array(touchedDirectories)
        try runParallel(directoryPaths.count) { index in
            try AtomicWrite.syncDirectory(atPath: directoryPaths[index])
        }
        Self.crashHook?("dir-fsync")

        // Stage 4: index rows for the whole batch in ONE transaction.
        let results: [IngestResult] = try db.write { db in
            let accountID = try Self.getOrCreateAccount(account, db: db)
            var slotResults: [IngestResult] = []
            slotResults.reserveCapacity(ordered.count)
            // Transaction-local caches: the same mailbox/address/label names
            // repeat constantly in a real batch, so resolve each name once.
            var mailboxCache: [String: Int64] = [:]
            var labelCache: [String: Int64] = [:]
            var addressCache: [String: Int64] = [:]
            for (slotIndex, item) in ordered.enumerated() {
                slotResults.append(try Self.insertRows(
                    item.message, hash: item.hash, tokens: tokenBuffer[slotIndex],
                    accountID: accountID, db: db, nowString: nowString,
                    accountEmail: account.email,
                    mailboxCache: &mailboxCache,
                    labelCache: &labelCache,
                    addressCache: &addressCache
                ))
            }
            return slotResults
        }
        Self.crashHook?("index-commit")

        // Expand slots back to one result per input message. A message whose
        // bytes repeat later in the batch reports .duplicate with the row id
        // the first occurrence got; insertRows already reports .duplicate for
        // bytes that existed before this batch.
        var expanded: [IngestResult] = []
        expanded.reserveCapacity(messages.count)
        for index in messages.indices {
            let slot = resultSlotByInput[index]
            let slotResult = results[slot]
            if index != firstInputIndex(bySlot: slot, slotMap: resultSlotByInput) {
                if case .created(let id) = slotResult {
                    expanded.append(.duplicate(messageID: id))
                    continue
                }
            }
            expanded.append(slotResult)
        }
        return expanded
    }

    /// The first input index that maps to `slot` — i.e. the occurrence whose
    /// result came from insertRows rather than a same-batch repeat.
    private func firstInputIndex(bySlot slot: Int, slotMap: [Int]) -> Int {
        slotMap.firstIndex(of: slot) ?? slot
    }

    /// Inserts one message's index rows (run inside the ingest transaction):
    /// the message row, search index, thread assignment, memberships, labels,
    /// addresses and attachments. Returns .created for new bytes, .duplicate
    /// when the exact bytes were already stored. The name caches are
    /// transaction-local and single-threaded (db.write serializes callers).
    static func insertRows(
        _ message: IngestedMessage, hash: MessageHash, tokens: SearchTokens,
        accountID: Int64, db: Database, nowString: String, accountEmail: String,
        mailboxCache: inout [String: Int64],
        labelCache: inout [String: Int64],
        addressCache: inout [String: Int64]
    ) throws -> IngestResult {
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
                try Self.indexSearchText(tokens, messageRowID: messageRowID, db: db)
            }
            try Self.assignThread(
                message, accountEmail: accountEmail,
                messageRowID: messageRowID, db: db
            )

            for membership in message.memberships {
                let mailboxKey = "\(accountID)/\(membership.mailbox)"
                let mailboxID: Int64
                if let cached = mailboxCache[mailboxKey] {
                    mailboxID = cached
                } else {
                    mailboxID = try Self.getOrCreateMailbox(
                        accountID: accountID, name: membership.mailbox, db: db
                    )
                    mailboxCache[mailboxKey] = mailboxID
                }
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
                let labelKey = "\(accountID)/\(label.name)"
                let labelID: Int64
                if let cached = labelCache[labelKey] {
                    labelID = cached
                } else {
                    labelID = try Self.getOrCreateLabel(accountID: accountID, name: label.name, db: db)
                    labelCache[labelKey] = labelID
                }
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
                    // Key distinguishes a nil name from an empty one (NUL
                    // marker never appears in real addresses).
                    let addressKey = recipient.email.lowercased() + "|" + (recipient.name ?? "\u{0}")
                    let addressID: Int64
                    if let cached = addressCache[addressKey] {
                        addressID = cached
                    } else {
                        addressID = try Self.getOrCreateAddress(recipient, db: db)
                        addressCache[addressKey] = addressID
                    }
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

    // MARK: Search + threading (run inside the ingest transaction)

    /// Writes the pre-tokenized text columns into the FTS5 table (DESIGN 6A).
    /// The rowid is the message row's id, which is what makes MATCH results
    /// joinable to `message` without a mapping table. Tokenization happened
    /// earlier (parallel in batch ingest); this only inserts.
    static func indexSearchText(
        _ tokens: SearchTokens, messageRowID: Int64, db: Database
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO message_text
                (rowid, subject, from_name, from_addr, recipients, body, quoted, attachments)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                messageRowID,
                tokens.subject,
                tokens.fromName,
                tokens.fromAddr,
                tokens.recipients,
                tokens.body,
                tokens.quoted,
                tokens.attachments,
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

extension ArchiveStore {
    /// Runs `body(index)` for `count` indices on the cooperative global
    /// concurrent queue and waits for all of them. Used by batch ingest to
    /// overlap fsync latency across files; the per-index work is independent
    /// and idempotent, so no ordering is assumed. The first error thrown wins;
    /// the rest finish (their writes are harmless), then the error rethrows.
    func runParallel(_ count: Int, body: @escaping (Int) throws -> Void) throws {
        guard count > 1 else {
            if count == 1 { try body(0) }
            return
        }
        final class ErrorBox: @unchecked Sendable {
            private let lock = NSLock()
            private var error: Error?
            func set(_ error: Error) {
                lock.lock()
                if self.error == nil { self.error = error }
                lock.unlock()
            }
            var firstError: Error? {
                lock.lock()
                defer { lock.unlock() }
                return error
            }
        }
        let box = ErrorBox()
        DispatchQueue.concurrentPerform(iterations: count) { index in
            do {
                try body(index)
            } catch {
                box.set(error)
            }
        }
        if let error = box.firstError {
            throw error
        }
    }
}
