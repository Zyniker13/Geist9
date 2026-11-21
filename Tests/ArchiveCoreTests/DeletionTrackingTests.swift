import XCTest
import GRDB
@testable import ArchiveCore

/// Deletion tracking (DESIGN 5 step 6): server-side deletions never delete
/// from the archive. After each sync pass the engine marks the memberships it
/// did not see, the index records "no longer on the server" with the date,
/// and the person decides (default: keep forever). Every test runs in a
/// temporary directory.
final class DeletionTrackingTests: XCTestCase {
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

    private func message(_ id: String, mailbox: String, uid: Int64, seen: String) throws -> (ArchiveStore, Int64) {
        let store = try makeStore()
        let data = Data("From: alice@example.com\r\nTo: bob@example.org\r\nSubject: \(id)\r\nMessage-ID: <\(id)@example.com>\r\n\r\nbody\r\n".utf8)
        let parsed = MailBridge.parse(for: data)
        var record = parsed.record
        record.dateReceived = Date(timeIntervalSince1970: 0)
        let result = try store.ingest(
            IngestedMessage(
                record: record,
                data: data,
                memberships: [Membership(mailbox: mailbox, uid: uid, flags: [], dateReceived: record.dateReceived)],
                searchText: parsed.searchText
            ),
            into: account
        )
        guard case .created(let rowID) = result else {
            XCTFail("expected created, got \(result)")
            throw ArchiveError.corruptLayout("test fixture")
        }
        // Stamp the membership's lastSeen to the given pass time, as a real
        // sync pass would have.
        try store.db.write { db in
            try db.execute(
                sql: "UPDATE message_mailbox SET lastSeen = ? WHERE messageID = ?",
                arguments: [seen, rowID]
            )
        }
        return (store, rowID)
    }

    private func ids(_ store: ArchiveStore, _ sql: String) throws -> [Int64] {
        try store.db.read { db in try Int64.fetchAll(db, sql: sql) }
    }

    private func removed(_ store: ArchiveStore, _ sql: String, _ args: [any GRDB.DatabaseValueConvertible] = []) throws -> Bool {
        try store.db.read { db in
            try Bool.fetchOne(db, sql: sql, arguments: StatementArguments(args)) ?? false
        }
    }

    // MARK: - Marking

