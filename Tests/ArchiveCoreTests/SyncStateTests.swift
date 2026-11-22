import XCTest
import GRDB
@testable import ArchiveCore

/// Sync-state persistence (DESIGN 5, ARCHIVE-FORMAT `sync_state`): the
/// resumable per-mailbox checkpoint the sync engine reads before each folder
/// and writes after each batch. A killed sync resumes from its last
/// checkpoint; a forced UIDVALIDITY change resets the high-water UID to zero
/// so a folder is never fetched twice under the same validity and never
/// skipped under a new one. Every test runs in a temporary directory.
final class SyncStateTests: XCTestCase {
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
        email: "alice@example.com", displayName: "Alice", providerKind: "imap"
    )

    private func count(_ store: ArchiveStore, _ sql: String) throws -> Int {
        try store.db.read { db in try Int.fetchOne(db, sql: sql) ?? 0 }
    }

    private func singleRow(_ store: ArchiveStore, _ sql: String) throws -> Row {
        try store.db.read { db in try Row.fetchOne(db, sql: sql)! }
    }

    // MARK: - Fresh store

    func testNeverSyncedMailboxHasNoCheckpoint() throws {
        let store = try makeStore()
        XCTAssertNil(try store.syncState(account: account, mailbox: "INBOX"))
        XCTAssertEqual(try count(store, "SELECT COUNT(*) FROM sync_state"), 0)
    }

    // MARK: - Set and read back

    func testSetCreatesAccountAndMailboxAndStoresCheckpoint() throws {
        let store = try makeStore()
        let state = SyncState(
            uidValidity: 42, highestUID: 500, highestModSeq: 1200,
            updatedAt: "2024-03-05T14:23:01Z"
        )
        try store.setSyncState(state, account: account, mailbox: "INBOX")

        // The account and mailbox rows were created on demand.
        XCTAssertEqual(try count(store, "SELECT COUNT(*) FROM account"), 1)
        XCTAssertEqual(try count(store, "SELECT COUNT(*) FROM mailbox"), 1)
        XCTAssertEqual(try count(store, "SELECT COUNT(*) FROM sync_state"), 1)

        let read = try store.syncState(account: account, mailbox: "INBOX")
        XCTAssertEqual(read, state)
        XCTAssertEqual(read?.uidValidity, 42)
        XCTAssertEqual(read?.highestUID, 500)
        XCTAssertEqual(read?.highestModSeq, 1200)
        XCTAssertEqual(read?.updatedAt, "2024-03-05T14:23:01Z")
    }

    func testCheckpointPerMailboxIsIndependent() throws {
        let store = try makeStore()
        try store.setSyncState(
            SyncState(uidValidity: 1, highestUID: 10, highestModSeq: nil,
                      updatedAt: "2024-03-05T14:23:01Z"),
            account: account, mailbox: "INBOX"
        )
        try store.setSyncState(
            SyncState(uidValidity: 1, highestUID: 999, highestModSeq: nil,
                      updatedAt: "2024-03-05T14:23:01Z"),
            account: account, mailbox: "Archive/2024"
        )
        XCTAssertEqual(try count(store, "SELECT COUNT(*) FROM sync_state"), 2)
        XCTAssertEqual(try store.syncState(account: account, mailbox: "INBOX")?.highestUID, 10)
        XCTAssertEqual(try store.syncState(account: account, mailbox: "Archive/2024")?.highestUID, 999)
    }

    // MARK: - Upsert

    func testSetReplacesExistingCheckpoint() throws {
        let store = try makeStore()
        try store.setSyncState(
            SyncState(uidValidity: 1, highestUID: 10, highestModSeq: 100,
                      updatedAt: "2024-03-05T14:23:01Z"),
            account: account, mailbox: "INBOX"
        )
        try store.setSyncState(
            SyncState(uidValidity: 1, highestUID: 20, highestModSeq: 200,
                      updatedAt: "2024-03-05T15:00:00Z"),
            account: account, mailbox: "INBOX"
        )
        // Still one row for the mailbox; the checkpoint advanced.
        XCTAssertEqual(try count(store, "SELECT COUNT(*) FROM sync_state"), 1)
        let read = try store.syncState(account: account, mailbox: "INBOX")
        XCTAssertEqual(read?.highestUID, 20)
        XCTAssertEqual(read?.highestModSeq, 200)
        XCTAssertEqual(read?.updatedAt, "2024-03-05T15:00:00Z")
    }

    // MARK: - UIDVALIDITY reset (DESIGN 5 step 3)

    func testUidValidityChangeResetsHighWaterUID() throws {
        let store = try makeStore()
        // First sync under UIDVALIDITY 1: high-water UID 500.
        try store.setSyncState(
            SyncState(uidValidity: 1, highestUID: 500, highestModSeq: 5000,
                      updatedAt: "2024-03-05T14:23:01Z"),
            account: account, mailbox: "INBOX"
        )
        // The server reports a new UIDVALIDITY (2). The engine resets the
        // high-water UID to zero so the folder is re-fetched from the start
        // and nothing is skipped.
        try store.setSyncState(
            SyncState(uidValidity: 2, highestUID: 0, highestModSeq: nil,
                      updatedAt: "2024-03-05T16:00:00Z"),
            account: account, mailbox: "INBOX"
        )
        let read = try store.syncState(account: account, mailbox: "INBOX")
        XCTAssertEqual(read?.uidValidity, 2)
        XCTAssertEqual(read?.highestUID, 0)
        XCTAssertEqual(read?.highestModSeq, nil)
    }

    // MARK: - Clear

    func testClearRemovesCheckpoint() throws {
        let store = try makeStore()
        try store.setSyncState(
            SyncState(uidValidity: 1, highestUID: 10, highestModSeq: nil,
                      updatedAt: "2024-03-05T14:23:01Z"),
            account: account, mailbox: "INBOX"
        )
        try store.clearSyncState(account: account, mailbox: "INBOX")
        XCTAssertNil(try store.syncState(account: account, mailbox: "INBOX"))
        XCTAssertEqual(try count(store, "SELECT COUNT(*) FROM sync_state"), 0)
        // The account and mailbox rows remain; only the checkpoint is gone.
        XCTAssertEqual(try count(store, "SELECT COUNT(*) FROM account"), 1)
        XCTAssertEqual(try count(store, "SELECT COUNT(*) FROM mailbox"), 1)
    }

    func testClearIsNoOpForUnknownMailbox() throws {
        let store = try makeStore()
        // No checkpoint was ever written; clearing must not throw.
        try store.clearSyncState(account: account, mailbox: "INBOX")
        XCTAssertEqual(try count(store, "SELECT COUNT(*) FROM sync_state"), 0)
    }

    // MARK: - Migration forward

    func testIndexMigratesV15ArchiveToV16SyncState() throws {
        // Simulate an archive written before the sync engine (index at
        // core-v15, no sync_state table). Opening it must run core-v16
        // (create sync_state) without touching stored rows, and the migrated
        // schema must accept a checkpoint write.
        _ = try ArchiveStore.create(at: archiveURL, appVersion: "0.1.0")

        let indexURL = archiveURL.appendingPathComponent(ArchiveStore.indexName)
        let pool = try DatabasePool(path: indexURL.path)
        try IndexSchema.migrator(through: "core-v15").migrate(pool)
        try pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO message (hash, size, subject, normalizedSubject, dateSent, messageID, fromEmail)
                VALUES (x'01020304', 12, 'Old subject', 'old subject',
                        '2024-03-05T14:23:01Z', '<old@example.com>', 'alice@example.com')
                """
            )
        }

        let store = try ArchiveStore.open(at: archiveURL)
        // The old row is untouched.
        XCTAssertEqual(try count(store, "SELECT COUNT(*) FROM message"), 1)
        // The new table exists and is empty.
        XCTAssertEqual(try count(store, "SELECT COUNT(*) FROM sync_state"), 0)
        // The migrated schema accepts a checkpoint write.
        try store.setSyncState(
            SyncState(uidValidity: 7, highestUID: 42, highestModSeq: nil,
                      updatedAt: "2024-03-05T14:23:01Z"),
            account: account, mailbox: "INBOX"
        )
        XCTAssertEqual(try store.syncState(account: account, mailbox: "INBOX")?.highestUID, 42)
    }

    /// Decision 0062: opening an archive written before the profile column
    /// (index at core-v16) must add `providerJSON` without touching stored
    /// rows, and the migrated schema must accept a profile write.
    func testIndexMigratesV16ArchiveToV17ProfileColumn() throws {
        _ = try ArchiveStore.create(at: archiveURL, appVersion: "0.1.0")

        let indexURL = archiveURL.appendingPathComponent(ArchiveStore.indexName)
        let pool = try DatabasePool(path: indexURL.path)
        try IndexSchema.migrator(through: "core-v16").migrate(pool)
        try pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO message (hash, size, subject, normalizedSubject, dateSent, messageID, fromEmail)
                VALUES (x'01020304', 12, 'Old subject', 'old subject',
                        '2024-03-05T14:23:01Z', '<old@example.com>', 'alice@example.com')
                """
            )
        }

        let store = try ArchiveStore.open(at: archiveURL)
        // The old row is untouched.
        XCTAssertEqual(try count(store, "SELECT COUNT(*) FROM message"), 1)
        // The new column exists and is empty; unknown accounts report no
        // profile rather than throwing.
        XCTAssertNil(try store.accountProfileJSON(account: account))
        // The migrated schema accepts a profile write and reads it back.
        try store.setAccountProfile("{\"id\":\"x\"}", account: account)
        XCTAssertEqual(try store.accountProfileJSON(account: account), "{\"id\":\"x\"}")
    }

    // MARK: - Corrupt checkpoint

    func testCorruptCheckpointThrows() throws {
        let store = try makeStore()
        // Write a checkpoint, then corrupt the stored JSON directly.
        try store.setSyncState(
            SyncState(uidValidity: 1, highestUID: 10, highestModSeq: nil,
                      updatedAt: "2024-03-05T14:23:01Z"),
            account: account, mailbox: "INBOX"
        )
        try store.db.write { db in
            try db.execute(
                sql: "UPDATE sync_state SET checkpointJSON = 'not-json'"
            )
        }
        XCTAssertThrowsError(try store.syncState(account: account, mailbox: "INBOX")) { error in
            XCTAssertEqual(error as? ArchiveError, .corruptLayout("sync_state checkpoint"))
        }
    }
}
