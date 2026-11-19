@testable import ArchiveCore
import ArchiveSearch
import GRDB
import XCTest

/// The as-you-type search path (decision 0025): vocabulary completions for
/// the active prefix, the 60k match-set gate, ranked prefix hits when the
/// gate passes, honest emptiness when the query is malformed mid-typing,
/// and the core-v7 migration that builds the first-letter tables. Every
/// test runs in a temporary directory.
final class AsYouTypeTests: XCTestCase {
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

    // MARK: Completions and the ranked gate

    func testFirstKeystrokeCompletesAcrossTermsAndRanksWhenTheGatePasses() throws {
        let store = try makeStore()
        try ingest(store, [
            makeMessage(subject: "Budget kickoff", body: "The kickoff meeting starts Monday"),
            makeMessage(subject: "Lunch order", body: "Kickoff slides attached"),
            makeMessage(subject: "Zebra fish", body: "Nothing to do with it"),
        ])
        // The first-letter tables are maintained at the end of an import
        // (decision 0025); simulate that before the first keystroke.
        try store.refreshAsYouTypeVocabulary()
        let result = try store.searchAsYouType("k")
        // Completions are terms that START with the prefix: only kickoff.
        // (meeting/monday live under the letter "m" — covered by the
        // first-letter test below.)
        XCTAssertEqual(result.completions.map(\.term), ["kickoff"])
        // kickoff spans both messages that mention it.
        XCTAssertEqual(result.matchSet, 2)
        // The gate passes, so the ranked path runs on the first keystroke
        // with the prefix already applied: both messages mention a k-word.
        XCTAssertEqual(Set(result.ranked.map(\.messageID)), [1, 2])
        // The prefix folds case before the vocabulary lookup.
        XCTAssertEqual(try store.searchAsYouType("K").completions.map(\.term), ["kickoff"])
    }

    func testFirstKeystrokeServedFromTheFirstLetterTable() throws {
        let store = try makeStore()
        try ingest(store, [
            makeMessage(subject: "Budget kickoff", body: "The kickoff meeting starts Monday"),
        ])
        try store.refreshAsYouTypeVocabulary()
        // "m" completes from the precomputed first-letter table, which the
        // import filled: meeting, monday, and — decision 0026 — the stem
        // "meet" that the ingest stored alongside "meeting", so a user who
        // types "meet" finds the message through its indexed stem. Ordered
        // by term on a tie.
        let result = try store.searchAsYouType("m")
        XCTAssertEqual(result.completions.map(\.term), ["meet", "meeting", "monday"])
        XCTAssertEqual(result.matchSet, 3)
        XCTAssertEqual(result.ranked.map(\.messageID), [1])
    }

    func testLongerPrefixNarrowsCompletions() throws {
        let store = try makeStore()
        try ingest(store, [
            makeMessage(subject: "Budget kickoff", body: "The kickoff meeting starts Monday"),
            makeMessage(subject: "Lunch order", body: "Kickoff slides attached"),
        ])
        let result = try store.searchAsYouType("ki")
        XCTAssertEqual(result.completions.map(\.term), ["kickoff"])
        XCTAssertEqual(result.matchSet, 2)
        XCTAssertEqual(Set(result.ranked.map(\.messageID)), [1, 2])
    }

    func testACompleteTermInFlightIsStillAPrefix() throws {
        // "kickoff" with no trailing space is still being typed: the user
        // may be writing "kickoffs". Completions stay on and the ranked
        // path uses the prefix.
        let store = try makeStore()
        try ingest(store, [
            makeMessage(subject: "Budget kickoff", body: "The kickoff meeting starts Monday"),
            makeMessage(subject: "Kickoff recap", body: "All kickoffs happen Monday"),
        ])
        let result = try store.searchAsYouType("kickoff")
        XCTAssertEqual(result.completions.map(\.term), ["kickoff", "kickoffs"])
        XCTAssertEqual(result.matchSet, 3)
        XCTAssertEqual(Set(result.ranked.map(\.messageID)), [1, 2])
    }

