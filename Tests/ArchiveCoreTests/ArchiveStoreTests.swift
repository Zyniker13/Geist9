import XCTest
import GRDB
@testable import ArchiveCore

/// ArchiveStore: creation, manifest validation, content-addressed storage,
/// ingest transactions, scrub. Every test runs in a temporary directory.
final class ArchiveStoreTests: XCTestCase {
    private var tempDir: URL!

    private func count(_ store: ArchiveStore, _ sql: String) throws -> Int {
        try store.db.read { db in try Int.fetchOne(db, sql: sql) ?? 0 }
    }

    private func singleRow(_ store: ArchiveStore, _ sql: String) throws -> Row {
        try store.db.read { db in try Row.fetchOne(db, sql: sql)! }
    }

    private func scalar(_ store: ArchiveStore, _ sql: String) throws -> String? {
        try store.db.read { db in try String.fetchOne(db, sql: sql) }
    }

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

    private func makeSampleMessage(_ body: String = "hello", subject: String = "Hi") -> IngestedMessage {
        let record = MessageRecord(
            subject: subject,
            dateSent: Timestamp.date("2024-03-05T14:23:01Z"),
            dateReceived: Timestamp.date("2024-03-05T14:23:05Z"),
            messageID: "abc123@example.com",
            from: Recipient(name: "Alice", email: "alice@example.com"),
            to: [Recipient(name: "Bob", email: "bob@example.org")]
        )
        let data = Data("""
        From: Alice <alice@example.com>
        To: Bob <bob@example.org>
        Subject: \(subject)
        Message-ID: <abc123@example.com>

        \(body)
        """.utf8)
        return IngestedMessage(
            record: record,
            data: data,
            memberships: [Membership(mailbox: "INBOX", uid: 7, flags: ["\\Seen"])]
        )
    }

    // MARK: Creation and manifest

