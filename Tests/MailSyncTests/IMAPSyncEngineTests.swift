import ArchiveCore
import GRDB
import XCTest
@testable import MailSync

/// The IMAP sync engine against the in-process fake server (real wire
/// protocol both directions, driven by swift-nio-imap's own server codec).
/// Every test runs its own server on a fresh loopback port and its own
/// temporary archive; nothing here touches a real account.
///
/// The safety assertion runs in every test: the engine must only ever send
/// LOGIN, ID, LIST, STATUS, SELECT, and UID FETCH. A STORE, EXPUNGE, MOVE,
/// COPY, or APPEND on the wire fails the test — the engine is read-only
/// toward the server, no exceptions (DESIGN 5).
final class IMAPSyncEngineTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("geist9-sync-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
    }

    // MARK: - Fixtures

    private let account = AccountIdentity(
        email: "alice@example.com", displayName: "Alice", providerKind: "imap"
    )

    /// A small RFC 822 message with distinct content per uid.
    private func message(_ subject: String, body: String = "hello") -> Data {
        Data((
            "From: Bob <bob@example.org>\r\n" +
            "To: Alice <alice@example.com>\r\n" +
            "Subject: \(subject)\r\n" +
            "Date: Mon, 20 Jan 2026 10:00:00 +0000\r\n" +
            "Message-ID: <\(subject)@example.org>\r\n" +
            "\r\n" +
            body + "\r\n"
        ).utf8)
    }

    private func makeStore() throws -> ArchiveStore {
        try ArchiveStore.create(at: tempDir.appendingPathComponent("Test.emailarchive"), appVersion: "0.1.0")
    }

    private func profile(port: UInt16) -> ProviderProfile {
        ProviderProfile(
            id: "test",
            displayName: "Test",
            host: "127.0.0.1",
            tls: .starttls(port: Int(port)), // no real TLS needed: plain loopback server
            credential: .appPassword,
            domains: []
        )
    }

    /// The read-only command set the engine may send.
    private static let readOnlyCommands: Set<String> = [
        "LOGIN", "ID", "LIST", "STATUS", "SELECT", "UID FETCH", "UID SEARCH", "LOGOUT", "NOOP",
    ]

    private func assertReadOnly(_ server: FakeIMAPServer) {
        for command in server.seenCommands {
            XCTAssertTrue(
                Self.readOnlyCommands.contains(command),
                "engine sent a mutating or unexpected command: \(command)"
            )
        }
    }

    // MARK: - Helpers for assertions

    private func count(_ store: ArchiveStore, _ sql: String) throws -> Int {
        try store.db.read { db in try Int.fetchOne(db, sql: sql) ?? 0 }
    }

    private func syncState(_ store: ArchiveStore, _ mailbox: String) throws -> SyncState? {
        try store.syncState(account: account, mailbox: mailbox)
    }

    // MARK: - Full sync

    func testFullSyncStoresMessagesWithUIDsAndCheckpoint() async throws {
        let scenario = FakeServerScenario(folders: [
            FakeFolder(
                name: "INBOX",
                messages: [
                    FakeMessage(uid: 1, data: message("alpha")),
                    FakeMessage(uid: 2, data: message("beta")),
                    FakeMessage(uid: 5, data: message("gamma")),
                ],
                uidValidity: 7
            ),
        ])
        let server = FakeIMAPServer(scenario: scenario)
        try server.start()
        defer { server.stop() }

        let store = try makeStore()
        let engine = IMAPSyncEngine(profile: profile(port: server.port), account: account)
        let progress = try await runSync(engine, store: store)

        XCTAssertEqual(progress.messagesStored, 3)
        XCTAssertEqual(progress.messagesDuplicate, 0)
        XCTAssertEqual(progress.foldersListed, 1)
        // Every message stored, keyed by uid.
        let stored = try await store.db.read { db -> [(subject: String, uid: Int64)] in
            try Row.fetchAll(db, sql: """
                SELECT m.subject, mm.uid FROM message m
                JOIN message_mailbox mm ON mm.messageID = m.id
                """).map { row in
                (subject: row["subject"] ?? "", uid: row["uid"] ?? 0)
            }
        }
        XCTAssertEqual(stored.count, 3)
        XCTAssertEqual(Set(stored.map { $0.uid }), Set([1, 2, 5]))
        XCTAssertEqual(
            Set(stored.map { $0.subject }),
            Set(["alpha", "beta", "gamma"])
        )
        // The checkpoint reached the folder's highest UID.
        let state = try syncState(store, "INBOX")
        XCTAssertEqual(state?.uidValidity, 7)
        XCTAssertEqual(state?.highestUID, 5)
        self.assertReadOnly(server)
    }

    func testSyncHonorsFolderByteBudgetAcrossBatches() async throws {
        // Two folders, each message ~600 bytes; a budget of 1,000 bytes
        // forces multiple batches per folder and both folders still sync.
        let scenario = FakeServerScenario(folders: [
            FakeFolder(
                name: "INBOX",
                messages: (1...4).map { FakeMessage(uid: UInt32($0), data: message("m\($0)", body: String(repeating: "x", count: 400))) },
                uidValidity: 1
            ),
        ])
        let server = FakeIMAPServer(scenario: scenario)
        try server.start()
        defer { server.stop() }

        let store = try makeStore()
        let engine = IMAPSyncEngine(
            profile: profile(port: server.port), account: account, batchBytes: 1000
        )
        let progress = try await runSync(engine, store: store)
        XCTAssertEqual(progress.messagesStored, 4)
        // Checkpoint covers the whole folder.
        XCTAssertEqual(try syncState(store, "INBOX")?.highestUID, 4)
        self.assertReadOnly(server)
    }

    // MARK: - Incremental sync

    func testIncrementalSyncFetchesOnlyAboveCheckpoint() async throws {
        let messages = (1...5).map { FakeMessage(uid: UInt32($0), data: message("m\($0)")) }
        let scenario = FakeServerScenario(folders: [
            FakeFolder(name: "INBOX", messages: messages, uidValidity: 3),
        ])
        let server = FakeIMAPServer(scenario: scenario)
        try server.start()
        defer { server.stop() }

        let store = try makeStore()
        let engine = IMAPSyncEngine(profile: profile(port: server.port), account: account)

        // First pass: everything.
        let first = try await runSync(engine, store: store)
        XCTAssertEqual(first.messagesStored, 5)
        // Second pass: nothing new, nothing re-fetched.
        let second = try await runSync(engine, store: store)
        XCTAssertEqual(second.messagesStored, 0)
        XCTAssertEqual(second.messagesDuplicate, 0)
        // The server saw: pass 1 = one full batch (the wrap-guarded loop no
        // longer sends an empty probe after the last message — it stops at
        // the folder's highest live UID); pass 2 = zero fetches, because the
        // checkpoint already sits at that highest UID. A pass that
        // re-fetched the folder would push the count past 1.
        let fetchCount = server.seenCommands.filter { $0 == "UID FETCH" }.count
        XCTAssertEqual(fetchCount, 1, "incremental pass must not re-fetch the folder")
        self.assertReadOnly(server)
    }

    func testNewMessagesOnlyFetchedOnLaterPass() async throws {
        var messages = (1...3).map { FakeMessage(uid: UInt32($0), data: message("m\($0)")) }
        let scenario = FakeServerScenario(folders: [
            FakeFolder(name: "INBOX", messages: messages, uidValidity: 2),
        ])
        let server = FakeIMAPServer(scenario: scenario)
        try server.start()
        defer { server.stop() }

        let store = try makeStore()
        let engine = IMAPSyncEngine(profile: profile(port: server.port), account: account)
        _ = try await runSync(engine, store: store)

        // Mail arrives on the server; the next pass fetches only the new UIDs.
        messages.append(contentsOf: [
            FakeMessage(uid: 4, data: message("m4")),
            FakeMessage(uid: 5, data: message("m5")),
        ])
        server.updateFolders([FakeFolder(name: "INBOX", messages: messages, uidValidity: 2)])
        let second = try await runSync(engine, store: store)
        XCTAssertEqual(second.messagesStored, 2)
        XCTAssertEqual(second.messagesDuplicate, 0)
        let stored = try await store.db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message") ?? 0
        }
        XCTAssertEqual(stored, 5)
        XCTAssertEqual(try syncState(store, "INBOX")?.highestUID, 5)
        self.assertReadOnly(server)
    }

    // MARK: - STATUS item quirks

    /// A server without CONDSTORE/QRESYNC rejects HIGHESTMODSEQ in STATUS
    /// with a tagged NO naming the item (GreenMail 2.1.3 does exactly this).
    /// The pass must still succeed: the engine retries the STATUS without the
    /// refused item and records a nil mod-sequence.
    func testStatusRefusingHighestModSeqStillSyncs() async throws {
        var scenario = FakeServerScenario(folders: [
            FakeFolder(
                name: "INBOX",
                messages: [
                    FakeMessage(uid: 1, data: message("alpha")),
                    FakeMessage(uid: 2, data: message("beta")),
                ],
                uidValidity: 7
            ),
        ])
        scenario.refuseStatusItems = ["HIGHESTMODSEQ"]
        let server = FakeIMAPServer(scenario: scenario)
        try server.start()
        defer { server.stop() }

        let store = try makeStore()
        let engine = IMAPSyncEngine(profile: profile(port: server.port), account: account)
        let progress = try await runSync(engine, store: store)

        XCTAssertEqual(progress.messagesStored, 2, "the pass succeeds without HIGHESTMODSEQ")
        XCTAssertEqual(try self.count(store, "SELECT COUNT(*) FROM message"), 2)
        let state = try self.syncState(store, "INBOX")
        XCTAssertEqual(state?.uidValidity, 7)
        XCTAssertEqual(state?.highestUID, 2)
        self.assertReadOnly(server)
    }

    // MARK: - Star-range wrap

    /// RFC 3501 §6.4.8: a UID range "n:*" whose lower bound exceeds the
    /// folder's highest UID still matches the last message. Real servers
    /// (GreenMail) answer a stale incremental window with that message
    /// forever; the engine must not re-fetch it in a loop. The incremental
    /// pass bounds its fetch window by the folder's known highest UID (from
    /// its own UID SEARCH) and stops once it is above it.
    func testIncrementalPassStopsWhenWindowExceedsHighestUID() async throws {
        var scenario = FakeServerScenario(folders: [
            FakeFolder(
                name: "INBOX",
                messages: [
                    FakeMessage(uid: 1, data: message("alpha")),
                    FakeMessage(uid: 2, data: message("beta")),
                    FakeMessage(uid: 3, data: message("gamma")),
                ],
                uidValidity: 7
            ),
        ])
        // Full pass: everything stored once.
        let server = FakeIMAPServer(scenario: scenario)
        try server.start()
        defer { server.stop() }

        let store = try makeStore()
        let engine = IMAPSyncEngine(profile: profile(port: server.port), account: account)
        let full = try await runSync(engine, store: store)
        XCTAssertEqual(full.messagesStored, 3)

        // No server-side change. The next pass must send exactly ONE UID
        // FETCH (the empty-window probe above the checkpoint) and must NOT
        // loop: with the wrap bug the stale "4:*" window re-matches UID 3
        // forever, piling thousands of duplicate ingests.
        let incremental = try await runSync(engine, store: store)
        XCTAssertEqual(incremental.messagesStored, 0)
        let fetchCount = server.seenCommands.filter { $0 == "UID FETCH" }.count
        XCTAssertEqual(
            fetchCount, 1,
            "an unchanged folder pass probes once above the checkpoint; more fetches mean the star-range wrap re-matches the last UID"
        )
        XCTAssertEqual(try self.count(store, "SELECT COUNT(*) FROM message"), 3)
        self.assertReadOnly(server)
    }

    // MARK: - UIDVALIDITY change

    func testUIDValidityChangeResetsHighWaterAndRefetches() async throws {
        let scenario = FakeServerScenario(folders: [
            FakeFolder(
                name: "INBOX",
                messages: [FakeMessage(uid: 1, data: message("old-a")), FakeMessage(uid: 2, data: message("old-b"))],
                uidValidity: 10
            ),
        ])
        let server = FakeIMAPServer(scenario: scenario)
        try server.start()
        defer { server.stop() }

        let store = try makeStore()
        let engine = IMAPSyncEngine(profile: profile(port: server.port), account: account)
        _ = try await runSync(engine, store: store)
        XCTAssertEqual(try syncState(store, "INBOX")?.highestUID, 2)

        // The mailbox is rebuilt with a new validity; UID 1 is now a
        // different message. The engine resets the high-water mark and
        // re-fetches; dedupe keeps every distinct message exactly once.
        server.updateFolders([
            FakeFolder(
                name: "INBOX",
                messages: [FakeMessage(uid: 1, data: message("old-a")), FakeMessage(uid: 2, data: message("new-b"))],
                uidValidity: 99
            ),
        ])
        _ = try await runSync(engine, store: store)
        let state = try syncState(store, "INBOX")
        XCTAssertEqual(state?.uidValidity, 99)
        XCTAssertEqual(state?.highestUID, 2)
        // "old-a" (identical bytes, deduped), "old-b" (still stored, now
        // removed from the server), "new-b" (new bytes).
        let subjects = try await store.db.read { db in
            try Set(String.fetchAll(db, sql: "SELECT subject FROM message"))
        }
        XCTAssertEqual(subjects, Set(["old-a", "old-b", "new-b"]))
        self.assertReadOnly(server)
    }

    // MARK: - Byte budget: batch ends above its last UID

    func testBatchEndsAboveLastFetchedUID() async throws {
        // Budget fits exactly one message: each batch stores one and the
        // window must advance past it, not re-offer the same UID forever.
        let scenario = FakeServerScenario(folders: [
            FakeFolder(
                name: "INBOX",
                messages: (1...3).map { FakeMessage(uid: UInt32($0), data: message("m\($0)", body: String(repeating: "y", count: 500))) },
                uidValidity: 4
            ),
        ])
        let server = FakeIMAPServer(scenario: scenario)
        try server.start()
        defer { server.stop() }

        let store = try makeStore()
        let engine = IMAPSyncEngine(
            profile: profile(port: server.port), account: account, batchBytes: 700
        )
        let progress = try await runSync(engine, store: store)
        XCTAssertEqual(progress.messagesStored, 3)
        XCTAssertEqual(progress.messagesDuplicate, 0, "no message may be fetched twice in one pass")
        XCTAssertEqual(try syncState(store, "INBOX")?.highestUID, 3)
        self.assertReadOnly(server)
    }

    // MARK: - Deletion tracking integration

    func testDeletionTrackingMarksUnseenMembershipsAcrossPass() async throws {
        let scenario = FakeServerScenario(folders: [
            FakeFolder(
                name: "INBOX",
                messages: [FakeMessage(uid: 1, data: message("kept")), FakeMessage(uid: 2, data: message("deleted"))],
                uidValidity: 6
            ),
            FakeFolder(name: "Archive", messages: [], uidValidity: 1),
        ])
        let server = FakeIMAPServer(scenario: scenario)
        try server.start()
        defer { server.stop() }

        let store = try makeStore()
        let engine = IMAPSyncEngine(profile: profile(port: server.port), account: account)
        _ = try await runSync(engine, store: store)

        // Both messages stored and both flagged seen in this pass.
        var keptGone = try membershipIsRemoved(store, "kept")
        var deletedGone = try membershipIsRemoved(store, "deleted")
        XCTAssertFalse(keptGone)
        XCTAssertFalse(deletedGone)

        // The server loses "deleted" (and its folder keeps the rest).
        server.updateFolders([
            FakeFolder(
                name: "INBOX",
                messages: [FakeMessage(uid: 1, data: message("kept"))],
                uidValidity: 6
            ),
            FakeFolder(name: "Archive", messages: [], uidValidity: 1),
        ])
        let second = try await runSync(engine, store: store)
        // Nothing was fetched; the pass only marks deletions.
        XCTAssertEqual(second.messagesStored, 0)
        keptGone = try membershipIsRemoved(store, "kept")
        deletedGone = try membershipIsRemoved(store, "deleted")
        XCTAssertFalse(keptGone, "a message still on the server stays live")
        XCTAssertTrue(deletedGone, "a message gone from the server is marked, never deleted")

        // The archive keeps the bytes AND the full searchable text.
        let deletedBytes = try bytes(store, "deleted")
        XCTAssertEqual(deletedBytes, message("deleted"), "stored bytes are never touched")
        let hits = try searchCount(store, "deleted")
        XCTAssertEqual(hits, 1, "a server-deleted message stays searchable")
        self.assertReadOnly(server)
    }

    func testFolderThatVanishedKeepsItsMessages() async throws {
        let scenario = FakeServerScenario(folders: [
            FakeFolder(
                name: "INBOX",
                messages: [FakeMessage(uid: 1, data: message("inbox-msg"))],
                uidValidity: 3
            ),
            FakeFolder(
                name: "Gone",
                messages: [FakeMessage(uid: 1, data: message("gone-msg"))],
                uidValidity: 3
            ),
        ])
        let server = FakeIMAPServer(scenario: scenario)
        try server.start()
        defer { server.stop() }

        let store = try makeStore()
        let engine = IMAPSyncEngine(profile: profile(port: server.port), account: account)
        _ = try await runSync(engine, store: store)

        // The folder disappears server-side.
        server.updateFolders([
            FakeFolder(
                name: "INBOX",
                messages: [FakeMessage(uid: 1, data: message("inbox-msg"))],
                uidValidity: 3
            ),
        ])
        _ = try await runSync(engine, store: store)
        // The message from the vanished folder is marked removed but kept.
        XCTAssertTrue(try membershipIsRemoved(store, "gone-msg"))
        XCTAssertEqual(try bytes(store, "gone-msg"), message("gone-msg"))
        self.assertReadOnly(server)
    }

    // MARK: - INTERNALDATE

    func testInternalDateBecomesDateReceived() async throws {
        let scenario = FakeServerScenario(folders: [
            FakeFolder(
                name: "INBOX",
                messages: [FakeMessage(uid: 1, data: message("dated"))],
                uidValidity: 1
            ),
        ])
        let server = FakeIMAPServer(scenario: scenario)
        try server.start()
        defer { server.stop() }

        let store = try makeStore()
        let engine = IMAPSyncEngine(profile: profile(port: server.port), account: account)
        _ = try await runSync(engine, store: store)
        // The fake stamps every message 2026-01-01 12:00:00 UTC; that is
        // what lands in date_received (not the Date header of the message).
        let received = try await store.db.read { db in
            try String.fetchOne(db, sql: "SELECT dateReceived FROM message")
        }
        XCTAssertEqual(received, "2026-01-01T12:00:00Z")
        self.assertReadOnly(server)
    }

    // MARK: - Errors

    func testLoginFailureThrowsAuthenticationErrorWithoutEchoingPassword() async throws {
        var scenario = FakeServerScenario()
        scenario.loginFails = true
        let server = FakeIMAPServer(scenario: scenario)
        try server.start()
        defer { server.stop() }

        let store = try makeStore()
        let engine = IMAPSyncEngine(
            profile: profile(port: server.port), account: account
        )
        do {
            _ = try await runSync(engine, store: store, password: "secret-DO-NOT-ECHO")
            XCTFail("expected authenticationFailed")
        } catch let error as SyncEngineError {
            guard case .authenticationFailed = error else {
                XCTFail("expected authenticationFailed, got \(error)")
                return
            }
        }
        // The error text must never carry the attempted secret.
        let nothing = try count(store, "SELECT COUNT(*) FROM message")
        XCTAssertEqual(nothing, 0)
        self.assertReadOnly(server)
    }

    func testCommandFailureIsReportedNotSwallowed() async throws {
        // STATUS on a folder the server refuses to open: the engine fails
        // the pass with commandFailed rather than silently skipping.
        var scenario = FakeServerScenario(folders: [
            FakeFolder(name: "INBOX", messages: [], uidValidity: 1),
            FakeFolder(name: "Broken", messages: [], uidValidity: 1),
        ])
        scenario.failStatusFor = ["Broken"]
        let server = FakeIMAPServer(scenario: scenario)
        try server.start()
        defer { server.stop() }

        let store = try makeStore()
        let engine = IMAPSyncEngine(profile: profile(port: server.port), account: account)
        do {
            _ = try await runSync(engine, store: store)
            XCTFail("expected commandFailed")
        } catch let error as SyncEngineError {
            guard case .commandFailed = error else {
                XCTFail("expected commandFailed, got \(error)")
                return
            }
        }
        self.assertReadOnly(server)
    }

    // MARK: - Connectivity loss mid-sync

    func testConnectionLostMidPassKeepsCheckpointAndBytes() async throws {
        var scenario = FakeServerScenario(folders: [
            FakeFolder(
                name: "INBOX",
                messages: (1...10).map { FakeMessage(uid: UInt32($0), data: message("m\($0)", body: String(repeating: "z", count: 800))) },
                uidValidity: 5
            ),
        ])
        scenario.disconnectAfterCommands = 7 // close right after batch 1's tagged OK
        let server = FakeIMAPServer(scenario: scenario)
        try server.start()
        defer { server.stop() }

        let store = try makeStore()
        let engine = IMAPSyncEngine(
            profile: profile(port: server.port), account: account, batchBytes: 2000
        )
        do {
            _ = try await runSync(engine, store: store)
            XCTFail("expected connectionLost or commandFailed")
        } catch let error as SyncEngineError {
            switch error {
            case .connectionLost, .commandFailed:
                break
            default:
                XCTFail("expected connectionLost/commandFailed, got \(error)")
            }
        }
        // Whatever was committed before the drop stays: at least one batch
        // durable, checkpoint consistent with the stored rows.
        let stored = try count(store, "SELECT COUNT(*) FROM message")
        XCTAssertGreaterThan(stored, 0, "at least one batch must be durable before the drop")
        if let state = try syncState(store, "INBOX") {
            XCTAssertEqual(state.highestUID, Int64(stored), "checkpoint matches stored rows")
            XCTAssertEqual(state.uidValidity, 5)
        } else {
            XCTFail("a pass that stored messages must have committed a checkpoint")
        }
    }

    // MARK: - Internals

    /// Runs one sync pass against the running server.
    private func runSync(
        _ engine: IMAPSyncEngine, store: ArchiveStore, password: String = "secret"
    ) async throws -> SyncProgress {
        try await engine.sync(store: store, credentials: "alice@example.com", password: password)
    }

    private func membershipIsRemoved(_ store: ArchiveStore, _ subject: String) throws -> Bool {
        try store.db.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT mm.removedFromServer FROM message_mailbox mm
                JOIN message m ON m.id = mm.messageID
                WHERE m.subject = ?
                """, arguments: [subject]) ?? false
        }
    }

    /// The original bytes of the message, via its content-addressed file.
    private func bytes(_ store: ArchiveStore, _ subject: String) throws -> Data? {
        let hash: Data? = try store.db.read { db in
            try Data.fetchOne(db, sql: "SELECT hash FROM message WHERE subject = ?", arguments: [subject])
        }
        guard let hash, hash.count == 32 else { return nil }
        let messageHash = MessageHash(bytes: hash)
        return try store.messageData(messageHash)
    }

    private func searchCount(_ store: ArchiveStore, _ term: String) throws -> Int {
        try store.db.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM message_text WHERE message_text MATCH ?
                """, arguments: [term]) ?? 0
        }
    }
}
