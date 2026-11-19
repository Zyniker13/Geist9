@testable import ArchiveCore
import ArchiveSearch
import XCTest

/// Entity facets (DESIGN 6A, M2): live counts beside the results. For a
/// query's full match set, the facet says how many messages carry each
/// entity kind, and the drill-in says which values dominate one kind.
/// Counts cover the whole match set — not one result page — and follow
/// the same zero-hit fallback ladder as the hits (trigram retry, then the
/// one-edit typo rescue), so facets always describe the set the person is
/// actually looking at.
final class FacetTests: XCTestCase {
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

    private let account = AccountIdentity(
        email: "alice@example.com", displayName: "Alice", providerKind: "import"
    )

    private func makeMessage(subject: String, body: String) -> IngestedMessage {
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

    /// Five messages: three "order" messages with a spread of entity kinds,
    /// one SMTP message the trigram fallback rescues, one entity-free note.
    private func makeFixture() throws -> (store: ArchiveStore, mailServerID: Int64) {
        let store = try makeStore()
        var mailServerID: Int64 = 0
        _ = try ingest(makeMessage(
            subject: "Order shipped",
            body: "Parcel 1Z999AA10123456784 arrives 2024-03-03; postage $15, "
                + "questions to +49 30 1234567, details at https://example.com/track, "
                + "PNR: 7QKX2Z"
        ), into: store)
        try ingest(makeMessage(
            subject: "Order invoice", body: "Total: $1,234.56 due 2024-03-05"
        ), into: store)
        try ingest(makeMessage(
            subject: "Order invoice too", body: "paid $1,234.56 again, thanks"
        ), into: store)
        mailServerID = try ingest(makeMessage(
            subject: "Mail server",
            body: "the SMTP relay at mail.example.com charges $300, reference INV221488"
        ), into: store)
        try ingest(makeMessage(
            subject: "Lunch", body: "receipt for lunch, nothing counted"
        ), into: store)
        return (store, mailServerID)
    }

    // MARK: Kind counts

    func testFacetsCountMatchingMessagesPerKind() throws {
        let (store, _) = try makeFixture()
        XCTAssertEqual(try store.entityFacets(matching: "order"), [
            .amount: 3, .date: 2, .phone: 1, .tracking: 1, .domain: 1, .booking: 1,
        ])
        // Kinds with no matching messages are absent, not zero.
        XCTAssertEqual(try store.entityFacets(matching: "lunch"), [:])
    }

    func testFacetsFollowTheTrigramRetry() throws {
        let (store, mailServerID) = try makeFixture()
        // "2214" misses the exact index (the token is "INV221488") but the
        // trigram fallback rescues the substring; the facets must describe
        // that same rescued set, not a fresh exact match.
        let hits = try store.search("2214").hits
        XCTAssertEqual(hits.map(\.messageID), [mailServerID])
        XCTAssertTrue(hits.allSatisfy(\.viaTrigram))
        XCTAssertEqual(try store.entityFacets(matching: "2214"), [.amount: 1, .domain: 1])
    }

    func testFacetsFollowTheTypoRescue() throws {
        let (store, _) = try makeFixture()
        // "inoice" is one edit from "invoice" and not a substring of it, so
        // only the one-edit vocabulary rescue can correct it — to the two
        // "Order invoice" subjects. The facets must describe that rescued
        // set, not a fresh exact match or an honest zero.
        let hits = try store.search("inoice").hits
        XCTAssertEqual(Set(hits.map(\.messageID)).count, 2)
        XCTAssertTrue(hits.allSatisfy(\.viaTypo))
        XCTAssertEqual(try store.entityFacets(matching: "inoice"), [.amount: 2, .date: 1])
    }

    func testFacetsAreEmptyWithoutMatches() throws {
        let (store, _) = try makeFixture()
        XCTAssertEqual(try store.entityFacets(matching: "no-such-word-xyzq"), [:])
        XCTAssertEqual(try store.entityFacets(matching: ""), [:])
    }

    // MARK: Value drill-in

    func testValuesRankByMessageCount() throws {
        let (store, _) = try makeFixture()
        XCTAssertEqual(
            try store.entityValues(.amount, matching: "order"),
            [
                EntityValueCount(value: "$1,234.56", count: 2),
                EntityValueCount(value: "$15", count: 1),
            ]
        )
        // Equal counts order by value, so the ranking is deterministic.
        XCTAssertEqual(
            try store.entityValues(.date, matching: "order"),
            [
                EntityValueCount(value: "2024-03-03", count: 1),
                EntityValueCount(value: "2024-03-05", count: 1),
            ]
        )
    }

    func testValuesRespectTheMatchSet() throws {
        let (store, _) = try makeFixture()
        XCTAssertEqual(
            try store.entityValues(.tracking, matching: "order"),
            [EntityValueCount(value: "1Z999AA10123456784", count: 1)]
        )
        XCTAssertEqual(try store.entityValues(.amount, matching: "lunch"), [])
    }

    func testValuesHonorLimit() throws {
        let (store, _) = try makeFixture()
        XCTAssertEqual(
            try store.entityValues(.amount, matching: "order", limit: 1),
            [EntityValueCount(value: "$1,234.56", count: 2)]
        )
    }
}
