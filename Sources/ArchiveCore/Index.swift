// Index schema. core-v1 (DESIGN 6) laid down accounts, mailboxes, messages,
// memberships, labels, threads, addresses, attachments; later milestones
// append their own migrations (search tables in 6A, provider metadata for
// MailSync) — they must never rewrite what an earlier migration recorded.
// Dates are ISO 8601 UTC TEXT so the index is readable by third-party tools
// and TEXT comparison sorts correctly.

import Foundation
import GRDB

public enum IndexSchema {
    /// The index schema has its own version, applied by the ordered
    /// migrations below. It is independent of ArchiveManifest's archive
    /// format version, which tracks the on-disk file layout contract
    /// (docs/ARCHIVE-FORMAT.md): migrations make old indexes openable
    /// without any change to the stored files.
    public static let version = 12

    /// The ordered, named migrations. Kept as a list so tests can build a
    /// database at an older schema version (`migrator(through:)`) and verify
    /// that opening it migrates forward without touching stored rows.
    static let steps: [(name: String, apply: @Sendable (Database) throws -> Void)] = [
        ("core-v1", coreV1),
        ("core-v2", coreV2),
        ("core-v3", coreV3),
        ("core-v4", coreV4),
        ("core-v5", coreV5),
        ("core-v6", coreV6),
        ("core-v7", coreV7),
        ("core-v8", coreV8),
        ("core-v9", coreV9),
        ("core-v10", coreV10),
        ("core-v11", coreV11),
        ("core-v12", coreV12),
        ("core-v13", coreV13),
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

    /// core-v3: the search index (DESIGN 6A). The FTS5 table holds the
    /// pre-tokenized text columns; its rowid is `message.id`, so ingest writes
    /// the token stream in the same transaction as the message row. Column
    /// Column order matches the BM25 weight vector used at query time:
    /// subject(12) from_name(8) from_addr(6) recipients(5) body(1)
    /// quoted(0.4) attachments(0.3).
    private static func coreV3(_ db: Database) throws {
        // Provider thread identity is keyed per account (X-GM-THRID values are
        // only unique within one account), so the stored key is account + id.
        try db.alter(table: "thread") { t in
            t.add(column: "providerKey", .text)
        }
        try db.execute(sql: """
            CREATE VIRTUAL TABLE IF NOT EXISTS message_text USING fts5(
                subject, from_name, from_addr, recipients, body, quoted, attachments,
                tokenize = 'unicode61'
            )
            """)
        // Thread and subject lookups the query executor and threading rely on.
        try db.create(index: "idx_message_normsubject", on: "message", columns: ["normalizedSubject"])
        try db.create(index: "idx_message_thread", on: "message", columns: ["threadID"])
        try db.create(index: "idx_message_provthread", on: "message", columns: ["providerThreadID"])
    }

    /// core-v4: saved searches (DESIGN 12). A saved search is a stored,
    /// named query the person saved; opening it runs the query live over
    /// the current index, so it stays current as mail arrives. Saved
    /// searches never touch message rows.
    private static func coreV4(_ db: Database) throws {
        try db.create(table: "saved_search") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("name", .text).notNull()
            t.column("query", .text).notNull()
            t.column("createdAt", .text).notNull()
            t.uniqueKey(["name"])
        }
    }

    /// core-v5: the trigram index (DESIGN 6A, M2.1) and the text pipeline
    /// version column. message_trigram holds the same seven columns as
    /// message_text but with raw folded text under the FTS5 trigram
    /// tokenizer, so substring and partial-word queries and CJK queries
    /// whose segmentation differs from the indexed text still find
    /// messages. message.textVersion records which text pipeline version
    /// indexed each row; rows older than the current version are re-indexed
    /// from the stored bytes by the backfill queue, never by rewriting
    /// stored files. Existing rows get no trigram content until the
    /// backfill runs (reindexOutdated).
    private static func coreV5(_ db: Database) throws {
        try db.execute(
            sql: """
            CREATE VIRTUAL TABLE IF NOT EXISTS message_trigram USING fts5(
                subject, from_name, from_addr, recipients, body, quoted, attachments,
                tokenize = 'trigram'
            )
            """
        )
        try db.alter(table: "message") { t in
            t.add(column: "textVersion", .integer)
        }
    }

