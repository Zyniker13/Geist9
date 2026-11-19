@testable import ArchiveCore
import ArchiveSearch
import GRDB
import XCTest

/// The persistent vocabulary table (decision 0027): the table mirrors the
/// FTS5 index's term set exactly, at every entry point that writes the
/// index — the core-v9 migration, incremental ingest, duplicate ingest,
/// and the reindex backfill. The stored message rows and stored bytes are
/// never touched by any of it. Every test runs in a temporary directory.
final class VocabularyTableTests: XCTestCase {
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

    private let account = AccountIdentity(email: "alice@example.com", displayName: "Alice", providerKind: "import")

    private func makeMessage(
        subject: String,
        body: String,
        from: Recipient? = nil,
        date: String = "2024-03-05T14:23:05Z"
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

    private func ingest(_ store: ArchiveStore, _ messages: [IngestedMessage]) throws {
        for message in messages {
            _ = try store.ingest(message, into: account)
        }
    }

    /// Reads the live FTS5 term set through a temporary fts5vocab table —
    /// the ground truth the vocabulary table must mirror.
    private func liveVocabulary(_ store: ArchiveStore) throws -> [String: Int] {
        try store.db.read { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS temp._bcon_vocab \
                USING fts5vocab(main, 'message_text', 'row')
                """)
            let rows = try Row.fetchAll(db, sql: "SELECT term, doc FROM temp._bcon_vocab")
            var terms: [String: Int] = [:]
            for row in rows {
                terms[row["term"] as String] = row["doc"] as Int
            }
            try db.execute(sql: "DROP TABLE temp._bcon_vocab")
            return terms
        }
    }

    private func vocabularyTable(_ store: ArchiveStore) throws -> [String: Int] {
        try store.db.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT term, doc FROM vocabulary")
            var terms: [String: Int] = [:]
            for row in rows {
                terms[row["term"] as String] = row["doc"] as Int
            }
            return terms
        }
    }

    // MARK: Exactness at every entry point

    func testVocabularyMatchesFts5vocabAfterIngestWithoutAnyRebuild() throws {
        // The persistent table must be exact right after ingest: the ingest
        // transaction applies per-message deltas (decision 0027), so no
        // import-end rebuild is needed for 2+-character completions.
        let store = try makeStore()
        try ingest(store, [
            makeMessage(subject: "Budget kickoff", body: "The kickoff meeting starts Monday"),
            makeMessage(subject: "Zebra fish", body: "Nothing to do with it"),
        ])
        let live = try liveVocabulary(store)
        XCTAssertFalse(live.isEmpty)
        XCTAssertEqual(try vocabularyTable(store), live)
    }

    func testVocabularyDocCountsAreExactForOverlapAndDuplicates() throws {
        let store = try makeStore()
        let first = makeMessage(subject: "Budget kickoff", body: "The kickoff meeting starts Monday")
        let second = makeMessage(subject: "Lunch order", body: "Kickoff slides attached")
        try ingest(store, [first, second])
        // "budget" is held only by the first message; "kickoff" by both.
        XCTAssertEqual(try vocabularyTable(store)["budget"], 1)
        XCTAssertEqual(try vocabularyTable(store)["kickoff"], 2)
        // Re-ingesting the same bytes is a duplicate: the term counts must
        // not grow, and the second message's unique terms stay at one doc.
        try ingest(store, [first])
        XCTAssertEqual(try vocabularyTable(store)["budget"], 1)
        XCTAssertEqual(try vocabularyTable(store)["kickoff"], 2)
        XCTAssertEqual(try vocabularyTable(store)["slides"], 1)
        XCTAssertEqual(try vocabularyTable(store), try liveVocabulary(store))
    }

    func testReindexDeltaRemovesTermsAndCountsOverlapOnce() throws {
        let store = try makeStore()
        let message = makeMessage(subject: "Budget kickoff", body: "The kickoff meeting starts Monday")
        try ingest(store, [message])
        // Simulate a row written by an older text pipeline: the row's token
        // stream differs from what the current pipeline produces, so the
        // backfill must both drop and add terms (decision 0027: the delta
        // is read from the old row before the rewrite).
        try store.db.write { db in
            try db.execute(sql: "UPDATE message SET textVersion = NULL WHERE id = 1")
            try db.execute(
                sql: "UPDATE message_text SET body = 'orphan legacy stale meeting starts' WHERE rowid = 1"
            )
        }
        // The raw FTS mutation bypasses the delta bookkeeping by design:
        // only the reindex path below applies deltas. The table still holds
        // the original terms here.
        let ftsOnly = Set(["orphan", "legacy", "stale"])
        XCTAssertEqual(try vocabularyTable(store), try liveVocabulary(store).filter { !ftsOnly.contains($0.key) })

        // Re-ingesting the same bytes finds the stale version and rebuilds
        // the text tables from the current pipeline.
        try ingest(store, [message])
        // Terms the message no longer holds lost their last document and
        // are gone from the table.
        XCTAssertNil(try vocabularyTable(store)["orphan"])
        XCTAssertNil(try vocabularyTable(store)["legacy"])
        XCTAssertNil(try vocabularyTable(store)["stale"])
        // Terms kept across the rewrite are counted once, not twice.
        XCTAssertEqual(try vocabularyTable(store)["kickoff"], 1)
        XCTAssertEqual(try vocabularyTable(store)["meeting"], 1)
        // Terms regained by the fresh parse are back.
        XCTAssertEqual(try vocabularyTable(store)["budget"], 1)
        XCTAssertEqual(try vocabularyTable(store), try liveVocabulary(store))
    }

    func testVersionlessReingestNeverInflatesCounts() throws {
        let store = try makeStore()
        let message = makeMessage(subject: "Budget kickoff", body: "The kickoff meeting starts Monday")
        try ingest(store, [message])
        try store.db.write { db in
            try db.execute(sql: "UPDATE message SET textVersion = NULL WHERE id = 1")
        }
        // The same bytes re-parsed by the same pipeline hold exactly the
        // same terms: the delta is empty and nothing grows.
        try ingest(store, [message])
        XCTAssertEqual(try vocabularyTable(store)["kickoff"], 1)
        XCTAssertEqual(try vocabularyTable(store), try liveVocabulary(store))
    }

    func testVocabularyDeltasRollBackWithTheirTransaction() throws {
        let store = try makeStore()
        try ingest(store, [makeMessage(subject: "Budget kickoff", body: "The kickoff meeting starts Monday")])
        let before = try vocabularyTable(store)
        // applyDeltas runs inside the ingest transaction; a transaction that
        // fails after the deltas must leave both the vocabulary table and
        // the FTS index unchanged.
        struct Boom: Error {}
        XCTAssertThrowsError(
            try store.db.write { db in
                try Vocabulary.applyDeltas(["orphan": 1], in: db)
                throw Boom()
            }
        )
        XCTAssertEqual(try vocabularyTable(store), before)
        XCTAssertEqual(try vocabularyTable(store), try liveVocabulary(store))
    }

    func testCompleteGateReadsTheVocabularyTable() throws {
        let store = try makeStore()
        let message = makeMessage(subject: "Budget kickoff", body: "The kickoff meeting starts Monday")
        try ingest(store, [message])
        // No import-end rebuild anywhere in this test: the completion query
        // and its match-set gate read the table the ingest deltas keep.
        let result = try store.searchAsYouType("ki")
        XCTAssertEqual(result.completions.map(\.term), ["kickoff"])
        XCTAssertEqual(result.matchSet, 1)
        // A duplicate must not grow the match set.
        try ingest(store, [message])
        XCTAssertEqual(try store.searchAsYouType("ki").matchSet, 1)
    }

    // MARK: The core-v9 migration

    func testMigrationRebuildsVocabularyFromExistingIndex() throws {
        // Simulate an archive written before the vocabulary table existed:
        // a core-v8 index with a message and its message_text row, the
        // original bytes in content-addressed storage. Opening it must run
        // core-v9, and the vocabulary table must come out equal to the
        // live FTS5 vocabulary without touching the stored row.
        let dbURL = archiveURL.appendingPathComponent(ArchiveStore.indexName)
        try FileManager.default.createDirectory(
            at: archiveURL, withIntermediateDirectories: true
        )
        let pool = try DatabasePool(path: dbURL.path)
        try IndexSchema.migrator(through: "core-v8").migrate(pool)

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
                INSERT INTO message_text (
                    rowid, subject, from_name, from_addr, recipients, body, quoted, attachments
                )
                VALUES (1, 'kickoff', 'alice', 'alice example com', 'bob',
                        'order prj 2214 confirmed for thursday', '', '')
                """
            )
        }

        let store = try ArchiveStore.open(at: archiveURL)
        // The vocabulary table mirrors the live FTS5 vocabulary exactly.
        XCTAssertEqual(try vocabularyTable(store), try liveVocabulary(store))
        XCTAssertFalse(try vocabularyTable(store).isEmpty)
        XCTAssertEqual(try vocabularyTable(store)["kickoff"], 1)
        XCTAssertEqual(try vocabularyTable(store)["prj"], 1)
        // The stored message row survived the migration untouched.
        let row = try store.db.read { db in
            try Row.fetchOne(db, sql: "SELECT hash, size, subject, fromEmail FROM message WHERE id = 1")
        }
        XCTAssertEqual(row?["hash"] as Data?, hash.bytes)
        XCTAssertEqual(row?["size"] as Int64?, Int64(data.count))
        XCTAssertEqual(row?["subject"] as String?, "Kickoff")
        XCTAssertEqual(row?["fromEmail"] as String?, "alice@example.com")
        // The stored text row is also untouched.
        let textRow = try store.db.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT subject, body FROM message_text WHERE rowid = 1"
            )
        }
        XCTAssertEqual(textRow?["subject"] as String?, "kickoff")
        XCTAssertEqual(textRow?["body"] as String?, "order prj 2214 confirmed for thursday")
        // And the migrated archive answers completions right away.
        let result = try store.searchAsYouType("ki")
        XCTAssertEqual(result.completions.map(\.term), ["kickoff"])
        XCTAssertEqual(result.matchSet, 1)
    }
}