    func testCreateWritesManifestAndLayout() throws {
        _ = try ArchiveStore.create(at: archiveURL, appVersion: "0.1.0")
        XCTAssertTrue(ArchiveStore.isArchiveDirectory(archiveURL))
        let manifestData = try Data(contentsOf: archiveURL.appendingPathComponent("manifest.json"))
        let json = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        XCTAssertEqual(json?["formatVersion"] as? Int, 2)
        XCTAssertEqual(json?["appVersion"] as? String, "0.1.0")
        let encryption = json?["encryption"] as? [String: Any]
        XCTAssertEqual(encryption?["enabled"] as? Bool, false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.appendingPathComponent("messages").path))
    }

    func testCreateRefusesNonEmptyDirectory() throws {
        try FileManager.default.createDirectory(at: archiveURL, withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: archiveURL.appendingPathComponent("user-file.txt"))
        XCTAssertThrowsError(try ArchiveStore.create(at: archiveURL, appVersion: "0.1.0")) { error in
            XCTAssertEqual(error as? ArchiveError, .notAnArchive)
        }
    }

    func testOpenRejectsUnknownFormatVersion() throws {
        _ = try ArchiveStore.create(at: archiveURL, appVersion: "0.1.0")
        // A future app wrote a newer manifest; this build must refuse to open.
        var future = try JSONSerialization.jsonObject(with: Data(contentsOf: archiveURL.appendingPathComponent("manifest.json"))) as! [String: Any]
        future["formatVersion"] = 99
        let data = try JSONSerialization.data(withJSONObject: future, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: archiveURL.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try ArchiveStore.open(at: archiveURL)) { error in
            XCTAssertEqual(error as? ArchiveError, .unsupportedFormatVersion(99))
        }
    }

    func testIndexMigratesV1ArchiveToCurrentSchema() throws {
        // Simulate an archive written by the M1.1–M1.9 build: manifest
        // formatVersion 1 and an index with only core-v1 applied, holding a
        // real row. Opening it must run core-v2 (add the import provenance
        // columns) without touching the stored row.
        _ = try ArchiveStore.create(at: archiveURL, appVersion: "0.1.0")
        var manifestV1 = try JSONSerialization.jsonObject(
            with: Data(contentsOf: archiveURL.appendingPathComponent("manifest.json"))
        ) as! [String: Any]
        manifestV1["formatVersion"] = 1
        try JSONSerialization.data(
            withJSONObject: manifestV1, options: [.prettyPrinted, .sortedKeys]
        ).write(to: archiveURL.appendingPathComponent("manifest.json"))

        let indexURL = archiveURL.appendingPathComponent(ArchiveStore.indexName)
        let pool = try DatabasePool(path: indexURL.path)
        try IndexSchema.migrator(through: "core-v1").migrate(pool)
        try pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO account (email, displayName, providerKind)
                VALUES ('alice@example.com', 'Alice', 'imap')
                """
            )
            try db.execute(
                sql: """
                INSERT INTO message (hash, size, subject, normalizedSubject, dateSent, messageID, fromEmail)
                VALUES (x'01020304', 12, 'Old subject', 'old subject',
                        '2024-03-05T14:23:01Z', '<old@example.com>', 'alice@example.com')
                """
            )
        }

        let store = try ArchiveStore.open(at: archiveURL)
        let row = try singleRow(
            store,
            "SELECT subject, fromEmail, importSource, providerThreadID FROM message"
        )
        XCTAssertEqual(row["subject"] as? String, "Old subject")
        XCTAssertEqual(row["fromEmail"] as? String, "alice@example.com")
        // New columns exist (added by core-v2) and are NULL for the old row;
        // the row itself was not rewritten.
        XCTAssertNil(row["importSource"] as? String)
        XCTAssertNil(row["providerThreadID"] as? String)
        // The migrated index accepts inserts with the new columns.
        try store.db.write { db in
            try db.execute(
                sql: """
                INSERT INTO message (hash, size, subject, importSource, providerThreadID)
                VALUES (x'05060708', 8, 'New subject', 'emlFolder', '<new@example.com>')
                """
            )
        }
        XCTAssertEqual(try count(store, "SELECT COUNT(*) FROM message"), 2)
    }

    func testOpenRejectsNonArchiveDirectory() throws {
        try FileManager.default.createDirectory(at: archiveURL, withIntermediateDirectories: true)
        XCTAssertThrowsError(try ArchiveStore.open(at: archiveURL)) { error in
            XCTAssertEqual(error as? ArchiveError, .notAnArchive)
        }
    }

    func testManifestRoundTrip() throws {
        let url = tempDir.appendingPathComponent("m.json")
        let manifest = ArchiveManifest(createdAt: Timestamp.date("2026-11-17T12:00:00Z")!, appVersion: "0.1.0")
        try manifest.write(to: url)
        let read = try ArchiveManifest.read(from: url)
        XCTAssertEqual(read, manifest)
    }

    // MARK: Content-addressed storage

    func testPutMessageWritesShardedFileAndRoundTrips() throws {
        let store = try ArchiveStore.create(at: archiveURL, appVersion: "0.1.0")
        let data = Data("original bytes, kept exactly".utf8)
        let hash = try store.putMessage(data)
        XCTAssertEqual(hash.hex.count, 64)
        // messages/ab/cd/<64 hex>.eml
        let path = ArchiveStore.relativePath(for: hash)
        XCTAssertTrue(path.hasPrefix("messages/") && path.hasSuffix(".eml"))
        XCTAssertTrue(try store.messageData(hash).elementsEqual(data))
        XCTAssertTrue(store.hasMessage(hash))
    }

    func testPutMessageIsDeduplicated() throws {
        let store = try ArchiveStore.create(at: archiveURL, appVersion: "0.1.0")
        let data = Data("same bytes twice".utf8)
        let h1 = try store.putMessage(data)
        let h2 = try store.putMessage(data)
        XCTAssertEqual(h1, h2)
        // Exactly one file on disk.
        XCTAssertEqual(try countEMLFiles(store), 1)
    }

    func testMessageDataThrowsForUnknownHash() throws {
        let store = try ArchiveStore.create(at: archiveURL, appVersion: "0.1.0")
        let unknown = MessageHash.sha256(Data("never stored".utf8))
        XCTAssertThrowsError(try store.messageData(unknown)) { error in
            XCTAssertEqual(error as? ArchiveError, .messageNotFound(unknown))
        }
    }

    // MARK: Ingest

    func testIngestStoresFileAndIndexRows() throws {
        let store = try ArchiveStore.create(at: archiveURL, appVersion: "0.1.0")
        let message = makeSampleMessage()
        let result = try store.ingest(message, into: AccountIdentity(
            email: "alice@example.com", displayName: "Alice Personal", providerKind: "import"
        ))
        guard case .created(let id) = result else {
            return XCTFail("expected created, got \(result)")
        }
        // File exists and bytes round-trip.
        XCTAssertTrue(try store.messageData(MessageHash.sha256(message.data)).elementsEqual(message.data))
        // Index rows.
        let messageCount = try count(store, "SELECT COUNT(*) FROM message")
        XCTAssertEqual(messageCount, 1)
        let mailbox = try singleRow(store, "SELECT * FROM mailbox")
        XCTAssertEqual(mailbox["name"] as String, "INBOX")
        XCTAssertEqual(mailbox["role"] as String?, "inbox")
        let membership = try singleRow(store, "SELECT * FROM message_mailbox")
        XCTAssertEqual(membership["uid"] as Int64?, 7)
        XCTAssertEqual(membership["flags"] as String?, "\\seen")
        let addressCount = try count(store, "SELECT COUNT(*) FROM address")
        XCTAssertEqual(addressCount, 2)
        let fromKind = try scalar(store, "SELECT kind FROM message_address ma JOIN address a ON a.id = ma.addressID WHERE a.email = 'alice@example.com'")
        XCTAssertEqual(fromKind, "from")
        XCTAssertEqual(id, 1)
    }

    func testReIngestAddsNothingTwice() throws {
        let store = try ArchiveStore.create(at: archiveURL, appVersion: "0.1.0")
        let account = AccountIdentity(email: "alice@example.com", displayName: "Alice", providerKind: "import")
        let message = makeSampleMessage()
        let first = try store.ingest(message, into: account)
        let second = try store.ingest(message, into: account)
        guard case .duplicate(let sameID) = second else {
            return XCTFail("expected duplicate, got \(second)")
        }
        guard case .created(let id) = first else { return XCTFail("expected created") }
        XCTAssertEqual(id, sameID)
        XCTAssertEqual(try count(store, "SELECT COUNT(*) FROM message"), 1)
        XCTAssertEqual(try count(store, "SELECT COUNT(*) FROM message_mailbox"), 1)
        XCTAssertEqual(try countEMLFiles(store), 1)
    }

    func testSameBytesInAnotherMailboxAddsOnlyMembership() throws {
        let store = try ArchiveStore.create(at: archiveURL, appVersion: "0.1.0")
        let account = AccountIdentity(email: "alice@example.com", displayName: "Alice", providerKind: "import")
        var message = makeSampleMessage()
        message.memberships = [Membership(mailbox: "INBOX")]
        _ = try store.ingest(message, into: account)
        message.memberships = [Membership(mailbox: "Archive/2024")]
        let second = try store.ingest(message, into: account)
        guard case .duplicate = second else { return XCTFail("expected duplicate") }
        XCTAssertEqual(try count(store, "SELECT COUNT(*) FROM message"), 1)
        XCTAssertEqual(try count(store, "SELECT COUNT(*) FROM mailbox"), 2)
        XCTAssertEqual(try count(store, "SELECT COUNT(*) FROM message_mailbox"), 2)
    }

    func testIngestMergesFlagsAndUpdatesLastSeen() throws {
        let store = try ArchiveStore.create(at: archiveURL, appVersion: "0.1.0")
        let account = AccountIdentity(email: "alice@example.com", displayName: "Alice", providerKind: "imap")
        var message = makeSampleMessage()
        message.memberships = [Membership(mailbox: "INBOX", uid: 7, flags: ["\\Seen"])]
        _ = try store.ingest(message, into: account)
        message.memberships = [Membership(mailbox: "INBOX", uid: 7, flags: ["\\Flagged", "$label1"])]
        _ = try store.ingest(message, into: account)
        let flags = try scalar(store, "SELECT flags FROM message_mailbox")!
        XCTAssertEqual(flags, "\\seen \\flagged $label1")
        XCTAssertEqual(try count(store, "SELECT COUNT(*) FROM message_mailbox"), 1)
    }

    func testIngestRecordsLabelsAndAttachments() throws {
        let store = try ArchiveStore.create(at: archiveURL, appVersion: "0.1.0")
        let message = makeSampleMessage()
        var enriched = message
        enriched.labels = [LabelName(name: "work")]
        enriched.attachments = [AttachmentInfo(partIndex: "2", filename: "report.pdf", contentType: "application/pdf", size: 900)]
        _ = try store.ingest(enriched, into: AccountIdentity(email: "alice@example.com", displayName: "Alice", providerKind: "import"))
        XCTAssertEqual(try count(store, "SELECT COUNT(*) FROM message_label"), 1)
        let attachment = try singleRow(store, "SELECT * FROM attachment")
        XCTAssertEqual(attachment["filename"] as String?, "report.pdf")
        XCTAssertEqual(attachment["textState"] as String?, "pending")
    }

    // MARK: Scrub

    func testScrubCleanArchive() throws {
        let store = try ArchiveStore.create(at: archiveURL, appVersion: "0.1.0")
        _ = try store.ingest(makeSampleMessage(), into: AccountIdentity(email: "a@x.com", displayName: "A", providerKind: "import"))
        let report = try store.scrub()
        XCTAssertTrue(report.isClean)
        XCTAssertEqual(report.filesVerified, 1)
    }

    func testScrubDetectsModifiedFileBytes() throws {
        let store = try ArchiveStore.create(at: archiveURL, appVersion: "0.1.0")
        let message = makeSampleMessage()
        _ = try store.ingest(message, into: AccountIdentity(email: "a@x.com", displayName: "A", providerKind: "import"))
        let hash = MessageHash.sha256(message.data)
        // Corrupt the stored bytes in place (simulating disk damage or a bad tool).
        let url = store.fileURL(for: hash)
        var data = try Data(contentsOf: url)
        data[0] ^= 0xFF
        try data.write(to: url)
        let report = try store.scrub()
        XCTAssertEqual(report.hashMismatches, [hash])
        XCTAssertFalse(report.isClean)
    }

    func testScrubDetectsMissingFile() throws {
        let store = try ArchiveStore.create(at: archiveURL, appVersion: "0.1.0")
        let message = makeSampleMessage()
        _ = try store.ingest(message, into: AccountIdentity(email: "a@x.com", displayName: "A", providerKind: "import"))
        // Remove the file: the index now outlives its bytes.
        let hash = MessageHash.sha256(message.data)
        try FileManager.default.removeItem(at: store.fileURL(for: hash))
        let report = try store.scrub()
        XCTAssertEqual(report.missingFiles, [hash])
        XCTAssertEqual(report.filesVerified, 0)
    }

    func testScrubDetectsUnindexedFile() throws {
        let store = try ArchiveStore.create(at: archiveURL, appVersion: "0.1.0")
        // Put bytes without ingesting (e.g. a crashed import between file and index).
        let data = Data("orphaned file".utf8)
        _ = try store.putMessage(data)
        let report = try store.scrub()
        XCTAssertEqual(report.unindexedFiles, [MessageHash.sha256(data).hex])
    }

    func testScrubFlagsForeignFilesAsCorruptLayout() throws {
        let store = try ArchiveStore.create(at: archiveURL, appVersion: "0.1.0")
        let weird = store.messagesDirectory.appendingPathComponent("zz/yy/not-a-hash.eml")
        try FileManager.default.createDirectory(at: weird.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("junk".utf8).write(to: weird)
        let report = try store.scrub()
        XCTAssertEqual(report.corruptLayout, ["zz/yy/not-a-hash.eml"])
    }

    // MARK: Queries

    func testListNewestFirst() throws {
        let store = try ArchiveStore.create(at: archiveURL, appVersion: "0.1.0")
        let account = AccountIdentity(email: "a@x.com", displayName: "A", providerKind: "import")
        var first = makeSampleMessage(subject: "First")
        first.record.dateReceived = Timestamp.date("2024-03-05T10:00:00Z")
        _ = try store.ingest(first, into: account)
        var second = makeSampleMessage(subject: "Second")
        second.record.dateReceived = Timestamp.date("2024-03-06T10:00:00Z")
        _ = try store.ingest(second, into: account)
        let list = try store.listMessages(mailbox: "INBOX", newestFirst: true, limit: 10)
        XCTAssertEqual(list.map(\.subject), ["Second", "First"])
    }

    // MARK: Timestamps

    func testTimestampRoundTripAndOrdering() {
        let a = Timestamp.date("2024-03-05T14:23:01Z")!
        let b = Timestamp.date("2024-03-05T14:23:02Z")!
        XCTAssertLessThan(Timestamp.string(a), Timestamp.string(b))
        XCTAssertEqual(Timestamp.date(Timestamp.string(a)), a)
        XCTAssertNil(Timestamp.date("nonsense"))
        XCTAssertNil(Timestamp.date("2024-13-05T14:23:01Z"))
    }

    private func countEMLFiles(_ store: ArchiveStore) throws -> Int {
        var count = 0
        let fm = FileManager.default
        let enumerator = fm.enumerator(at: store.messagesDirectory, includingPropertiesForKeys: nil)!
        for case let url as URL in enumerator where url.pathExtension == "eml" {
            count += 1
        }
        return count
    }
}