    /// core-v6: the message_rank side table (DESIGN 6A, M2.2). One narrow
    /// row per message holding just the two columns the ranked executor
    /// sorts on — the threadID and the recency day — so ranked queries
    /// join a three-column table by primary key instead of the wide
    /// message row, and bind "now" as a parameter instead of re-parsing
    /// every matched message's date per query. Ingest writes the row in
    /// the same transaction as the message; this backfill covers archives
    /// created before v6. The expression matches the one ingest uses, so
    /// both paths compute the same day.
    private static func coreV6(_ db: Database) throws {
        try db.create(table: "message_rank") { t in
            t.column("id", .integer).notNull().primaryKey().references("message", onDelete: .cascade)
            t.column("threadID", .integer).references("thread", onDelete: .setNull)
            t.column("day", .double)
        }
        try db.execute(sql: """
            INSERT INTO message_rank (id, threadID, day)
            SELECT id, threadID, julianday(COALESCE(dateSent, dateReceived))
            FROM message
            """)
    }

    /// core-v7: the as-you-type vocabulary tables (decision 0025). The
    /// first_letter table holds, per leading letter, the total document
    /// frequency of every term starting with that letter — the match-set
    /// size the full ranked search gates on for a one-character prefix.
    /// first_letter_terms holds the top-N terms per letter (by document
    /// frequency) so the first keystroke returns completions from a small
    /// indexed table instead of scanning the live FTS5 vocabulary. Both are
    /// rebuilt from the current FTS5 vocabulary at the end of an import and
    /// by the backfill; they never touch stored message rows.
    private static func coreV7(_ db: Database) throws {
        try db.create(table: "first_letter") { t in
            t.column("letter", .text).notNull().primaryKey()
            t.column("total_doc", .integer).notNull().defaults(to: 0)
        }
        try db.create(table: "first_letter_terms") { t in
            t.column("letter", .text).notNull()
            t.column("ord", .integer).notNull()
            t.column("term", .text).notNull()
            t.column("doc", .integer).notNull()
            t.primaryKey(["letter", "ord"])
        }
        // Populate from the current vocabulary right away: an upgraded
        // archive answers the first keystroke without waiting for the next
        // import or backfill (decision 0025).
        try Vocabulary.rebuildFirstLetterTable(in: db)
    }

    /// core-v8: the stem columns (decision 0026). Snowball stems cannot be
    /// interleaved into the original token columns without breaking phrase
    /// adjacency — a body holding "running budgets" would be indexed as
    /// "running run budgets budget", and the phrase "running budgets" would
    /// stop matching. So the stems live in three extra FTS5 columns that
    /// mirror subject, body, and quoted. The original columns keep the
    /// folded token stream exactly, so phrases and exact matches stay
    /// adjacent; the stem columns give term recall. FTS5 tables cannot be
    /// widened in place, so the table is rebuilt: a wider copy is created,
    /// the original seven columns are copied row for row (rowid preserved),
    /// and the copy is renamed over the original. The stem columns are left
    /// empty here; the text pipeline version bump (TextIndexVersion.v3)
    /// makes the backfill queue re-index every row from the stored bytes and
    /// populate them. No stored message bytes are touched.
    private static func coreV8(_ db: Database) throws {
        try db.execute(sql: """
            CREATE VIRTUAL TABLE message_text_new USING fts5(
                subject, from_name, from_addr, recipients, body, quoted, attachments,
                subject_stem, body_stem, quoted_stem,
                tokenize = 'unicode61'
            )
            """)
        try db.execute(sql: """
            INSERT INTO message_text_new(
                rowid, subject, from_name, from_addr, recipients, body, quoted, attachments
            )
            SELECT rowid, subject, from_name, from_addr, recipients, body, quoted, attachments
            FROM message_text
            """)
        try db.execute(sql: "DROP TABLE message_text")
        try db.execute(sql: "ALTER TABLE message_text_new RENAME TO message_text")
    }

