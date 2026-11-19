@testable import ArchiveCore
import ArchiveSearch
import GRDB
import XCTest

/// Entity extraction (DESIGN 6A, M2): entities recognized at ingest are
/// stored in message_entity, and the amount: operator queries them with
/// numeric comparisons. The first kind is amounts and currencies; dates,
/// phones, tracking and booking codes, and domains follow the same table.
/// Extraction is pure CPU over the message's search text, so it happens
/// where tokenization happens, and the write path stays transactional.
final class EntityTests: XCTestCase {
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
        subject: String, body: String, searchText: SearchText? = nil
    ) -> IngestedMessage {
        let record = MessageRecord(
            subject: subject,
            dateSent: Timestamp.date("2024-03-05T14:23:05Z"),
            dateReceived: Timestamp.date("2024-03-05T14:23:05Z"),
            messageID: "<\(subject)@example.com>",
            from: Recipient(name: "Alice", email: "alice@example.com"),
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
            searchText: searchText ?? SearchText(body: body, quoted: nil)
        )
    }

    private let account = AccountIdentity(email: "alice@example.com", displayName: "Alice", providerKind: "import")

    private func search(_ store: ArchiveStore, _ query: String) throws -> [Int64] {
        try store.search(query).hits.map(\.messageID)
    }

    // MARK: Extraction patterns

    func testDollarWithCommaThousands() throws {
        XCTAssertEqual(
            EntityExtraction.entities(in: "Total: $1,234.56 today"),
            [EntityHit(kind: .amount, value: "$1,234.56", normalized: 1234.56, currency: "USD")]
        )
    }

    func testEuroWithDecimalComma() throws {
        XCTAssertEqual(
            EntityExtraction.entities(in: "Rechnung: € 99,90"),
            [EntityHit(kind: .amount, value: "€ 99,90", normalized: 99.9, currency: "EUR")]
        )
    }

    func testEuroThousandsDotDecimalComma() throws {
        XCTAssertEqual(
            EntityExtraction.entities(in: "Summe 1.234,56 € zahlen"),
            [EntityHit(kind: .amount, value: "1.234,56 €", normalized: 1234.56, currency: "EUR")]
        )
    }

    func testCurrencyCodePrefixAndSuffix() throws {
        XCTAssertEqual(
            EntityExtraction.entities(in: "refund of USD 45 processed"),
            [EntityHit(kind: .amount, value: "USD 45", normalized: 45, currency: "USD")]
        )
        XCTAssertEqual(
            EntityExtraction.entities(in: "refund of 45 USD processed"),
            [EntityHit(kind: .amount, value: "45 USD", normalized: 45, currency: "USD")]
        )
    }

    func testPoundAndSwissFranc() throws {
        XCTAssertEqual(
            EntityExtraction.entities(in: "fee £1,200 due"),
            [EntityHit(kind: .amount, value: "£1,200", normalized: 1200, currency: "GBP")]
        )
        XCTAssertEqual(
            EntityExtraction.entities(in: "fee CHF 75.50 due"),
            [EntityHit(kind: .amount, value: "CHF 75.50", normalized: 75.5, currency: "CHF")]
        )
    }

    func testYenKeepsItsAmbiguousSymbol() throws {
        // ¥ denotes both yen and yuan; the query language has no currency
        // filter yet, so the honest store is the symbol itself.
        XCTAssertEqual(
            EntityExtraction.entities(in: "price ¥12,800"),
            [EntityHit(kind: .amount, value: "¥12,800", normalized: 12800, currency: "¥")]
        )
    }

    func testBareNumbersAreNotAmounts() throws {
        XCTAssertEqual(EntityExtraction.entities(in: "42 apples and invoice #12345 shipped"), [])
        XCTAssertEqual(EntityExtraction.entities(in: "version 1.2.3 released"), [])
    }

    func testNegativeSignIsNotAnAmount() throws {
        // A minus before the number is a subtraction, not a currency amount;
        // recognizing negatives is left until a query needs them.
        XCTAssertEqual(EntityExtraction.entities(in: "balance changed $-50 and -50 USD"), [])
    }

    func testDuplicateAmountsCollapsePerMessage() throws {
        XCTAssertEqual(
            EntityExtraction.entities(in: "cost $5 first, another $5 later, total $5"),
            [EntityHit(kind: .amount, value: "$5", normalized: 5, currency: "USD")]
        )
    }

    func testDistinctAmountsAreKept() throws {
        XCTAssertEqual(
            EntityExtraction.entities(in: "deposit $250, fee $30"),
            [
                EntityHit(kind: .amount, value: "$250", normalized: 250, currency: "USD"),
                EntityHit(kind: .amount, value: "$30", normalized: 30, currency: "USD"),
            ]
        )
    }

    func testEntityCountIsCapped() throws {
        let text = (1...300).map { "item $\($0)" }.joined(separator: ", ")
        let hits = EntityExtraction.entities(in: text)
        XCTAssertEqual(hits.count, 200, "the per-message entity cap bounds pathological input")
    }

    func testSubjectAndAttachmentTextAreExtracted() throws {
        let entities = EntityExtraction.entities(
            forSubject: "Invoice $850 attached", searchText: SearchText(
                body: "see the PDF", quoted: nil, attachments: "amount due EUR 2.500,00"
            )
        )
        XCTAssertEqual(
            Set(entities.map(\.normalized)), Set([850, 2500]),
            "subject and attachment text both feed entity extraction"
        )
    }

    // MARK: The amount: operator

    @discardableResult
    private func ingest(_ message: IngestedMessage, into store: ArchiveStore) throws -> Int64 {
        switch try store.ingest(message, into: account) {
        case .created(let id): return id
        case .duplicate(let id): return id
        }
    }

    func testAmountOperatorComparesNumerically() throws {
        let store = try makeStore()
        let cheap = try ingest(
            makeMessage(subject: "Rechnung", body: "Betrag € 99,90 bitte überweisen"), into: store
        )
        let expensive = try ingest(
            makeMessage(subject: "Invoice", body: "Total: $1,234.56 due Friday"), into: store
        )
        let none = try ingest(
            makeMessage(subject: "Lunch", body: "see you at noon"), into: store
        )

        XCTAssertEqual(try search(store, "amount:>1000"), [expensive])
        XCTAssertEqual(try search(store, "amount:<100"), [cheap])
        XCTAssertEqual(try search(store, "amount:>=1234.56"), [expensive])
        XCTAssertEqual(try search(store, "amount:99.90"), [cheap])
        XCTAssertEqual(try search(store, "amount:1234.56"), [expensive])
        XCTAssertEqual(try search(store, "amount:>1000000"), [])
        XCTAssertNotEqual(try search(store, "amount:>100"), [none])
    }

    func testAmountOperatorCombinesWithTextAsAND() throws {
        let store = try makeStore()
        _ = try ingest(
            makeMessage(subject: "Rechnung", body: "Betrag € 99,90"), into: store
        )
        _ = try ingest(
            makeMessage(subject: "Invoice", body: "Total: $1,234.56 due Friday"), into: store
        )
        // Text narrows the amount filter; an amount outside the text's
        // messages cannot rescue an OR.
        XCTAssertEqual(try search(store, "rechnung amount:<100"), [1])
        XCTAssertEqual(try search(store, "rechnung amount:>1000"), [])
    }

    func testAmountOperatorWithNoEntityRowsIsQuiet() throws {
        let store = try makeStore()
        _ = try ingest(
            makeMessage(subject: "Lunch", body: "see you at noon"), into: store
        )
        // A valid operator over a corpus with no matching entity is an empty
        // result, not a warning — the operator is real now (it used to warn
        // "not indexed yet" before this feature existed).
        let results = try store.search("amount:3")
        XCTAssertTrue(results.hits.isEmpty)
        XCTAssertTrue(results.warnings.isEmpty)
    }

    func testAmountOperatorRejectsUnparseableValues() throws {
        let store = try makeStore()
        _ = try ingest(
            makeMessage(subject: "Invoice", body: "Total: $1,234.56"), into: store
        )
        // A bare operator is a parse error, like every other operator;
        // a value that parses to no comparison warns and matches nothing.
        XCTAssertThrowsError(try store.search("amount:"))
        for value in ["abc", ",,", "5.5.5", ">", "≤5", "1e6"] {
            let results = try store.search("amount:\(value)")
            XCTAssertTrue(results.hits.isEmpty, "amount:\(value) must match nothing")
            XCTAssertFalse(results.warnings.isEmpty, "amount:\(value) must warn")
        }
    }

    func testAmountRowsAreRemovedWithTheirMessage() throws {
        let store = try makeStore()
        let id = try ingest(
            makeMessage(subject: "Invoice", body: "Total: $1,234.56"), into: store
        )
        XCTAssertEqual(try search(store, "amount:>1000"), [id])
        // Messages leave the store through the cascade (mailbox or account
        // deletion); entity rows must go with the message, never linger as
        // orphans pointing at a missing row.
        try store.db.write { db in
            try db.execute(sql: "DELETE FROM message WHERE id = ?", arguments: [id])
        }
        XCTAssertEqual(try search(store, "amount:>1000"), [])
    }

    // MARK: Backfill from stored bytes

    func testEntityBackfillRunsInTheReindexPass() throws {
        let store = try makeStore()
        let id = try ingest(
            makeMessage(subject: "Invoice", body: "Total: $1,234.56"), into: store
        )
        XCTAssertEqual(try search(store, "amount:>1000"), [id])

        // Simulate an archive indexed before entity extraction existed: the
        // entity rows are gone and the row's text version predates them.
        try store.db.write { db in
            try db.execute(sql: "DELETE FROM message_entity")
            try db.execute(
                sql: "UPDATE message SET textVersion = ? WHERE id = ?",
                arguments: [TextIndexVersion.v5, id]
            )
        }

        XCTAssertEqual(try store.reindexOutdated(), 1)
        XCTAssertEqual(try search(store, "amount:>1000"), [id])
        XCTAssertEqual(try store.reindexOutdated(), 0)
    }
}
