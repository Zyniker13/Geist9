@testable import ArchiveCore
import ArchiveSearch
import GRDB
import XCTest

/// The trigram index (DESIGN 6A, M2.1): substring and partial-word queries
/// ("parts of order numbers") and CJK queries whose segmentation differs
/// from the indexed text. The trigram table lives alongside message_text;
/// exact token matching and ranking stay with message_text. Every test
/// runs in a temporary directory.
final class TrigramSearchTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("geist9-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
    }

    private var archiveURL: URL { tempDir.appendingPathComponent("Test.emailarchive") }

    private func makeStore() throws -> ArchiveStore {
        try ArchiveStore.create(at: archiveURL, appVersion: "0.1.0")
    }

    private func makeMessage(
        subject: String, body: String, from: Recipient? = nil, date: String = "2024-03-05T14:23:05Z"
    ) -> IngestedMessage {
        let record = MessageRecord(
            subject: subject,
            dateSent: Timestamp.date(date),
            dateReceived: Timestamp.date(date),
            messageID: "<\(subject)@example.com>",
            from: from ?? Recipient(name: "Alice", email: "alice@example.com"),
            to: [Recipient(name: "Bob", email: "bob@example.org")]
        )
        let data = Data("""
        From: Alice <alice@example.com>
        To: Bob <bob@example.org>
        Subject: \(subject)
        Message-ID: <\(subject)@example.com>

        \(body)
        """.utf8)
        return IngestedMessage(
            record: record,
            data: data,
            memberships: [Membership(mailbox: "INBOX", uid: 1, flags: [])],
            searchText: SearchText(body: body, quoted: nil)
        )
    }

    private let account = AccountIdentity(email: "alice@example.com", displayName: "Alice", providerKind: "import")

    private func search(_ store: ArchiveStore, _ query: String) throws -> [Int64] {
        try store.search(query).hits.map(\.messageID)
    }

    // MARK: Substring fallback (ranked path, zero exact hits)

    func testSubstringFallbackFindsPartOfOrderNumber() throws {
        // The indexed token is "inv221488"; the query's token "2214" is not
        // in the index vocabulary, so the exact FTS match finds nothing —
        // the trigram fallback must rescue it as a substring.
        let store = try makeStore()
        _ = try store.ingest(
            makeMessage(subject: "Shipping update", body: "Order INV221488 left the depot today"),
            into: account
        )
        XCTAssertEqual(try search(store, "2214"), [1])
        XCTAssertEqual(try search(store, "221488"), [1])
        // The hit is honest about coming from the fallback.
        XCTAssertTrue(try store.search("2214").hits.allSatisfy(\.viaTrigram))
    }

    func testExactMatchPreferredOverFallback() throws {
        // When the exact FTS match has hits, the trigram fallback must not
        // widen the answer: "invoice" should not pull in "invoicing" here.
        let store = try makeStore()
        _ = try store.ingest(
            makeMessage(subject: "Invoice 12", body: "Please review the invoice total"),
            into: account
        )
        _ = try store.ingest(
            makeMessage(subject: "Renewal", body: "Our invoicing system is down today"),
            into: account
        )
        let hits = try search(store, "invoice")
        XCTAssertEqual(hits, [1])
        XCTAssertFalse(try store.search("invoice").hits.allSatisfy(\.viaTrigram))
    }

    func testSubstringFallbackRespectsFieldFilter() throws {
        // subject:2214 must stay inside the subject column; a body-only
        // occurrence never satisfies it.
        let store = try makeStore()
        _ = try store.ingest(
            makeMessage(subject: "Kickoff", body: "Order INV221488 left the depot today"),
            into: account
        )
        _ = try store.ingest(
            makeMessage(subject: "Project PRJ-2214 kickoff", body: "See you there"),
            into: account
        )
        XCTAssertEqual(try search(store, "subject:2214"), [2])
    }

    func testVeryShortTermSkipsFallback() throws {
        // A term shorter than a trigram cannot use the fallback; when it is
        // also no token in the archive, the query honestly returns nothing.
        let store = try makeStore()
        _ = try store.ingest(
            makeMessage(subject: "Status update", body: "The plan anchor details are attached"),
            into: account
        )
        XCTAssertEqual(try search(store, "ab"), [])
    }

    // MARK: CJK queries (segmentation differs between query and text)

    func testCJKQueryFindsTextWhenSegmentationDiffers() throws {
        // "算评审安" spans word boundaries the tokenizers may draw
        // differently in the query and the body; the trigram substring
        // match finds it either way, on both platforms.
        let store = try makeStore()
        _ = try store.ingest(
            makeMessage(
                subject: "预算评审",
                body: "预算评审安排在周四，请准时参加。京东快递单号 77881122 已发货。"
            ),
            into: account
        )
        XCTAssertEqual(try search(store, "算评审安"), [1])
        XCTAssertEqual(try search(store, "快递单号 77881122"), [1])
    }

    func testCJKLeafInsidePredicateQueryUnionsTrigram() throws {
        // A CJK leaf under boolean structure runs in the predicate path,
        // where there is no zero-hit retry — its trigram match must be
        // unioned in eagerly.
        let store = try makeStore()
        _ = try store.ingest(
            makeMessage(
                subject: "预算评审",
                body: "预算评审安排在周四，请准时参加。"
            ),
            into: account
        )
        _ = try store.ingest(
            makeMessage(subject: "预算评审", body: "会议改到周五了。"),
            into: account
        )
        XCTAssertEqual(try search(store, "算评审安"), [1])
        XCTAssertEqual(try search(store, "from:alice@example.com 算评审安"), [1])
        XCTAssertEqual(try search(store, "from:bob@example.org 算评审安"), [])
    }

    func testTrigramTableHoldsFoldedContent() throws {
        // The trigram table mirrors message_text's columns with raw folded
        // text, one row per message keyed by rowid = message.id.
        let store = try makeStore()
        _ = try store.ingest(
            makeMessage(
                subject: "Résumé ÇÑ scan",
                body: "Invoice INV221488 left the depot today"
            ),
            into: account
        )
        let count = try store.db.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM message_trigram WHERE message_trigram MATCH ?",
                arguments: ["\"inv221488\""]
            )
        }
        XCTAssertEqual(count, 1)
        // Content is folded the same way the query pipeline folds input.
        let folded = try store.db.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM message_trigram WHERE message_trigram MATCH ?",
                arguments: ["\"resume\""]
            )
        }
        XCTAssertEqual(folded, 1)
    }

    // MARK: Versioning and backfill

    func testIngestStampsTextVersion() throws {
        let store = try makeStore()
        _ = try store.ingest(
            makeMessage(subject: "Shipping update", body: "Order INV221488 left the depot today"),
            into: account
        )
        let version = try store.db.read { db in
            try Int.fetchOne(db, sql: "SELECT textVersion FROM message WHERE id = 1")
        }
        XCTAssertEqual(version, TextIndexVersion.current)
    }

    func testReingestRestoresStaleTrigram() throws {
        // Re-importing the same bytes after the text pipeline moved forward
        // re-indexes that message (self-heal), without duplicating the row.
        let store = try makeStore()
        let message = makeMessage(subject: "Shipping update", body: "Order INV221488 left the depot today")
        _ = try store.ingest(message, into: account)
        try store.db.write { db in
            try db.execute(sql: "DELETE FROM message_trigram")
            try db.execute(sql: "UPDATE message SET textVersion = NULL")
        }
        XCTAssertEqual(try search(store, "2214"), [])

        let result = try store.ingest(message, into: account)
        XCTAssertEqual(result, .duplicate(messageID: 1))
        XCTAssertEqual(try search(store, "2214"), [1])
        XCTAssertEqual(try store.search("2214").hits.first?.viaTrigram, true)
    }

    func testBackfillUpgradesOutdatedMessages() throws {
        let store = try makeStore()
        _ = try store.ingest(
            makeMessage(subject: "Shipping update", body: "Order INV221488 left the depot today"),
            into: account
        )
        _ = try store.ingest(
            makeMessage(subject: "Nothing here", body: "Completely unrelated words"),
            into: account
        )
        try store.db.write { db in
            try db.execute(sql: "DELETE FROM message_trigram")
            try db.execute(sql: "UPDATE message SET textVersion = NULL")
        }

        let processed = try store.reindexOutdated()
        XCTAssertEqual(processed, 2)
        XCTAssertEqual(try search(store, "2214"), [1])
        // A second pass finds nothing left to do.
        XCTAssertEqual(try store.reindexOutdated(), 0)
    }

    func testMigrationV4ToV5BackfillsTrigram() throws {
        // Simulate an archive written before the trigram index existed:
        // a core-v4 index with a message and its message_text row, the
        // original bytes in content-addressed storage, no trigram table
        // and no message.textVersion column. Opening it must run core-v5,
        // and the backfill must rebuild trigram content from the stored
        // bytes without touching the stored row.
        let dbURL = archiveURL.appendingPathComponent(ArchiveStore.indexName)
        try FileManager.default.createDirectory(
            at: archiveURL, withIntermediateDirectories: true
        )
        let pool = try DatabasePool(path: dbURL.path)
        try IndexSchema.migrator(through: "core-v4").migrate(pool)

        let data = Data("""
        From: Alice <alice@example.com>
        To: Bob <bob@example.org>
        Subject: Kickoff
        Message-ID: <kickoff@example.com>

        Order PRJ-2214 confirmed for Thursday
        """.utf8)
        let hash = MessageHash.sha256(data)
        let fileURL = archiveURL.appendingPathComponent(ArchiveStore.relativePath(for: hash))
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: fileURL)
        try ArchiveManifest(createdAt: Date(), appVersion: "0.1.0")
            .write(to: archiveURL.appendingPathComponent(ArchiveStore.manifestName))

        try pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO message (id, hash, size, subject, normalizedSubject, dateReceived, fromName, fromEmail)
                VALUES (1, ?, ?, 'Kickoff', 'kickoff', '2024-03-05T14:23:05Z', 'Alice', 'alice@example.com')
                """,
                arguments: [hash.bytes, data.count]
            )
            try db.execute(
                sql: """
                INSERT INTO message_text (rowid, subject, from_name, from_addr, recipients, body, quoted, attachments)
                VALUES (1, 'kickoff', 'alice', 'alice@example.com', 'bob', 'order prj 2214 confirmed for thursday', '', '')
                """
            )
        }

        let store = try ArchiveStore.open(at: archiveURL)
        // The stored row survived the migration untouched.
        let row = try store.db.read { db in
            try Row.fetchOne(db, sql: "SELECT hash, size, subject, fromEmail FROM message WHERE id = 1")
        }
        XCTAssertEqual(row?["hash"] as Data?, hash.bytes)
        XCTAssertEqual(row?["size"] as Int?, data.count)
        XCTAssertEqual(row?["subject"] as String?, "Kickoff")

        // The exact index kept working through the migration.
        XCTAssertEqual(try search(store, "2214"), [1])
        // Before the backfill, a pure substring cannot match; after it, it
        // can. "rder prj" spans two tokens, so only the trigram can find it.
        XCTAssertEqual(try search(store, "rder prj"), [])
        XCTAssertEqual(try store.reindexOutdated(), 1)
        // The backfill rebuilt the trigram column from the stored bytes.
        let trigramBody = try store.db.read { db in
            try String.fetchOne(db, sql: "SELECT body FROM message_trigram WHERE rowid = 1")
        }
        XCTAssertEqual(trigramBody, "order prj-2214 confirmed for thursday")
        XCTAssertEqual(try search(store, "rder prj"), [1])
        XCTAssertEqual(try store.reindexOutdated(), 0)
    }

    func testMigrationV5ToV6BackfillsMessageRank() throws {
        // Simulate an archive written before the ranked executor's side
        // table existed: a core-v5 index with two messages — one dated
        // and threaded, one with no dates — and no message_rank table.
        // Opening it must run core-v6 and backfill one rank row per
        // message with exactly the day and threadID ingest would have
        // written, without touching the stored rows.
        let dbURL = archiveURL.appendingPathComponent(ArchiveStore.indexName)
        try FileManager.default.createDirectory(
            at: archiveURL, withIntermediateDirectories: true
        )
        let pool = try DatabasePool(path: dbURL.path)
        try IndexSchema.migrator(through: "core-v5").migrate(pool)

        try ArchiveManifest(createdAt: Date(), appVersion: "0.1.0")
            .write(to: archiveURL.appendingPathComponent(ArchiveStore.manifestName))

        try pool.write { db in
            try db.execute(
                sql: "INSERT INTO thread (id, rootSubject) VALUES (1, 'Kickoff')"
            )
            try db.execute(
                sql: """
                INSERT INTO message (id, hash, size, subject, normalizedSubject, dateReceived, fromName, fromEmail, threadID)
                VALUES (1, X'0102030405060708', 10, 'Kickoff', 'kickoff', '2024-03-05T14:23:05Z', 'Alice', 'alice@example.com', 1)
                """
            )
            try db.execute(
                sql: """
                INSERT INTO message (id, hash, size, subject, normalizedSubject, fromName, fromEmail)
                VALUES (2, X'0807060504030201', 12, 'Undated', 'undated', 'Bob', 'bob@example.org')
                """
            )
            try db.execute(
                sql: """
                INSERT INTO message_text (rowid, subject, from_name, from_addr, recipients, body, quoted, attachments)
                VALUES (1, 'kickoff', 'alice', 'alice@example.com', 'bob', 'order prj 2214 confirmed for thursday', '', '')
                """
            )
            try db.execute(
                sql: """
                INSERT INTO message_text (rowid, subject, from_name, from_addr, recipients, body, quoted, attachments)
                VALUES (2, 'undated', 'bob', 'bob@example.org', 'alice', 'no dates on this one', '', '')
                """
            )
        }

        let store = try ArchiveStore.open(at: archiveURL)
        // The stored rows survived the migration untouched.
        let rows = try store.db.read { db in
            try Row.fetchAll(db, sql: "SELECT id, hash, subject FROM message ORDER BY id")
        }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["subject"] as String?, "Kickoff")
        XCTAssertEqual(rows[1]["subject"] as String?, "Undated")

        // Every message has a rank row, computed by the same expression
        // the ingest path uses: day from the first available date, null
        // when a message has none; threadID copied from the message row.
        let ranks = try store.db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT r.id, r.day, r.threadID,
                       julianday(COALESCE(m.dateSent, m.dateReceived)) AS expectedDay,
                       m.threadID AS expectedThread
                FROM message m JOIN message_rank r ON r.id = m.id
                ORDER BY m.id
                """)
        }
        XCTAssertEqual(ranks.count, 2)
        for rank in ranks {
            XCTAssertEqual(rank["day"] as Double?, rank["expectedDay"] as Double?)
            XCTAssertEqual(rank["threadID"] as Int64?, rank["expectedThread"] as Int64?)
        }
        XCTAssertNotNil(ranks.first?["day"] as Double?)
        XCTAssertNil(ranks.last?["day"] as Double?)
        XCTAssertEqual(ranks.first?["threadID"] as Int64?, 1)

        // Search still resolves through the migrated index.
        XCTAssertEqual(try search(store, "kickoff"), [1])
        XCTAssertEqual(try search(store, "undated"), [2])
    }
}
