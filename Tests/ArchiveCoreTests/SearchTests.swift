// End-to-end search tests (DESIGN 6A): ingest a small corpus into a real
// archive, then run queries through the parser, compiler and executor. The
// fixtures deliberately overlap (shared subjects, reference chains,
// recipients, labels, flags, dates, sizes) so each test can assert both the
// positive and the negative case against the same corpus. Every message is
// fake: example.com/example.net addresses only.

import ArchiveSearch
import GRDB
import XCTest
@testable import ArchiveCore

final class SearchTests: XCTestCase {
    private var tempDir: URL!
    private var store: ArchiveStore!
    private var ids: [String: Int64] = [:]

    private let alice = AccountIdentity(email: "alice@example.com", displayName: "Alice", providerKind: "import")
    private let bob = AccountIdentity(email: "bob@example.net", displayName: "Bob", providerKind: "import")

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("geist9-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = try ArchiveStore.create(at: tempDir.appendingPathComponent("Search.emailarchive"), appVersion: "0.1.0")

        ids["m1"] = try ingest(Fixtures.m1, flags: ["seen"])
        ids["m2"] = try ingest(Fixtures.m2)
        ids["m3"] = try ingest(Fixtures.m3, mailbox: "Archive/2020", flags: ["flagged"])
        ids["m4"] = try ingest(Fixtures.m4)
        ids["m5"] = try ingest(Fixtures.m5)
        ids["m6"] = try ingest(Fixtures.m6, mailbox: "Sent")
        ids["m7"] = try ingest(Fixtures.m7)
        ids["m8"] = try ingest(Fixtures.m8)
        ids["m9"] = try ingest(Fixtures.m9)
        ids["m10"] = try ingest(Fixtures.m10, account: bob)
        ids["m11"] = try ingest(Fixtures.m11)
        ids["m12"] = try ingest(Fixtures.m12)
        ids["m13"] = try ingest(Fixtures.m13)
        ids["m15"] = try ingest(Fixtures.m15)
        ids["m16"] = try ingest(Fixtures.m16)
    }

