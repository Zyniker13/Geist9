@testable import ArchiveCore
import ArchiveSearch
import XCTest

/// The timeline histogram (DESIGN 6A, M2): for a query's full match set,
/// how many messages carry each year-and-month of their effective date
/// (dateSent, else dateReceived), plus the undated count. The buckets
/// cover the whole match set — not one result page — and follow the same
/// zero-hit fallback ladder as the hits (trigram retry, then the one-edit
/// typo rescue), so the histogram always describes the set on screen.
final class TimelineHistogramTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("geist9-timeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
    }

    private var archiveURL: URL { tempDir.appendingPathComponent("Test.emailarchive") }

    private func makeStore() throws -> ArchiveStore {
        try ArchiveStore.create(at: archiveURL, appVersion: "0.1.0")
    }

    private let account = AccountIdentity(
        email: "alice@example.com", displayName: "Alice", providerKind: "import"
    )

    private func makeMessage(
        subject: String, body: String, sent: String?, id: String
    ) -> IngestedMessage {
        let record = MessageRecord(
            subject: subject,
            dateSent: sent.map { Timestamp.date($0) } ?? nil,
            dateReceived: sent.map { Timestamp.date($0) } ?? nil,
            messageID: "<\(id)@example.com>",
            from: Recipient(name: "Alice", email: "alice@example.com"),
            to: [Recipient(name: "Bob", email: "bob@example.org")]
        )
        let data = Data("""
        From: Alice <alice@example.com>
        To: Bob <bob@example.org>
        Subject: \(subject)
        Message-ID: <\(id)@example.com>

        \(body)
        """.utf8)
        return IngestedMessage(
            record: record,
            data: data,
            memberships: [Membership(mailbox: "INBOX", uid: 1, flags: [])],
            searchText: SearchText(body: body, quoted: nil)
        )
    }

    @discardableResult
    private func ingest(_ message: IngestedMessage, into store: ArchiveStore) throws -> Int64 {
        switch try store.ingest(message, into: account) {
        case .created(let id): return id
        case .duplicate(let id): return id
        }
    }

    /// Four "invoice" messages spread over three months and two years, plus
    /// one undated one; and one unrelated message.
    private func makeFixture() throws -> ArchiveStore {
        let store = try makeStore()
        try ingest(makeMessage(
            subject: "Invoice January", body: "invoice for January work",
            sent: "2023-01-15T10:00:00Z", id: "jan"
        ), into: store)
        try ingest(makeMessage(
            subject: "Invoice January two", body: "another invoice for January",
            sent: "2023-01-20T10:00:00Z", id: "jan2"
        ), into: store)
        try ingest(makeMessage(
            subject: "Invoice March", body: "invoice for March work",
            sent: "2023-03-08T10:00:00Z", id: "mar"
        ), into: store)
        try ingest(makeMessage(
            subject: "Invoice next year", body: "invoice for the next fiscal year",
            sent: "2024-01-09T10:00:00Z", id: "nextyear"
        ), into: store)
        // A message with no dates at all.
        try ingest(makeMessage(
            subject: "Invoice undated", body: "an invoice with no date",
            sent: nil, id: "undated"
        ), into: store)
        try ingest(makeMessage(
            subject: "Lunch", body: "receipt for lunch, nothing counted",
            sent: "2023-02-02T10:00:00Z", id: "lunch"
        ), into: store)
        // One unrelated message, reachable only through the trigram
        // fallback: its reference number contains the digits of "2214".
        try ingest(makeMessage(
            subject: "Mail server quote",
            body: "the SMTP relay at mail.example.com charges $300, reference INV221488",
            sent: "2024-03-05T10:00:00Z", id: "mailserver"
        ), into: store)
        return store
    }

    func testHistogramBucketsTheFullMatchSetByYearMonth() throws {
        let store = try makeFixture()
        let (buckets, undated) = try store.timelineHistogram(matching: "invoice")
        XCTAssertEqual(buckets, [
            YearMonthCount(year: 2023, month: 1, count: 2),
            YearMonthCount(year: 2023, month: 3, count: 1),
            YearMonthCount(year: 2024, month: 1, count: 1),
        ])
        XCTAssertEqual(undated, 1)
    }

    func testHistogramIsChronologicalAscending() throws {
        let store = try makeFixture()
        let (buckets, _) = try store.timelineHistogram(matching: "invoice")
        let keys = buckets.map { $0.year * 100 + $0.month }
        XCTAssertEqual(keys, keys.sorted())
    }

    func testHistogramIsEmptyForZeroHits() throws {
        let store = try makeFixture()
        let (buckets, undated) = try store.timelineHistogram(matching: "nothing matches this at all")
        XCTAssertEqual(buckets, [])
        XCTAssertEqual(undated, 0)
    }

    func testHistogramFollowsTheTrigramRetry() throws {
        let store = try makeFixture()
        // The mail-server message is only reachable through the trigram
        // fallback ("2214" is a substring of "INV221488"); the histogram
        // must describe that same rescued set, not a fresh exact match.
        let hits = try store.search("2214").hits
        XCTAssertEqual(hits.count, 1)
        XCTAssertTrue(hits.allSatisfy(\.viaTrigram))
        let (buckets, undated) = try store.timelineHistogram(matching: "2214")
        XCTAssertEqual(
            buckets, [YearMonthCount(year: 2024, month: 3, count: 1)]
        )
        XCTAssertEqual(undated, 0)
    }

    func testHistogramFollowsTheTypoRescue() throws {
        let store = try makeFixture()
        // "inoice" is one edit from "invoice" and not a substring of
        // anything in the corpus, so both the exact index and the trigram
        // fallback come up empty; the one-edit rescue must serve the
        // histogram the same rescued set the hits show.
        let hits = try store.search("inoice").hits
        XCTAssertEqual(hits.count, 5)
        XCTAssertTrue(hits.allSatisfy(\.viaTypo))
        let (buckets, undated) = try store.timelineHistogram(matching: "inoice")
        XCTAssertEqual(buckets, [
            YearMonthCount(year: 2023, month: 1, count: 2),
            YearMonthCount(year: 2023, month: 3, count: 1),
            YearMonthCount(year: 2024, month: 1, count: 1),
        ])
        XCTAssertEqual(undated, 1)
    }

    func testHistogramCountsWithinTheFacetBudget() throws {
        let store = try ArchiveStore.create(at: archiveURL, appVersion: "0.1.0")
        // A few thousand messages spread over years: the histogram query is
        // a single indexed scan, comfortably under the 300 ms budget.
        for index in 0..<4_000 {
            let year = 2020 + (index % 5)
            let month = 1 + (index % 12)
            try ingest(makeMessage(
                subject: "Invoice \(index)",
                body: "invoice body number \(index)",
                sent: String(format: "%04d-%02d-15T10:00:00Z", year, month),
                id: "bulk\(index)"
            ), into: store)
        }
        let started = Date()
        let (buckets, _) = try store.timelineHistogram(matching: "invoice")
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(buckets.count, 60)
        XCTAssertLessThan(elapsed, 0.3, "histogram must run under the 300 ms faceted-counts budget")
    }
}