    func testCommittedQueryRanksWithoutCompletions() throws {
        let store = try makeStore()
        try ingest(store, [
            makeMessage(subject: "Budget kickoff", body: "The kickoff meeting starts Monday"),
            makeMessage(subject: "Lunch order", body: "Kickoff slides attached"),
            makeMessage(subject: "Zebra fish", body: "Nothing to do with it"),
        ])
        // A trailing space commits the term: no completions, ranked as if
        // entered.
        let committed = try store.searchAsYouType("kickoff ")
        XCTAssertEqual(committed.completions, [])
        XCTAssertEqual(committed.matchSet, 0)
        XCTAssertEqual(Set(committed.ranked.map(\.messageID)), [1, 2])

        // A closing quote commits a phrase.
        let quoted = try store.searchAsYouType("\"kickoff meeting\"")
        XCTAssertEqual(quoted.completions, [])
        XCTAssertEqual(quoted.ranked.map(\.messageID), [1])
    }

    func testFieldedQueryWithoutTextClauseRanksAsEntered() throws {
        let store = try makeStore()
        try ingest(store, [
            makeMessage(subject: "Budget kickoff", body: "See attached"),
            makeMessage(
                subject: "Lunch order", body: "See attached",
                from: Recipient(name: "Bob", email: "bob@example.org")),
        ])
        // "from:bob" ends mid-word, but a field clause has no active
        // prefix, so the ranked search runs exactly as entered.
        let result = try store.searchAsYouType("from:bob")
        XCTAssertEqual(result.completions, [])
        XCTAssertEqual(result.ranked.map(\.messageID), [2])
    }

    func testMalformedInFlightQueriesReturnEmptyInsteadOfRaising() throws {
        let store = try makeStore()
        try ingest(store, [makeMessage(subject: "Budget kickoff", body: "See attached")])
        // Mid-typing, the parser rejects many half-entered queries. None of
        // them may surface an error or partial results.
        for query in ["(unclosed", "kickoff OR"] {
            let result = try store.searchAsYouType(query)
            XCTAssertEqual(result.completions, [], query)
            XCTAssertEqual(result.matchSet, 0, query)
            XCTAssertEqual(result.ranked, [], query)
        }
        // An empty input is nothing to search yet.
        let empty = try store.searchAsYouType("")
        XCTAssertEqual(empty.completions, [])
        XCTAssertEqual(empty.ranked, [])
    }

    // MARK: The gate at full size

    func testGateBlocksRankedForHugeMatchSetsUntilCommitted() throws {
        // More than Vocabulary.gateThreshold documents match the prefix.
        // Building 60k real messages would be slow; instead the store holds
        // three real messages and the rest are message_text rows only —
        // enough to trip the gate, since the gate reads document counts.
        let store = try makeStore()
        try ingest(store, [
            makeMessage(subject: "Alpha note", body: "alpha one two"),
            makeMessage(subject: "Alpha memo", body: "alpha three four"),
            makeMessage(subject: "Alpha list", body: "alpha five six"),
        ])
        try store.db.write { db in
            let statement = try db.makeStatement(sql: """
                INSERT INTO message_text (rowid, subject, from_name, from_addr, recipients, body, quoted, attachments)
                VALUES (?, ?, '', '', '', 'alpha one two', '', '')
                """)
            for rowid in 4...Vocabulary.gateThreshold + 5 {
                try statement.execute(arguments: [rowid, "batch \(rowid)"])
            }
        }
        // The first-letter table must reflect the bulk rows for the
        // one-character prefix to see the true match set.
        try store.refreshAsYouTypeVocabulary()

        let inFlight = try store.searchAsYouType("a")
        XCTAssertTrue(inFlight.completions.contains { $0.term == "alpha" })
        XCTAssertGreaterThan(inFlight.matchSet, Vocabulary.gateThreshold)
        // The gate holds: no ranked results while the match set is huge.
        XCTAssertEqual(inFlight.ranked, [])

        // Committing the term bypasses the gate and returns the hits the
        // archive actually has, limited.
        let committed = try store.searchAsYouType("alpha ", limit: 5)
        XCTAssertEqual(committed.completions, [])
        XCTAssertEqual(committed.ranked.count, 3)
    }

    // MARK: core-v7 migration

