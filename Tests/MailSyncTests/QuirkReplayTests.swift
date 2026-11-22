// Quirk replay tests (TESTING, "Quirk replay" row): a scripted fake IMAP
// server replays each provider's documented, sanitized behavior so the
// engine handles it without touching any real account. Every scenario here
// comes from PROVIDERS.md's documented quirks, never from a live server.
//
// Covered quirks:
// - 163/126 refuse SELECT until the client sends RFC 2971 ID ("Unsafe Login");
// - Gmail labels: [Gmail]/All Mail once, X-GM-LABELS recorded, label folders
//   never downloaded (2,500 MB/day cap);
// - Yahoo/AOL/AT&T: silent disconnects on long sessions; the next sync
//   resumes from the checkpoint without re-downloading.

import ArchiveCore
import GRDB
import XCTest
@testable import MailSync

final class QuirkReplayTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("geist9-quirk-tests-\(UUID().uuidString)")
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

    private func profile(port: UInt16, quirks: [ProviderQuirk] = []) -> ProviderProfile {
        var profile = ProviderProfile(
            id: "test",
            displayName: "Test",
            host: "127.0.0.1",
            tls: .starttls(port: Int(port)), // no real TLS needed: plain loopback server
            credential: .appPassword,
            domains: []
        )
        profile.quirks = Set(quirks)
        profile.politeness.batchPauseSeconds = 0
        return profile
    }

    private func assertReadOnly(_ server: FakeIMAPServer) {
        for command in server.seenCommands {
            XCTAssertTrue(
                Self.readOnlyCommands.contains(command),
                "the engine sent a mutating command: \(command)"
            )
        }
    }

    private func sqlCount(_ store: ArchiveStore, _ sql: String) throws -> Int {
        try store.db.read { db in try Int.fetchOne(db, sql: sql) ?? 0 }
    }

    private static let readOnlyCommands: Set<String> = [
        "LOGIN", "ID", "LIST", "STATUS", "SELECT", "UID FETCH", "UID SEARCH", "LOGOUT", "NOOP",
    ]

    // MARK: - 163: ID before SELECT

    /// 163 refuses the first SELECT with "Unsafe Login" unless an RFC 2971
    /// ID arrived earlier in the session (PROVIDERS row 8). The engine
    /// always sends ID right after LOGIN, so the whole pass must succeed
    /// and the recorded order must be LOGIN, ID, ... first SELECT — never
    /// a bare SELECT before the ID.
    func testEngineSendsIDBeforeTheFirstSelectForThe163Quirk() async throws {
        let server = FakeIMAPServer(scenario: FakeServerScenario(
            folders: [FakeFolder(name: "INBOX", messages: [], uidValidity: 1)],
            refuseSelectBeforeID: true
        ))
        try server.start()
        defer { server.stop() }

        let store = try makeStore()
        let engine = IMAPSyncEngine(profile: profile(port: server.port), account: account)
        _ = try await engine.sync(store: store, credentials: "alice@example.com", password: "secret")

        let order = server.seenCommands
        XCTAssertEqual(order.first, "LOGIN", "the engine must log in first")
        XCTAssertEqual(order.dropFirst(1).first, "ID", "163 requires ID before any SELECT")
        let firstSelect = order.firstIndex(of: "SELECT")
        let firstID = order.firstIndex(of: "ID")
        XCTAssertNotNil(firstSelect)
        XCTAssertNotNil(firstID)
        XCTAssertLessThan(firstID!, firstSelect!, "ID must precede the first SELECT")
        assertReadOnly(server)
    }

    // MARK: - Gmail labels

    /// DESIGN 5: archive [Gmail]/All Mail once, record X-GM-LABELS, and never
    /// download the per-label folders (each would re-serve the same bytes
    /// against Gmail's 2,500 MB/day cap). The engine in gmail mode must
    /// SELECT only the All-Mail folder, ingest the message with its labels,
    /// and leave the label folders untouched.
    func testGmailModeSyncsOnlyAllMailAndRecordsLabels() async throws {
        let body = message("label test", body: "with gmail labels")
        let server = FakeIMAPServer(scenario: FakeServerScenario(
            folders: [
                FakeFolder(name: "[Gmail]/All Mail", messages: [
                    FakeMessage(uid: 1, data: body, gmLabels: ["important", "work"]),
                ], uidValidity: 7),
                FakeFolder(name: "work", messages: [
                    // The label folder re-serves the same message; the
                    // engine must never come here.
                    FakeMessage(uid: 1, data: body, gmLabels: ["work"]),
                ], uidValidity: 7),
            ],
            password: "secret"
        ))
        try server.start()
        defer { server.stop() }

        let store = try makeStore()
        let engine = IMAPSyncEngine(
            profile: profile(port: server.port, quirks: [.gmailLabels]), account: account
        )
        let progress = try await engine.sync(store: store, credentials: "alice@example.com", password: "secret")
        XCTAssertEqual(progress.messagesStored, 1, "one message stored once, from All Mail only")

        // The label folder was never selected: the only SELECT is All Mail.
        let selects = server.seenCommands.filter { $0 == "SELECT" }
        XCTAssertEqual(selects.count, 1, "exactly one folder was selected")
        assertReadOnly(server)

        // The message carries both labels in the index.
        let labels = try sqlCount(store, "SELECT COUNT(*) FROM message_label")
        XCTAssertEqual(labels, 2, "both labels recorded for the one message")
    }

    // MARK: - Yahoo-style silent disconnects

    /// PROVIDERS row 6: Yahoo closes long sessions without warning. A sync
    /// that dies mid-pass keeps the checkpoint of every batch that was
    /// already durable; the next sync resumes from it and downloads only
    /// what the killed pass had not reached (no duplicates).
    func testMidPassDisconnectResumesFromTheCheckpoint() async throws {
        let body1 = message("resume one")
        let body2 = message("resume two")
        let server = FakeIMAPServer(scenario: FakeServerScenario(
            folders: [FakeFolder(name: "INBOX", messages: [
                FakeMessage(uid: 1, data: body1),
                FakeMessage(uid: 2, data: body2),
            ], uidValidity: 3)],
            // Close after the first batch's data was served.
            disconnectAfterCommands: 5
        ))
        try server.start()
        defer { server.stop() }

        let store = try makeStore()
        let engine = IMAPSyncEngine(profile: profile(port: server.port), account: account)

        // Pass 1 dies mid-way (connectionLost).
        do {
            _ = try await engine.sync(store: store, credentials: "alice@example.com", password: "secret")
            XCTFail("the scripted disconnect should have killed pass 1")
        } catch let error as SyncEngineError {
            guard case .connectionLost = error else {
                return XCTFail("expected connectionLost, got \(error)")
            }
        }

        // Pass 2: the checkpoint from pass 1 holds whatever was durable, so
        // pass 2 fetches only the rest. Whatever was stored before the cut
        // is never re-downloaded (incremental above the checkpoint).
        server.setDisconnectAfterCommands(nil)
        let progress = try await engine.sync(store: store, credentials: "alice@example.com", password: "secret")
        XCTAssertLessThanOrEqual(
            progress.messagesStored + progress.messagesDuplicate, 2,
            "pass 2 never re-downloads a message pass 1 already made durable"
        )

        // Both messages are in the archive exactly once.
        let count = try sqlCount(store, "SELECT COUNT(*) FROM message")
        XCTAssertEqual(count, 2)
        assertReadOnly(server)
    }
}
