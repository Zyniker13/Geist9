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
        // Integers without a fraction stay unrecognized: "4 units", "2024",
        // "#12345" are too ambiguous. A two-decimal figure is covered by
        // testBareTwoDecimalNumbersAreAmounts.
        XCTAssertEqual(EntityExtraction.entities(in: "42 apples and invoice #12345 shipped"), [])
        XCTAssertEqual(EntityExtraction.entities(in: "version 1.2.3 released"), [])
        XCTAssertEqual(EntityExtraction.entities(in: "roughly 1.234 of them"), [])
    }

    func testBareTwoDecimalNumbersAreAmounts() throws {
        // A plain two-decimal figure is a money amount far more often than
        // anything else in mail, and invoices state totals exactly this
        // way; the currency stays unknown. Both separator conventions read
        // through parseAmount's positional rule.
        XCTAssertEqual(
            EntityExtraction.entities(in: "total 1,240.00, due net-30"),
            [EntityHit(kind: .amount, value: "1,240.00", normalized: 1240, currency: nil)]
        )
        XCTAssertEqual(
            EntityExtraction.entities(in: "renewal 47.510,00 is due"),
            [EntityHit(kind: .amount, value: "47.510,00", normalized: 47510, currency: nil)]
        )
        XCTAssertEqual(
            EntityExtraction.entities(in: "interest posting 12.40 this month"),
            [EntityHit(kind: .amount, value: "12.40", normalized: 12.4, currency: nil)]
        )
    }

    func testBareAmountDoesNotStealClaimedSpans() throws {
        // The currency-marked reading wins its span, and a European date is
        // claimed by the date extractor, never sliced into an amount.
        XCTAssertEqual(
            EntityExtraction.entities(in: "summe 1.234,56 € zahlen"),
            [EntityHit(kind: .amount, value: "1.234,56 €", normalized: 1234.56, currency: "EUR")]
        )
        XCTAssertTrue(
            EntityExtraction.entities(in: "Schaden vom 14.02.2024 gemeldet").allSatisfy { $0.kind != .amount },
            "a European date must not yield a bare amount"
        )
    }

    func testCurrencyResolvesLoneDotThousands() throws {
        // With a currency, three-digit dot groups read European: "4.800
        // EUR" is 4,800 euros. Without a currency the lone-dot form stays
        // US-style 1.234 (decision 0031), so it is not an entity at all.
        XCTAssertEqual(
            EntityExtraction.entities(in: "geschätzter Schaden 4.800 EUR"),
            [EntityHit(kind: .amount, value: "4.800 EUR", normalized: 4800, currency: "EUR")]
        )
        XCTAssertEqual(
            EntityExtraction.entities(in: "Zuleitung 1.140 EUR erneuert"),
            [EntityHit(kind: .amount, value: "1.140 EUR", normalized: 1140, currency: "EUR")]
        )
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

    func testAmountOperatorReadsBareTotals() throws {
        // Regression from the judged set: invoices that state a bare total
        // ("total 1,240.00", no currency marker) are amounts, so the
        // amount: operator finds them — including the European "47.510,00"
        // shape and a lone-dot thousands group beside a currency.
        let store = try makeStore()
        let big = try ingest(
            makeMessage(subject: "Invoice", body: "adjusted renewal, 47,510.00, due net-30"), into: store
        )
        let european = try ingest(
            makeMessage(subject: "Rechnung", body: "Wartung 3.250,00 EUR im Januar"), into: store
        )
        let dotted = try ingest(
            makeMessage(subject: "Schaden", body: "geschätzter Schaden 4.800 EUR"), into: store
        )
        XCTAssertEqual(try search(store, "amount:>10000"), [big])
        XCTAssertEqual(try search(store, "amount:3250"), [european])
        XCTAssertEqual(try search(store, "amount:4800"), [dotted])
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

    // MARK: Dates

    /// The UTC epoch of a calendar date, for comparing normalized dates.
    private func utc(
        year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0
    ) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        )!
        return date.timeIntervalSince1970
    }

    private func hitsByValue(_ hits: [EntityHit], _ kind: EntityKind) -> [String: EntityHit] {
        Dictionary(hits.filter { $0.kind == kind }.map { ($0.value, $0) },
                   uniquingKeysWith: { first, _ in first })
    }

    func testISODatesExtracted() throws {
        let hits = EntityExtraction.entities(in: "meeting moved to 2024-03-03 in the plan")
        let date = try XCTUnwrap(hits.first { $0.kind == .date })
        XCTAssertEqual(date.value, "2024-03-03")
        XCTAssertEqual(date.normalized, utc(year: 2024, month: 3, day: 3))
        XCTAssertNil(date.currency)
    }

    func testISODatetimesExtracted() throws {
        let hits = EntityExtraction.entities(in: "starts 2024-03-03T14:23 sharp")
        let date = try XCTUnwrap(hits.first { $0.kind == .date })
        XCTAssertEqual(date.normalized, utc(year: 2024, month: 3, day: 3, hour: 14, minute: 23))
    }

    func testMonthNameDatesExtracted() throws {
        let hits = EntityExtraction.entities(
            in: "due March 3, 2024; reply by 3 April 2024; follow-up May 3, 2024"
        )
        let dates = hitsByValue(hits, .date)
        XCTAssertEqual(dates["March 3, 2024"]?.normalized, utc(year: 2024, month: 3, day: 3))
        XCTAssertEqual(dates["3 April 2024"]?.normalized, utc(year: 2024, month: 4, day: 3))
        XCTAssertEqual(dates["May 3, 2024"]?.normalized, utc(year: 2024, month: 5, day: 3))
        XCTAssertEqual(dates.count, 3)
    }

    func testAbbreviatedMonthDatesExtracted() throws {
        let hits = EntityExtraction.entities(in: "ship by Sep 30, 2024 or Dec 31, 2024")
        let dates = hitsByValue(hits, .date)
        XCTAssertEqual(dates["Sep 30, 2024"]?.normalized, utc(year: 2024, month: 9, day: 30))
        XCTAssertEqual(dates["Dec 31, 2024"]?.normalized, utc(year: 2024, month: 12, day: 31))
    }

    func testNumericDatesFollowTheirConvention() throws {
        // Slash runs month-first (US), dot runs day-first (European); the
        // written form is stored either way, so the raw text stays visible.
        let hits = EntityExtraction.entities(
            in: "pick 3/3/2024 or 03.03.2024, deadline 12/03/2024, alt 12.03.2024"
        )
        let dates = hitsByValue(hits, .date)
        XCTAssertEqual(dates.count, 4, "each written form is its own entity")
        XCTAssertEqual(dates["3/3/2024"]?.normalized, utc(year: 2024, month: 3, day: 3))
        XCTAssertEqual(dates["03.03.2024"]?.normalized, utc(year: 2024, month: 3, day: 3))
        XCTAssertEqual(dates["12/03/2024"]?.normalized, utc(year: 2024, month: 12, day: 3))
        XCTAssertEqual(dates["12.03.2024"]?.normalized, utc(year: 2024, month: 3, day: 12))
    }

    func testInvalidDatesAreSkipped() throws {
        XCTAssertEqual(
            EntityExtraction.entities(in: "nonsense 31.02.2024 and 13/13/2024")
                .filter { $0.kind == .date },
            [],
            "impossible calendar dates are not entities"
        )
    }

    func testBareWeekdayIsNotADate() throws {
        // Relative and weekday-only mentions stay out of the shared patterns:
        // their meaning depends on when the message is read, and a bare
        // "Friday" in a fixture must not become a date row.
        XCTAssertEqual(
            EntityExtraction.entities(in: "we meet on Friday, due date next Tuesday")
                .filter { $0.kind == .date },
            []
        )
    }

    func testGermanMonthDateOnMacOS() throws {
        #if canImport(Darwin)
        // NSDataDetector adds the multilingual and natural forms the shared
        // patterns do not carry; Linux keeps the shared patterns only.
        let hits = EntityExtraction.entities(in: "am 3. März 2024 antworten")
        let date = try XCTUnwrap(hits.first { $0.kind == .date })
        XCTAssertEqual(date.normalized, utc(year: 2024, month: 3, day: 3))
        #endif
    }

    // MARK: Phone numbers

    func testE164PhonesExtracted() throws {
        let hits = EntityExtraction.entities(in: "call +49 30 1234567 or +1-800-555-0100")
        let phones = hitsByValue(hits, .phone)
        XCTAssertEqual(phones["+49 30 1234567"]?.value, "+49 30 1234567")
        XCTAssertEqual(phones["+1-800-555-0100"]?.value, "+1-800-555-0100")
        XCTAssertEqual(phones.count, 2)
        for phone in phones.values {
            XCTAssertEqual(phone.normalized, 0, "phone numbers have no numeric meaning")
            XCTAssertNil(phone.currency)
        }
    }

    func testShortPlusSequencesAreNotPhones() throws {
        XCTAssertEqual(
            EntityExtraction.entities(in: "build with -DDEBUG+1.2.3 flags").filter { $0.kind == .phone },
            []
        )
    }

    func testDetectorPhoneOnMacOS() throws {
        #if canImport(Darwin)
        let hits = EntityExtraction.entities(in: "office phone (415) 555-0100")
        XCTAssertTrue(
            hits.contains { $0.kind == .phone && $0.value.contains("555-0100") },
            "the detector adds forms the shared patterns do not carry"
        )
        #endif
    }

    // MARK: Tracking numbers

    func testUPSTrackingNumbers() throws {
        let hits = EntityExtraction.entities(in: "your parcel 1Z999AA10123456784 shipped")
        XCTAssertEqual(
            hits.first { $0.kind == .tracking }?.value, "1Z999AA10123456784"
        )
    }

    func testUSPSTrackingNumbers() throws {
        let hits = EntityExtraction.entities(in: "track 9400 1000 0000 0000 0000 00 at usps.com")
        XCTAssertEqual(hits.first { $0.kind == .tracking }?.value, "9400 1000 0000 0000 0000 00")
    }

    func testShortDigitRunsAreNotTracking() throws {
        // Ten digits is an order number, a card, or anything else — only the
        // long service-specific shapes count as tracking numbers.
        XCTAssertEqual(
            EntityExtraction.entities(in: "order #1234567890 and card 4111 1111 1111 1111")
                .filter { $0.kind == .tracking },
            []
        )
    }

    // MARK: Booking codes

    func testBookingCodesNeedContext() throws {
        let hits = EntityExtraction.entities(in: "PNR: 7QKX2Z — booking code AB12CD")
        let bookings = hitsByValue(hits, .booking)
        XCTAssertEqual(bookings["7QKX2Z"]?.value, "7QKX2Z")
        XCTAssertEqual(bookings["AB12CD"]?.value, "AB12CD")
        XCTAssertEqual(bookings.count, 2)
    }

    func testBareSixCharacterTokensAreNotBookings() throws {
        XCTAssertEqual(
            EntityExtraction.entities(in: "revenue 7QKX2Z grew ABC123 percent").filter { $0.kind == .booking },
            [],
            "a six-character token without its keyword is noise"
        )
    }

    // MARK: Domains

    func testDomainsFromURLsAndBareHosts() throws {
        let hits = EntityExtraction.entities(
            in: "track it at https://example.com/checkout?x=1 or www.example.org, docs at docs.example.io/dev"
        )
        let domains = hitsByValue(hits, .domain)
        XCTAssertEqual(domains["example.com"]?.value, "example.com")
        XCTAssertEqual(domains["www.example.org"]?.value, "www.example.org")
        XCTAssertEqual(domains["docs.example.io"]?.value, "docs.example.io")
        XCTAssertEqual(domains.count, 3)
    }

    func testNonDomainsAreSkipped() throws {
        XCTAssertEqual(
            EntityExtraction.entities(in: "open invoice.pdf, build v1.2.3, ping foo.bar")
                .filter { $0.kind == .domain },
            [],
            "file names, versions, and unknown TLDs are not domains"
        )
    }

    // MARK: Storage for all kinds

    func testAllKindsStoredAndRemovedWithMessage() throws {
        let store = try makeStore()
        let id = try ingest(
            makeMessage(
                subject: "Shipment",
                body: "Parcel 1Z999AA10123456784 arrives 2024-03-03; postage $15, questions to +49 30 1234567,"
                    + " details at https://example.com/track, PNR: 7QKX2Z"
            ),
            into: store
        )
        let kinds = try store.db.read { db in
            try String.fetchAll(
                db, sql: "SELECT DISTINCT kind FROM message_entity WHERE messageID = ?",
                arguments: [id]
            ).sorted()
        }
        XCTAssertEqual(kinds, ["amount", "booking", "date", "domain", "phone", "tracking"].sorted())

        try store.db.write { db in
            try db.execute(sql: "DELETE FROM message WHERE id = ?", arguments: [id])
        }
        let remaining = try store.db.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM message_entity WHERE messageID = ?",
                arguments: [id]
            ) ?? 0
        }
        XCTAssertEqual(remaining, 0, "entity rows of every kind leave with their message")
    }

    func testDuplicateEntitiesCollapsePerMessageAcrossKinds() throws {
        let hits = EntityExtraction.entities(in: "due 2024-03-03, again 2024-03-03, see example.com and example.com")
        let dates = hits.filter { $0.kind == .date }
        let domains = hits.filter { $0.kind == .domain }
        XCTAssertEqual(dates.count, 1)
        XCTAssertEqual(domains.count, 1)
    }
}