    func testMigrationV6ToV7BuildsTheFirstLetterTables() throws {
        // Simulate an archive written before the vocabulary tables existed:
        // a core-v6 index with two messages and their message_text rows.
        // Opening it must run core-v7 and fill the first-letter tables from
        // message_text without touching the stored rows.
        let dbURL = archiveURL.appendingPathComponent(ArchiveStore.indexName)
        try FileManager.default.createDirectory(
            at: archiveURL, withIntermediateDirectories: true
        )
        let pool = try DatabasePool(path: dbURL.path)
        try IndexSchema.migrator(through: "core-v6").migrate(pool)
        try ArchiveManifest(createdAt: Date(), appVersion: "0.1.0")
            .write(to: archiveURL.appendingPathComponent(ArchiveStore.manifestName))

        try pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO message (id, hash, size, subject, normalizedSubject, dateReceived, fromName, fromEmail)
                VALUES (1, X'0102030405060708', 10, 'Kickoff', 'kickoff', '2024-03-05T14:23:05Z', 'Alice', 'alice@example.com')
                """
            )
            try db.execute(
                sql: """
                INSERT INTO message (id, hash, size, subject, normalizedSubject, dateReceived, fromName, fromEmail)
                VALUES (2, X'0807060504030201', 12, 'Undated', 'undated', '2024-03-05T14:23:05Z', 'Bob', 'bob@example.org')
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
            // A real core-v6 archive already ran the rank backfill over its
            // messages; replicate it for the rows added after the migration.
            try db.execute(
                sql: """
                INSERT INTO message_rank (id, threadID, day)
                SELECT id, threadID, julianday(COALESCE(dateSent, dateReceived))
                FROM message
                """
            )
        }

        let store = try ArchiveStore.open(at: archiveURL)
        // The stored rows survived the migration untouched.
        let subjects = try store.db.read { db in
            try String.fetchAll(db, sql: "SELECT subject FROM message ORDER BY id")
        }
        XCTAssertEqual(subjects, ["Kickoff", "Undated"])

        // The first-letter tables were built at open: 'k' and 'u' exist,
        // each with the single document its one term spans.
        let kTotal = try store.db.read { db in
            try Int.fetchOne(db, sql: "SELECT total_doc FROM first_letter WHERE letter = 'k'")
        }
        XCTAssertEqual(kTotal, 1)
        let uTotal = try store.db.read { db in
            try Int.fetchOne(db, sql: "SELECT total_doc FROM first_letter WHERE letter = 'u'")
        }
        XCTAssertEqual(uTotal, 1)
        let kickoffTerms = try store.db.read { db in
            try Row.fetchAll(
                db, sql: "SELECT letter, doc FROM first_letter_terms WHERE term = 'kickoff'")
        }
        XCTAssertEqual(kickoffTerms.count, 1)
        XCTAssertEqual(kickoffTerms.first?["letter"] as String?, "k")
        XCTAssertEqual(kickoffTerms.first?["doc"] as Int?, 1)

        // Both one-character prefixes complete and rank right away.
        let k = try store.searchAsYouType("k")
        XCTAssertEqual(k.completions.map(\.term), ["kickoff"])
        XCTAssertEqual(k.ranked.map(\.messageID), [1])
        let u = try store.searchAsYouType("u")
        XCTAssertEqual(u.completions.map(\.term), ["undated"])
        XCTAssertEqual(u.ranked.map(\.messageID), [2])
    }

    // MARK: Phrase adjacency under stemming (decision 0026)

    func testStemmingNeverBreaksPhraseAdjacency() throws {
        // Regression for the interleaved-stem design: indexing each token's
        // stem into the same FTS column turned "running budgets" into
        // "running run budgets budget", and the phrase "running budgets"
        // matched nothing. Stems live in separate stem columns now; the
        // original token stream stays adjacent.
        let store = try makeStore()
        try ingest(store, [
            makeMessage(subject: "Budget review", body: "The running budgets for next quarter arrive Friday"),
            makeMessage(subject: "Schedule note", body: "budgets running late this week"),
        ])
        // The adjacent phrase finds its message…
        XCTAssertEqual(
            try store.search("\"running budgets\"").hits.map(\.messageID),
            [1])
        // …in the other order the words are not adjacent…
        XCTAssertEqual(
            try store.search("\"budgets running\"").hits.map(\.messageID),
            [2])
        // …and stemming still supplies term recall: "running" (stem "run")
        // and "budgets" (stem "budget") each find both messages.
        XCTAssertEqual(
            Set(try store.search("running").hits.map(\.messageID)),
            Set([1, 2]))
        XCTAssertEqual(
            Set(try store.search("budgets").hits.map(\.messageID)),
            Set([1, 2]))
    }
}
