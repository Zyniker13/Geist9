import XCTest
import GRDB
@testable import ArchiveCore

/// Read-only archive access (DESIGN 9A): the MCP helper and scripts open an
/// archive with `openReadOnly` and can never write, never migrate, and never
/// create anything. Every test runs in a temporary directory and asserts the
/// directory's data files are byte-for-byte untouched.
final class ReadOnlyTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("geist9-readonly-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
    }

    private var archiveURL: URL { tempDir.appendingPathComponent("Test.emailarchive") }

    @discardableResult
    private func makeArchive() throws -> ArchiveStore {
        let store = try ArchiveStore.create(at: archiveURL, appVersion: "0.1.0")
        let message = IngestedMessage(
            record: MessageRecord(
                subject: "Lease renewal",
                dateSent: Timestamp.date("2024-03-05T14:23:01Z"),
                dateReceived: Timestamp.date("2024-03-05T14:23:05Z"),
                messageID: "lease-1@example.com",
                from: Recipient(name: "Alice", email: "alice@example.com"),
                to: [Recipient(name: "Bob", email: "bob@example.org")]
            ),
            data: Data("From: alice@example.com\r\nTo: bob@example.org\r\nSubject: Lease renewal\r\n\r\nThe lease renewal notice for the studio.\r\n".utf8),
            memberships: [Membership(mailbox: "INBOX", uid: 7)]
        )
        _ = try store.ingest(
            message,
            into: AccountIdentity(email: "alice@example.com", displayName: "Alice Personal", providerKind: "import")
        )
        return store
    }

    /// Relative paths of the archive's files, so the untouched test can
    /// compare snapshots. SQLite sidecars (-wal, -shm) are excluded: a
    /// read-only SQLite connection may attach shared memory, which is cache,
    /// not data (decision 0052).
    private func inventory(_ directory: URL) throws -> Set<String> {
        var names = Set<String>()
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)!
        for case let url as URL in enumerator {
            let relative = url.path.dropFirst(directory.path.count + 1)
            if relative.hasSuffix("-wal") || relative.hasSuffix("-shm") { continue }
            names.insert(String(relative))
        }
        return names
    }

    func testOpenReadOnlyReadsAndNeverWrites() throws {
        try makeArchive()
        let before = try inventory(archiveURL)

        let readonly = try ArchiveStore.openReadOnly(at: archiveURL)

        // Queries work: the ingested message is findable.
        let results = try readonly.search("lease", limit: 10)
        XCTAssertEqual(results.hits.count, 1)

        // The directory is untouched: no new files, none removed.
        XCTAssertEqual(try inventory(archiveURL), before)
    }

    func testOpenReadOnlyRefusesWrites() throws {
        try makeArchive()
        let readonly = try ArchiveStore.openReadOnly(at: archiveURL)

        XCTAssertThrowsError(try readonly.db.write { db in
            try db.execute(sql: "DELETE FROM message")
        }) { error in
            // SQLite refuses, not ArchiveCore silently swallowing it.
            guard error is GRDB.DatabaseError else {
                return XCTFail("expected a database error, got \(error)")
            }
        }
    }

    func testOpenReadOnlyNeverMigrates() throws {
        // Simulate an archive from an older build: one applied migration
        // fewer than this build expects.
        try makeArchive()
        let pool = try IndexSchema.openDatabase(at: archiveURL.appendingPathComponent(ArchiveStore.indexName))
        try pool.write { db in
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = (SELECT MAX(identifier) FROM grdb_migrations)")
        }
        try pool.close()

        let before = try inventory(archiveURL)
        XCTAssertThrowsError(try ArchiveStore.openReadOnly(at: archiveURL)) { error in
            guard case ArchiveError.schemaBehind = error else {
                return XCTFail("expected schemaBehind, got \(error)")
            }
        }
        XCTAssertEqual(try inventory(archiveURL), before)
    }

    func testOpenReadOnlyRefusesNotAnArchive() throws {
        XCTAssertThrowsError(try ArchiveStore.openReadOnly(at: tempDir)) { error in
            guard case ArchiveError.notAnArchive = error else {
                return XCTFail("expected notAnArchive, got \(error)")
            }
        }
    }

    func testSavedSearchesRefusedOnReadOnlyStore() throws {
        try makeArchive()
        let readonly = try ArchiveStore.openReadOnly(at: archiveURL)
        XCTAssertThrowsError(try readonly.saveSearch(name: "all", query: "from:alice@example.com"))
    }
}
