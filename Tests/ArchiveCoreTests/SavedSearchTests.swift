import XCTest
import GRDB
@testable import ArchiveCore

/// Saved searches (DESIGN 12, core-v4): migration from a pre-v4 index, the
/// CRUD round trip, and the sidebar label/account listings. Every test runs
/// in a temporary directory.
final class SavedSearchTests: XCTestCase {
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

    private func makeStore(appVersion: String = "0.1.0") throws -> ArchiveStore {
        try ArchiveStore.create(at: archiveURL, appVersion: appVersion)
    }

    private func makeSampleMessage(subject: String, mailbox: String, labels: [String] = []) -> IngestedMessage {
        let record = MessageRecord(
            subject: subject,
            dateSent: Timestamp.date("2024-03-05T14:23:01Z"),
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

        body of \(subject)
        """.utf8)
        return IngestedMessage(
            record: record,
            data: data,
            memberships: [Membership(mailbox: mailbox, uid: 1, flags: [])],
            labels: labels.map { LabelName(name: $0) }
        )
    }

    // MARK: Migration

    func testIndexMigratesV3ArchiveToCurrentSchema() throws {
        // Simulate an archive written before saved searches existed: an
        // index with only core-v1..v3 applied, holding a real row. Opening
        // it must run core-v4 (create saved_search) without touching the
        // stored row.
        _ = try ArchiveStore.create(at: archiveURL, appVersion: "0.1.0")
        let indexURL = archiveURL.appendingPathComponent(ArchiveStore.indexName)
        let pool = try DatabasePool(path: indexURL.path)
        try IndexSchema.migrator(through: "core-v3").migrate(pool)
        try pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO message (hash, size, subject, normalizedSubject, dateReceived, fromName, fromEmail)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    Data(repeating: 0x01, count: 32),  // a valid 32-byte hash
                    128, "Old subject", "old subject",
                    "2024-03-05T14:23:05Z", "Alice", "alice@example.com",
                ]
            )
        }

        let store = try ArchiveStore.open(at: archiveURL)
        // The old row survived the migration untouched.
        let summary = try store.message(id: 1)
        XCTAssertEqual(summary?.subject, "Old subject")
        XCTAssertEqual(summary?.fromEmail, "alice@example.com")
        // The saved_search table now exists and is empty.
        XCTAssertEqual(try store.listSavedSearches(), [])
        // Opening a second time is idempotent (GRDB skips applied steps).
        let reopened = try ArchiveStore.open(at: archiveURL)
        XCTAssertEqual(try reopened.listSavedSearches(), [])
    }

    // MARK: CRUD

    func testSaveListReplaceDelete() throws {
        let store = try makeStore()

        try store.saveSearch(name: "Invoices", query: "has:attachment invoice")
        try store.saveSearch(name: "From Alice", query: "from:alice@example.com")

        var saved = try store.listSavedSearches()
        XCTAssertEqual(saved.map(\.name), ["From Alice", "Invoices"])  // by name
        XCTAssertEqual(saved.map(\.query), ["from:alice@example.com", "has:attachment invoice"])

        // Saving again under the same name replaces the query, not the row.
        try store.saveSearch(name: "Invoices", query: "has:attachment receipt")
        saved = try store.listSavedSearches()
        XCTAssertEqual(saved.count, 2)
        XCTAssertEqual(saved.first { $0.name == "Invoices" }?.query, "has:attachment receipt")

        try store.deleteSavedSearch(id: saved.first { $0.name == "From Alice" }!.id)
        saved = try store.listSavedSearches()
        XCTAssertEqual(saved.map(\.name), ["Invoices"])
    }

    func testSaveSearchRejectsBlankNameOrQuery() throws {
        let store = try makeStore()

        XCTAssertThrowsError(try store.saveSearch(name: "   ", query: "x")) { error in
            XCTAssertEqual(error as? ArchiveError, .invalidSavedSearchName)
        }
        XCTAssertThrowsError(try store.saveSearch(name: "Name", query: "  ")) { error in
            XCTAssertEqual(error as? ArchiveError, .invalidSavedSearchQuery)
        }
        // Names are trimmed before storing.
        try store.saveSearch(name: "  Padded  ", query: " subject:padded ")
        let saved = try store.listSavedSearches()
        XCTAssertEqual(saved.map(\.name), ["Padded"])
        XCTAssertEqual(saved.map(\.query), ["subject:padded"])
    }

    // MARK: Sidebar listings

    func testListAccountsAndLabels() throws {
        let store = try makeStore()

        let account = AccountIdentity(email: "alice@example.com", displayName: "Alice", providerKind: "imported")
        let first = makeSampleMessage(subject: "one", mailbox: "INBOX", labels: ["Work", "Finance"])
        let second = makeSampleMessage(subject: "two", mailbox: "Archive", labels: ["Work"])
        _ = try store.ingest([first, second], into: account)

        let accounts = try store.listAccounts()
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts[0].email, "alice@example.com")
        XCTAssertEqual(accounts[0].displayName, "Alice")
        XCTAssertEqual(accounts[0].messageCount, 2)

        let labels = try store.listLabels(accountEmail: "alice@example.com")
        XCTAssertEqual(labels.map(\.name), ["Finance", "Work"])
        XCTAssertEqual(labels.first { $0.name == "Work" }?.messageCount, 2)
        XCTAssertEqual(labels.first { $0.name == "Finance" }?.messageCount, 1)

        // A second account shows up with zero counts, not hidden.
        _ = try store.ingest(
            makeSampleMessage(subject: "bobmail", mailbox: "INBOX"),
            into: AccountIdentity(email: "bob@example.org", displayName: "Bob", providerKind: "imported")
        )
        XCTAssertEqual(try store.listAccounts().count, 2)
    }
}