    /// core-v9: the persistent vocabulary table (decision 0027). The live
    /// fts5vocab range scan served 2+-character completions and the
    /// match-set gate until now, but it walks every FTS segment's b-tree:
    /// 60 ms at one million messages (35 segments), against the 50 ms
    /// keystroke budget. The persistent table is keyed on the term, so the
    /// same range query is a single b-tree walk. It is populated here from
    /// the current FTS5 vocabulary, then kept exact incrementally: ingest
    /// applies per-message term deltas in the same transaction that writes
    /// the message_text rows (decision 0027), and the import/reindex
    /// refresh rebuilds it from the live FTS5 vocabulary. No stored message
    /// bytes are touched.
    private static func coreV9(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE vocabulary(term TEXT PRIMARY KEY, doc INTEGER NOT NULL) WITHOUT ROWID
            """)
        try Vocabulary.rebuildAll(in: db)
    }

    /// core-v10: the sender-name stem column (decision 0030). Decision 0026
    /// stemmed subject, body, and quoted; sender display names kept only
    /// their exact folded tokens, so a query form could not reach a
    /// sender's morphology ("Nordwind Versicherung" could not find a
    /// sender named "Nordwind Versicherungen"). FTS5 tables cannot be
    /// widened in place: a wider copy is created, all ten existing columns
    /// are copied row for row (rowid preserved), and the copy is renamed
    /// over the original. The new column stays empty here; the text
    /// pipeline version bump (TextIndexVersion.v5) makes the backfill
    /// re-index every row from the stored bytes and populate it. No stored
    /// message bytes are touched.
    private static func coreV10(_ db: Database) throws {
        try db.execute(sql: """
            CREATE VIRTUAL TABLE message_text_new USING fts5(
                subject, from_name, from_addr, recipients, body, quoted, attachments,
                subject_stem, body_stem, quoted_stem, from_name_stem,
                tokenize = 'unicode61'
            )
            """)
        try db.execute(sql: """
            INSERT INTO message_text_new(
                rowid, subject, from_name, from_addr, recipients, body, quoted, attachments,
                subject_stem, body_stem, quoted_stem
            )
            SELECT rowid, subject, from_name, from_addr, recipients, body, quoted, attachments,
                   subject_stem, body_stem, quoted_stem
            FROM message_text
            """)
        try db.execute(sql: "DROP TABLE message_text")
        try db.execute(sql: "ALTER TABLE message_text_new RENAME TO message_text")
    }

    /// core-v11: the entity store (DESIGN 6A, M2). Entities recognized at
    /// ingest — the first kind is amounts and currencies — live in their own
    /// relational table so numeric comparisons (`amount:>100`) can run as
    /// plain SQL EXISTS predicates alongside the FTS5 text match. Rows
    /// cascade with their message; the text pipeline version bump
    /// (TextIndexVersion.v6) makes the backfill re-index older rows from
    /// their stored bytes to populate the table. No stored message bytes
    /// are touched.
    private static func coreV11(_ db: Database) throws {
        try db.create(table: "message_entity") { t in
            t.column("messageID", .integer).notNull().references("message", onDelete: .cascade)
            t.column("kind", .text).notNull()
            t.column("value", .text).notNull()
            t.column("normalized", .double).notNull()
            t.column("currency", .text)
        }
        try db.create(
            index: "message_entity_lookup", on: "message_entity", columns: ["kind", "normalized"]
        )
        try db.create(
            index: "message_entity_message", on: "message_entity", columns: ["messageID"]
        )
    }

    /// core-v12: the semantic-search vector index (decision 0045).
    /// Vectors are little-endian binary16 (2 bytes per dimension); `dim` is
    /// per model, one dimension per model keeps every cosine well-defined.
    private static func coreV12(_ db: Database) throws {
        try db.create(table: "message_embedding") { t in
            t.column("id", .integer)
                .notNull()
                .primaryKey()
                .references("message", onDelete: .cascade)
            t.column("model", .text).notNull()
            t.column("dim", .integer).notNull()
            t.column("vector", .blob).notNull()
        }
    }

    /// core-v13: message_embedding's primary key becomes (id, model). Under
    /// core-v12 the key was id alone, so a second model's backfill overwrote
    /// the first model's rows — models must coexist, not clobber each other.
    /// The row data carries over unchanged; deletion still cascades.
    private static func coreV13(_ db: Database) throws {
        try db.create(table: "message_embedding_rebuilt") { t in
            t.column("id", .integer)
                .notNull()
                .references("message", onDelete: .cascade)
            t.column("model", .text).notNull()
            t.column("dim", .integer).notNull()
            t.column("vector", .blob).notNull()
            t.primaryKey(["id", "model"])
        }
        try db.execute(
            sql: """
            INSERT INTO message_embedding_rebuilt (id, model, dim, vector)
            SELECT id, model, dim, vector FROM message_embedding
            """
        )
        try db.drop(table: "message_embedding")
        try db.rename(table: "message_embedding_rebuilt", to: "message_embedding")
    }

    public static func openDatabase(at url: URL) throws -> DatabasePool {
        var configuration = Configuration()
        configuration.busyMode = .timeout(10)
        // WAL mode: readers (search, MCP helper) never block the ingest writer.
        configuration.journalMode = .wal
        configuration.foreignKeysEnabled = true
        // Memory-map the index file in every connection. The semantic scan
        // streams ~0.8 KB of blob per message; with the default 0 window each
        // page crosses the SQLite page cache twice per read, and at one
        // million vectors that dominates the scan budget (measured ~180 ms
        // vs ~330 ms fetch time on 1M x 384 float16). Read-only mapping; the
        // WAL commit path is untouched.
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA mmap_size = 1073741824")
        }
        let pool = try DatabasePool(path: url.path, configuration: configuration)
        try migrator().migrate(pool)
        return pool
    }
}