    func testUnseenMembershipIsMarkedRemoved() throws {
        let (store, id) = try message("gone-1", mailbox: "INBOX", uid: 5, seen: "2024-03-05T14:00:00Z")
        let report = try markPass(store, ["INBOX"], cutoff: "2024-03-05T15:00:00Z")
        XCTAssertEqual(report.membershipsMarked, 1)
        XCTAssertEqual(report.newlyRemoved, 1)
        let row = try store.db.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT removedFromServer, lastSeen FROM message_mailbox WHERE messageID = ?",
                arguments: [id]
            )!
        }
        XCTAssertEqual(row["removedFromServer"] as Bool, true)
        XCTAssertEqual(row["lastSeen"] as String, "2024-03-05T15:00:00Z")
    }

    func testSeenMembershipStays() throws {
        let (store, _) = try message("kept-1", mailbox: "INBOX", uid: 6, seen: "2024-03-05T15:00:00Z")
        let report = try markPass(store, ["INBOX"], cutoff: "2024-03-05T15:00:00Z")
        XCTAssertEqual(report.membershipsMarked, 0)
        XCTAssertEqual(report.newlyRemoved, 0)
        XCTAssertFalse(try removed(store, "SELECT removedFromServer FROM message_mailbox"))
    }

    func testMarkIsIdempotent() throws {
        let (store, _) = try message("idem-1", mailbox: "INBOX", uid: 7, seen: "2024-03-05T14:00:00Z")
        _ = try markPass(store, ["INBOX"], cutoff: "2024-03-05T15:00:00Z")
        // A later pass with a NEWER cutoff must not re-mark or un-mark.
        let second = try markPass(store, ["INBOX"], cutoff: "2024-03-05T16:00:00Z")
        XCTAssertEqual(second.membershipsMarked, 0)
        XCTAssertEqual(try ids(store, "SELECT COUNT(*) FROM message_mailbox WHERE removedFromServer = 1").count, 1)
    }

    func testMessageInTwoFoldersNeedsBothRemoved() throws {
        let store = try makeStore()
        let data = Data("From: alice@example.com\r\nTo: bob@example.org\r\nSubject: cross\r\nMessage-ID: <cross@example.com>\r\n\r\nbody\r\n".utf8)
        let parsed = MailBridge.parse(for: data)
        let result = try store.ingest(
            IngestedMessage(
                record: parsed.record,
                data: data,
                memberships: [
                    Membership(mailbox: "INBOX", uid: 1, flags: [], dateReceived: nil),
                    Membership(mailbox: "Archive", uid: 2, flags: [], dateReceived: nil),
                ],
                searchText: parsed.searchText
            ),
            into: account
        )
        guard case .created(let rowID) = result else { XCTFail("expected created"); return }
        try store.db.write { db in
            try db.execute(sql: "UPDATE message_mailbox SET lastSeen = '2024-03-05T14:00:00Z'")
        }
        // Only INBOX was synced this pass: the message still lives in Archive.
        _ = try markPass(store, ["INBOX"], cutoff: "2024-03-05T15:00:00Z")
        XCTAssertTrue(try removed(
            store,
            "SELECT removedFromServer FROM message_mailbox mm JOIN mailbox mb ON mb.id = mm.mailboxID WHERE mm.messageID = ? AND mb.name = 'INBOX'",
            [rowID]
        ))
        XCTAssertFalse(try removed(
            store,
            "SELECT removedFromServer FROM message_mailbox mm JOIN mailbox mb ON mb.id = mm.mailboxID WHERE mm.messageID = ? AND mb.name = 'Archive'",
            [rowID]
        ))
        // The message itself is NOT gone from the server (one membership remains).
        XCTAssertEqual(try ids(store, "SELECT id FROM message m WHERE NOT EXISTS (SELECT 1 FROM message_mailbox mm WHERE mm.messageID = m.id AND mm.removedFromServer = 0)").count, 0)
        // Next pass syncs Archive: now every membership is removed.
        _ = try markPass(store, ["Archive"], cutoff: "2024-03-05T15:00:00Z")
        let gone = try ids(store, "SELECT COUNT(*) FROM message m WHERE NOT EXISTS (SELECT 1 FROM message_mailbox mm WHERE mm.messageID = m.id AND mm.removedFromServer = 0)").count
        XCTAssertEqual(gone, 1)
    }

    func testEmptyMailboxListIsANoOp() throws {
        let (store, _) = try message("noop-1", mailbox: "INBOX", uid: 8, seen: "2024-03-05T14:00:00Z")
        let report = try store.markUnseenMemberships(
            accountID: 1, mailboxIDs: [], cutoff: "2024-03-05T15:00:00Z", now: "2024-03-05T15:00:00Z"
        )
        XCTAssertEqual(report.membershipsMarked, 0)
        XCTAssertEqual(report.newlyRemoved, 0)
        XCTAssertFalse(try removed(store, "SELECT removedFromServer FROM message_mailbox"))
    }

    func testOnlyNamedMailboxesAreMarked() throws {
        let (store, _) = try message("other-1", mailbox: "Projects", uid: 9, seen: "2024-03-05T14:00:00Z")
        // The pass covered INBOX only; Projects' membership is untouched.
        _ = try markPass(store, ["INBOX"], cutoff: "2024-03-05T15:00:00Z")
        XCTAssertFalse(try removed(store, "SELECT removedFromServer FROM message_mailbox"))
    }

    // MARK: - Marked message stays searchable and its bytes stay

    func testMarkedMessageBytesAndIndexRowsRemain() throws {
        let (store, id) = try message("keep-1", mailbox: "INBOX", uid: 10, seen: "2024-03-05T14:00:00Z")
        _ = try markPass(store, ["INBOX"], cutoff: "2024-03-05T15:00:00Z")
        // The message row and its stored bytes survive untouched.
        XCTAssertEqual(try ids(store, "SELECT id FROM message").count, 1)
        let hash = try store.db.read { db in
            try Data.fetchOne(db, sql: "SELECT hash FROM message WHERE id = ?", arguments: [id])
        }
        let fileURL = try store.fileURL(for: MessageHash(bytes: hash!))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    // MARK: - Helpers

    /// Runs one mark pass against the named mailboxes, resolving mailbox ids
    /// the way the engine does (by account + folder name). The id lookup and
    /// the mark are two separate database calls: markUnseenMemberships opens
    /// its own write transaction and GRDB forbids nesting.
    private func markPass(_ store: ArchiveStore, _ mailboxes: [String], cutoff: String) throws -> DeletionReport {
        let accountID: Int64 = try store.db.read { db in
            try Int64.fetchOne(
                db, sql: "SELECT id FROM account WHERE email = ?", arguments: [account.email]
            )!
        }
        var mailboxIDs: [Int64] = []
        for name in mailboxes {
            let id: Int64? = try store.db.read { db in
                try Int64.fetchOne(
                    db, sql: "SELECT id FROM mailbox WHERE accountID = ? AND name = ?",
                    arguments: [accountID, name]
                )
            }
            if let id { mailboxIDs.append(id) }
        }
        return try store.markUnseenMemberships(
            accountID: accountID, mailboxIDs: mailboxIDs, cutoff: cutoff, now: cutoff
        )
    }
}