    override func tearDown() {
        store = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: Fixtures (all obviously fake)

    private enum Fixtures {
        static let m1 = """
        Message-ID: <m1@example.com>
        Date: Sat, 15 Jun 2019 12:30:00 +0000
        From: Patricia Quinn <patricia@example.com>
        To: alice@example.com
        Subject: Q3 budget review

        Please review the attached budget spreadsheet.
        """

        static let m2 = """
        Message-ID: <m2@example.com>
        Date: Tue, 01 Jul 2019 09:00:00 +0000
        From: Bob Vance <bob@example.com>
        To: alice@example.com
        Cc: carol@example.com
        Subject: Invoice 42
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="BOUND"

        --BOUND
        Content-Type: text/plain; charset=utf-8

        The invoice is attached. Shipping costs included.
        --BOUND
        Content-Type: application/pdf; name="invoice.pdf"
        Content-Disposition: attachment; filename="invoice.pdf"

        JVBERi0xLjQK
        --BOUND--
        """

        static let m3 = """
        Message-ID: <m3@example.com>
        In-Reply-To: <m1@example.com>
        Date: Sun, 05 Jan 2020 14:00:00 +0000
        From: Dana Wells <dana@example.org>
        To: alice@example.com
        Subject: Contract signed

        Thanks, signing now.
        """

        static let m4 = """
        Message-ID: <m4@example.com>
        Date: Wed, 10 Mar 2021 08:00:00 +0000
        From: Erin Fox <erin@example.net>
        To: alice@example.com
        Bcc: frank@example.net
        Subject: Shipping update

        Your shipping label is ready.
        """

        static let m5 = """
        Message-ID: <m5@example.com>
        Date: Thu, 01 Apr 2021 10:00:00 +0000
        From: Grace Lee <grace@example.com>
        To: alice@example.com
        Subject: Notes

        Quick note about the offsite.

        > budget looks fine to me
        """

        static let m6 = """
        Message-ID: <m6@example.com>
        Date: Thu, 01 May 2019 11:00:00 +0000
        From: alice@example.com
        To: bob@example.com
        Subject: Checking in

        Just checking in on the order.
        """

        static let m7 = """
        Message-ID: <m7@example.com>
        Date: Sat, 01 May 2021 12:00:00 +0000
        From: hank@example.org
        To: alice@example.com

        Mystery meat.
        """

        static let m8 = """
        Message-ID: <m8@example.com>
        Date: Sun, 01 Aug 2021 09:00:00 +0000
        From: Ivy Chen <ivy@example.com>
        To: alice@example.com
        Subject: Receipt for supplies
        X-Gmail-Labels: Receipts,Important

        Supplies ordered.
        """

        static let m9 = """
        Message-ID: <m9@example.com>
        Date: Wed, 01 Sep 2021 09:00:00 +0000
        From: jack@example.com
        To: alice@example.com
        Subject: Trip plans
        X-GM-THRID: 777

        Packing lists attached.
        """

        static let m10 = """
        Message-ID: <m10@example.com>
        Date: Thu, 02 Sep 2021 09:00:00 +0000
        From: kate@example.net
        To: bob@example.net
        Subject: Trip plans
        X-GM-THRID: 777

        Same thread id, other account.
        """

        static let m11 = """
        Message-ID: <m11@example.com>
        Date: Tue, 01 Jun 2021 10:00:00 +0000
        From: lena@example.com
        To: alice@example.com
        Subject: Big message

        \(String(repeating: "lorem ipsum dolor sit amet ", count: 60))
        """

        static let m12 = """
        Message-ID: <m12@example.com>
        Date: Fri, 03 Sep 2021 09:00:00 +0000
        From: greg@example.com
        To: alice@example.com
        Subject: Shipping update

        Follow-up on the shipment.
        """

        static let m13 = """
        Message-ID: <m13@example.com>
        Date: Fri, 03 Sep 2021 15:00:00 +0000
        From: hana@example.com
        To: alice@example.com
        Subject: Re: Shipping update

        Got it, thanks.
        """

        static let m15 = """
        Message-ID: <m15@example.com>
        Date: Sat, 04 Sep 2021 09:00:00 +0000
        From: ivan@example.com
        To: alice@example.com
        Subject: budget

        budget mentioned once here.
        """

        static let m16 = """
        Message-ID: <m16@example.com>
        Date: Sun, 05 Sep 2021 09:00:00 +0000
        From: olga@example.com
        To: alice@example.com
        Subject: Random thoughts

        we should revisit the budget next quarter.
        """

        static let m14 = """
        Message-ID: <m14@example.com>
        Date: Sat, 04 Sep 2021 10:00:00 +0000
        From: june@example.com
        To: alice@example.com
        Subject: Trip plans
        X-GM-THRID: 777

        Also bringing sunscreen.
        """

        // Extra fixtures for the recency and thread-grouping tests. They
        // are ingested inside those tests only, so the corpus-wide
        // assertions above keep their counts.
        static let m17 = """
        Message-ID: <m17@example.com>
        Date: Wed, 10 Feb 2021 09:00:00 +0000
        From: Priya Nair <priya@example.org>
        To: alice@example.com
        Subject: Konferenz Berlin

        Berlin agenda attached.
        """

        static let m18 = """
        Message-ID: <m18@example.com>
        In-Reply-To: <m17@example.com>
        Date: Thu, 11 Feb 2021 09:00:00 +0000
        From: Priya Nair <priya@example.org>
        To: alice@example.com
        Subject: Re: Konferenz Berlin

        Berlin works for me.
        """

        static let m19 = """
        Message-ID: <m19@example.com>
        Date: Fri, 12 Mar 2021 09:00:00 +0000
        From: Quentin Reed <quentin@example.com>
        To: alice@example.com
        Subject: Notes

        berlin review notes here.
        """

        // m20 and m21 are identical in every indexed column; only the date
        // differs, so bm25 ties and the recency boost must decide.
        static let m20 = """
        Message-ID: <m20@example.com>
        Date: Mon, 04 Jan 2021 08:00:00 +0000
        From: olga@example.com
        To: alice@example.com
        Subject: weekly risklog status

        Same text for both messages here.
        """

        static let m21 = """
        Message-ID: <m21@example.com>
        Date: Sat, 04 Jun 2022 08:00:00 +0000
        From: olga@example.com
        To: alice@example.com
        Subject: weekly risklog status

        Same text for both messages here.
        """
    }

    // MARK: Helpers

    private func eml(_ raw: String) -> Data {
        // Multiline literals carry no trailing newline; real .eml files end
        // with one.
        Data((raw + "\n").utf8)
    }

    @discardableResult
    private func ingest(
        _ raw: String,
        mailbox: String = "INBOX",
        flags: [String] = [],
        account: AccountIdentity? = nil
    ) throws -> Int64 {
        let data = eml(raw)
        let parsed = MailBridge.parse(for: data)
        let message = IngestedMessage(
            record: parsed.record,
            data: data,
            memberships: [Membership(mailbox: mailbox, flags: flags)],
            labels: parsed.gmailLabels.map { LabelName(name: $0) },
            attachments: parsed.attachments,
            providerThreadID: parsed.gmailThreadID,
            searchText: parsed.searchText
        )
        switch try store.ingest(message, into: account ?? alice) {
        case .created(let id): return id
        case .duplicate(let id): return id
        }
    }

    private func hits(_ query: String, withSnippets: Bool = false) throws -> [SearchHit] {
        try store.search(query, withSnippets: withSnippets).hits
    }

    private func idsMatching(_ query: String) throws -> Set<Int64> {
        Set(try hits(query).map(\.messageID))
    }

    private func assertHits(_ query: String, _ expected: [String], file: StaticString = #filePath, line: UInt = #line) throws {
        let got = try idsMatching(query)
        XCTAssertEqual(got, Set(expected.map { ids[$0]! }), "query: \(query)", file: file, line: line)
    }

    private func thread(_ name: String) throws -> Int64? {
        try store.db.read { db in
            try Int64.fetchOne(
                db, sql: "SELECT threadID FROM message WHERE id = ?", arguments: [ids[name]!]
            )
        }
    }

    // MARK: Bare terms

    func testBareTermSearchesSubjectBodySenderAndAttachments() throws {
        // "budget" appears in m1 (subject+body), m15 (subject+body), m16
        // (body only). m5's budget is quoted, which bare terms never reach.
        try assertHits("budget", ["m1", "m15", "m16"])
        // Sender names are searchable bare.
        try assertHits("patricia", ["m1"])
        // Attachment names are searchable bare.
        try assertHits("spreadsheet", ["m1"])
        try assertHits("invoice", ["m2"])
    }

    func testQuotedTextIsExcludedFromBareTerms() throws {
        // "looks" only exists in m5's quoted text.
        try assertHits("looks", [])
        // Unquoted text of the same message is still found.
        try assertHits("offsite", ["m5"])
    }

    func testUnqualifiedPhraseReachesQuotedText() throws {
        // A phrase-quoted term is the one bare form that may reach quoted
        // text, at quoted's low rank (DESIGN 6A).
        try assertHits("\"budget looks fine\"", ["m5"])
    }

    // MARK: Field operators

    func testSubjectOperator() throws {
        try assertHits("subject:invoice", ["m2"])
        try assertHits("subject:\"budget review\"", ["m1"])
        try assertHits("subject:q3", ["m1"])
        try assertHits("subject:zzz", [])
    }

    func testBodyOperator() throws {
        // "shipping" is in m2's body, m4's subject+body. m4/m12/m13 have it
        // in subjects, m13 only in its subject.
        try assertHits("body:shipping", ["m2", "m4"])
        try assertHits("body:review", ["m1"])
        try assertHits("body:budget", ["m1", "m15", "m16"])
    }

    func testFromOperator() throws {
        try assertHits("from:patricia@example.com", ["m1"])
        try assertHits("from:patricia", ["m1"])
        try assertHits("from:bob@example.com", ["m2"])
        try assertHits("from:alice@example.com", ["m6"])
        // from: never matches recipients, even when the address appears
        // there (m6's To is bob@example.com, and it is not in the set).
    }

    func testRecipientOperators() throws {
        // Every fixture except m6 (To bob@example.com) and m10 (To
        // bob@example.net) is addressed to alice@example.com.
        let aliceExpected = ["m1", "m2", "m3", "m4", "m5", "m7", "m8", "m9", "m11", "m12", "m13", "m15", "m16"]
        try assertHits("to:alice@example.com", aliceExpected)
        // Bare addresses fall back to token search, same set.
        try assertHits("to:alice", aliceExpected)
        // CC and BCC stay in their own columns.
        try assertHits("cc:carol@example.com", ["m2"])
        try assertHits("bcc:frank@example.net", ["m4"])
        // to: must not see CC-only recipients (address form distinguishes kinds).
        try assertHits("to:carol@example.com", [])
        // A bare word cannot distinguish kinds: it searches the merged
        // recipients column, which holds to + cc + bcc (documented in
        // DESIGN 6A), so carol (CC-only on m2) matches.
        try assertHits("to:carol", ["m2"])
    }

    // MARK: Phrases and boolean structure

    func testPhraseWordOrderMatters() throws {
        try assertHits("\"budget review\"", ["m1"])
        try assertHits("\"review budget\"", [])
        try assertHits("\"checking in\"", ["m6"])
    }

    func testNegation() throws {
        // m2's body has both words; the others only "shipping".
        try assertHits("shipping -invoice", ["m4", "m12", "m13"])
        // m2 has both, so nothing is left.
        try assertHits("invoice -shipping", [])
    }

    func testOrAndGrouping() throws {
        try assertHits("invoice OR receipt", ["m2", "m8"])
        try assertHits("(from:dana OR label:receipts)", ["m3", "m8"])
        try assertHits("subject:trip is:unread", ["m9", "m10"])
        try assertHits("(shipping OR invoice) -invoice", ["m4", "m12", "m13"])
    }

    // MARK: Filters

    func testHasAttachmentFilter() throws {
        try assertHits("has:attachment", ["m2"])
        try assertHits("-has:attachment shipping", ["m4", "m12", "m13"])
    }

    func testFilenameOperator() throws {
        try assertHits("filename:invoice", ["m2"])
        try assertHits("filename:pdf", ["m2"])
        try assertHits("filename:zzz", [])
    }

    func testTypeOperator() throws {
        try assertHits("type:pdf", ["m2"])
        try assertHits("type:image", [])
    }

    func testLabelOperator() throws {
        try assertHits("label:receipts", ["m8"])
        try assertHits("label:important", ["m8"])
        try assertHits("label:receipts from:ivy", ["m8"])
        try assertHits("label:zzz", [])
    }

    func testFolderOperator() throws {
        try assertHits("folder:archive", ["m3"])
        try assertHits("folder:2020", ["m3"])
        try assertHits("folder:sent", ["m6"])
    }

    func testAccountOperator() throws {
        try assertHits("account:bob", ["m10"])
        let allButM10 = ["m1", "m2", "m3", "m4", "m5", "m6", "m7", "m8", "m9", "m11", "m12", "m13", "m15", "m16"]
        try assertHits("account:alice", allButM10)
    }

    func testFlagFilters() throws {
        // m1 is the only seen message.
        let unread = try hits("is:unread")
        XCTAssertEqual(unread.count, 14)
        // Filtered browsing answers newest first.
        XCTAssertEqual(unread.first?.messageID, ids["m16"])
        try assertHits("is:starred", ["m3"])
        try assertHits("is:sent", ["m6"])
        // m16 has "budget" in its body only; m15 in its subject.
        try assertHits("is:unread subject:budget", ["m15"])
    }

    func testDateFilters() throws {
        try assertHits("before:2019-07", ["m1", "m6"])
        try assertHits("after:2021-06-02", ["m8", "m9", "m10", "m12", "m13", "m15", "m16"])
        try assertHits("on:2019-06-15", ["m1"])
    }

    func testSizeFilters() throws {
        try assertHits("larger:1kb", ["m11"])
        let small = ["m1", "m2", "m3", "m4", "m5", "m6", "m7", "m8", "m9", "m10", "m12", "m13", "m15", "m16"]
        try assertHits("smaller:1kb", small)
    }

    // MARK: Errors and warnings

    func testParseErrorsThrow() {
        XCTAssertThrowsError(try QueryParser.parse("("))
        XCTAssertThrowsError(try QueryParser.parse("a OR"))
        XCTAssertThrowsError(try QueryParser.parse("subject:"))
    }

    func testEmptyQueryReturnsNoHits() throws {
        let results = try store.search("")
        XCTAssertTrue(results.hits.isEmpty)
        XCTAssertTrue(results.warnings.isEmpty)
        // A valid operator with no matches is empty, not an error.
        XCTAssertTrue(try hits("subject:zzz").isEmpty)
    }

    func testAmountOperatorWarnsAndMatchesNothing() throws {
        let results = try store.search("amount:3")
        XCTAssertTrue(results.hits.isEmpty)
        XCTAssertFalse(results.warnings.isEmpty)
    }

    // MARK: Duplicate ingest

    func testDuplicateIngestDoesNotDuplicateIndexRows() throws {
        let before = try idsMatching("invoice")
        // Same bytes again, different mailbox: a duplicate. The returned id
        // equals the original id only when ingest deduplicated.
        let result = try ingest(Fixtures.m2, mailbox: "Work")
        XCTAssertEqual(result, ids["m2"]!)
        let after = try idsMatching("invoice")
        XCTAssertEqual(after, before)
        let count = try store.db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message WHERE id = ?", arguments: [ids["m2"]!])
        }
        XCTAssertEqual(count, 1)
        let ftsRows = try store.db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message_text WHERE rowid = ?", arguments: [ids["m2"]!])
        }
        XCTAssertEqual(ftsRows, 1)
    }

    // MARK: Threading (DESIGN 7)

    func testThreadGroupsByReferences() throws {
        let parent = try thread("m1")
        let reply = try thread("m3")
        XCTAssertNotNil(parent)
        XCTAssertEqual(parent, reply, "In-Reply-To joins the parent's thread")
        XCTAssertNotEqual(parent, try thread("m4"))
    }

    func testThreadGroupsByNormalizedSubject() throws {
        let m4 = try thread("m4")
        XCTAssertEqual(m4, try thread("m12"), "same normalized subject joins one thread")
        XCTAssertEqual(m4, try thread("m13"), "Re: is stripped before comparing")
        XCTAssertNotEqual(m4, try thread("m1"))
    }

    func testSubjectlessMessageGetsOwnThread() throws {
        let lonely = try thread("m7")
        XCTAssertNotNil(lonely)
        for other in ["m1", "m2", "m4", "m5", "m6", "m9", "m12", "m13"] {
            XCTAssertNotEqual(lonely, try thread(other))
        }
    }

    func testProviderThreadIsScopedToAccount() throws {
        // Same X-GM-THRID under two accounts must not merge.
        XCTAssertNotEqual(try thread("m9"), try thread("m10"))
        // A second message with the same id in the same account joins.
        let second = try ingest(Fixtures.m14, account: alice)
        let secondThread = try store.db.read { db in
            try Int64.fetchOne(db, sql: "SELECT threadID FROM message WHERE id = ?", arguments: [second])
        }
        XCTAssertEqual(try thread("m9"), secondThread)
    }

    // MARK: Ranking and snippets

    func testRankingFavorsFieldMatchesOverBodyOnly() throws {
        let hits = try hits("budget")
        let byID = Dictionary(uniqueKeysWithValues: hits.map { ($0.messageID, $0) })
        // All three budget messages come back, quoted m5 excluded.
        XCTAssertEqual(Set(byID.keys), Set([ids["m1"]!, ids["m15"]!, ids["m16"]!]))
        // The best hit must be a subject match; a body-only hit ranks worse
        // (bm25 is negative, best first).
        let top = hits.first!
        XCTAssertTrue(top.messageID == ids["m1"]! || top.messageID == ids["m15"]!)
        XCTAssertLessThan(top.rank!, byID[ids["m16"]!]!.rank!)
    }

    func testSnippetsAreProducedWhenRequested() throws {
        let results = try store.search("budget", withSnippets: true)
        let m16 = try XCTUnwrap(results.hits.first { $0.messageID == ids["m16"] })
        let snippet = try XCTUnwrap(m16.snippet)
        XCTAssertTrue(snippet.lowercased().contains("budget"))
        // Without snippets the field stays empty.
        let plain = try hits("budget")
        XCTAssertNil(plain.first { $0.messageID == ids["m16"] }?.snippet)
    }

    func testSnippetHelperCoversLongBodies() throws {
        let results = try store.search("lorem", withSnippets: true)
        let hit = try XCTUnwrap(results.hits.first { $0.messageID == ids["m11"] })
        XCTAssertTrue(hit.snippet?.contains("lorem") ?? false)
    }

    // MARK: Recency boost and thread grouping (M1 search core)

    func testRecencyBoostFavorsNewerMessageOnRankTie() throws {
        // These fixtures are not part of the corpus ids dict, so keep the
        // row ids ingest returns.
        let older = try ingest(Fixtures.m20)
        let newer = try ingest(Fixtures.m21)
        let hits = try hits("risklog")
        XCTAssertEqual(hits.count, 2)
        // The two messages tie on bm25 (identical indexed text); the
        // recency boost must put the newer one (m21, 2022) first.
        XCTAssertEqual(hits.first?.messageID, newer)
        XCTAssertEqual(hits.last?.messageID, older)
        XCTAssertNotNil(hits.first?.rank)
        // Both carry their thread ids.
        XCTAssertTrue(hits.allSatisfy { $0.threadID != nil })
    }

    func testThreadGroupingCollapsesThreadToBestHit() throws {
        let m17 = try ingest(Fixtures.m17)
        _ = try ingest(Fixtures.m18)
        _ = try ingest(Fixtures.m19)
        func threadOf(_ id: Int64) throws -> Int64? {
            try store.db.read { db in
                try Int64.fetchOne(
                    db, sql: "SELECT threadID FROM message WHERE id = ?", arguments: [id]
                )
            }
        }
        let t17 = try threadOf(m17)
        XCTAssertNotNil(t17)

        let plain = try hits("berlin")
        // m17 and m18 are one thread; m19 stands alone. All three match.
        XCTAssertEqual(plain.count, 3)
        XCTAssertTrue(plain.allSatisfy { $0.threadID != nil })

        // Grouped: the thread collapses to its best hit (m17, a subject
        // match, ranks above the body-only m18 and m19).
        let grouped = try store.search("berlin", groupByThread: true).hits
        XCTAssertEqual(grouped.count, 2)
        XCTAssertEqual(grouped.first?.messageID, m17)
        XCTAssertEqual(grouped.first?.threadID, t17)

        // Grouping combined with snippets still produces snippets.
        let groupedSnippets = try store.search(
            "berlin", withSnippets: true, groupByThread: true
        ).hits
        XCTAssertEqual(groupedSnippets.count, 2)
        XCTAssertTrue(groupedSnippets.allSatisfy { $0.snippet != nil })
        XCTAssertEqual(groupedSnippets.first?.messageID, m17)
    }

    func testIngestWritesMessageRankRow() throws {
        // The ranked executor sorts on the narrow message_rank side table
        // (DESIGN 6A, M2.2), so every ingested message must get exactly
        // one rank row in the same transaction as the message itself:
        // day equal to what the shared julianday(COALESCE(...)) computes,
        // threadID equal to the message's thread. Re-ingesting identical
        // bytes re-runs the write as an upsert and must leave a single
        // correct row behind.
        let id = try ingest(Fixtures.m1)

        func rankRow() throws -> Row {
            try store.db.read { db in
                try Row.fetchOne(db, sql: """
                    SELECT m.threadID AS thread, r.threadID AS rankThread,
                           r.day AS day,
                           julianday(COALESCE(m.dateSent, m.dateReceived)) AS expectedDay
                    FROM message m
                    JOIN message_rank r ON r.id = m.id
                    WHERE m.id = ?
                    """,
                    arguments: [id])!
            }
        }

        let first = try rankRow()
        XCTAssertEqual(first["thread"] as Int64?, first["rankThread"] as Int64?)
        XCTAssertEqual(first["day"] as Double?, first["expectedDay"] as Double?)
        XCTAssertNotNil(first["day"] as Double?)

        let again = try ingest(Fixtures.m1)
        XCTAssertEqual(again, id)
        XCTAssertEqual(try rankRow(), first)

        let counts = try store.db.read { db in
            try Row.fetchOne(db, sql: """
                SELECT (SELECT count(*) FROM message) AS messages,
                       (SELECT count(*) FROM message_rank) AS ranks
                """)!
        }
        // setUp ingests the shared fixtures first; the invariant is one
        // rank row per message, however many there are.
        XCTAssertEqual(counts["messages"] as Int64, counts["ranks"] as Int64)
        XCTAssertGreaterThan(counts["messages"] as Int64, 1)
    }

    // Regression (M2 judged set, 2026-11-19): the compiled leaf wrapped the
    // per-token group in the bare-column filter again, so the nested stem
    // column filter intersected down to nothing and a query whose only path
    // to a message is a stem form ("seats" vs "Seat expansion") found
    // nothing. The stem forms must reach the stem columns.
    func testStemFormReachesTheStemColumns() throws {
        let id = try ingest("""
        Message-ID: <seats-regression@example.com>
        Date: Tue, 12 Mar 2024 09:00:00 +0000
        From: Cedar Run Sales <sales@cedarrun.example.com>
        To: alice@example.com
        Subject: Seat expansion to 26

        We need a seat expansion from 18 to 26 users for the support team.
        """)
        XCTAssertTrue(
            try idsMatching("seats").contains(id),
            "\"seats\" must find the message through its stem form \"seat\""
        )
    }

    // Regression (M2 judged set, 2026-11-19): text/* attachment parts carry
    // searchable text (ROADMAP M2: attachment extraction). The attachments
    // column used to hold only file names, so a token that existed only
    // inside an attachment was invisible to every query.
    func testAttachmentTextIsSearchable() throws {
        let id = try ingest("""
        Message-ID: <parts-regression@example.com>
        Date: Tue, 12 Mar 2024 09:00:00 +0000
        From: Birchline Orders <orders@birchline.example.com>
        To: alice@example.com
        Subject: Order BX-2214 confirmation
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary=BOUND

        --BOUND
        Content-Type: text/plain; charset=utf-8

        Thanks for your order.
        --BOUND
        Content-Type: text/csv; charset=utf-8
        Content-Disposition: attachment; filename="parts-bx-2214.csv"

        part,description,quantity
        FB-2214A,wheel bearing kit,2
        --BOUND--
        """)
        XCTAssertTrue(
            try idsMatching("FB-2214A").contains(id),
            "the part number inside the CSV attachment must be searchable"
        )
        XCTAssertTrue(
            try idsMatching("bearing").contains(id),
            "attachment text must be searchable"
        )
    }

    // Decision 0029: one message contributes at most 1 MB of decoded
    // attachment text; text past the cap is not indexed.
    func testAttachmentTextHasACap() throws {
        let filler = String(repeating: "x", count: 1_100_000)
        try ingest("""
        Message-ID: <cap-regression@example.com>
        Date: Tue, 12 Mar 2024 09:00:00 +0000
        From: Birchline Orders <orders@birchline.example.com>
        To: alice@example.com
        Subject: The big export
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary=BOUND

        --BOUND
        Content-Type: text/plain; charset=utf-8

        The export is attached.
        --BOUND
        Content-Type: text/plain; charset=utf-8
        Content-Disposition: attachment; filename="big.txt"

        \(filler)unsearchablezq
        --BOUND--
        """)
        XCTAssertTrue(
            try idsMatching("unsearchablezq").isEmpty,
            "text past the attachment-text cap must not be indexed"
        )
    }

    // Decision 0029: a row indexed by the previous pipeline version gains
    // the attachment text when the backfill re-indexes it from the stored
    // bytes. The stored bytes are never rewritten.
    func testVersionBumpBackfillsAttachmentText() throws {
        let id = try ingest("""
        Message-ID: <backfill-regression@example.com>
        Date: Tue, 12 Mar 2024 09:00:00 +0000
        From: Birchline Orders <orders@birchline.example.com>
        To: alice@example.com
        Subject: Order BX-2214 confirmation
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary=BOUND

        --BOUND
        Content-Type: text/plain; charset=utf-8

        Thanks for your order.
        --BOUND
        Content-Type: text/csv; charset=utf-8
        Content-Disposition: attachment; filename="parts-bx-2214.csv"

        part,description,quantity
        FB-2214A,wheel bearing kit,2
        --BOUND--
        """)
        // Simulate the previous pipeline: mark the row older than current
        // and blank the attachment text the old row could not have had.
        try store.db.write { db in
            try db.execute(
                sql: "UPDATE message SET textVersion = textVersion - 1 WHERE id = ?",
                arguments: [id]
            )
            try db.execute(
                sql: "UPDATE message_text SET attachments = 'parts bx 2214 csv' WHERE rowid = ?",
                arguments: [id]
            )
        }
        let processed = try store.reindexOutdated()
        XCTAssertEqual(processed, 1)
        XCTAssertTrue(
            try idsMatching("FB-2214A").contains(id),
            "the backfill must restore attachment text from the stored bytes"
        )
    }

    // Regression (judged set q067, decision 0030): a sender display name's
    // morphology must be reachable — "nordwind versicherung" must find a
    // message from "Nordwind Versicherungen". The exact path stays
    // non-empty here (the first message matches it), so the trigram
    // fallback must not rescue the second one: only a sender stem column
    // can.
    func testSenderNameStemFormIsSearchable() throws {
        let a = try ingest("""
        Message-ID: <sender-stem-a@example.org>
        Date: Fri, 01 Mar 2024 14:35:00 +0000
        From: Nordwind Versicherungen <claims@nordwind.example.org>
        To: alice@example.com
        Subject: Versicherung: Regulierung läuft

        Die Regulierung läuft.
        """)
        let b = try ingest("""
        Message-ID: <sender-stem-b@example.org>
        Date: Mon, 19 Feb 2024 15:50:00 +0000
        From: Nordwind Versicherungen <claims@nordwind.example.org>
        To: alice@example.com
        Subject: Schadensbericht zum Wasserrohrbruch

        Im Anhang finden Sie den Schadensbericht.
        """)
        let found = try idsMatching("nordwind versicherung")
        XCTAssertTrue(found.contains(a))
        XCTAssertTrue(
            found.contains(b),
            "the sender name's stem form must reach the sender stem column"
        )
    }
}
