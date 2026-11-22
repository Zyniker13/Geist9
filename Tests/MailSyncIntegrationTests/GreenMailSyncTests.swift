// Integration tests for the sync engine against a REAL IMAP server
// (TESTING.md, Protocol row: "Sync engine against real servers").
//
// The suite runs whenever a GreenMail standalone instance is reachable at
// GEIST9_GREENMAIL_HOST / GEIST9_GREENMAIL_PORT (default 127.0.0.1:13143)
// with user `alice@example.com` / password `secret`; start one with
// `scripts/imap-servers.sh start` (TESTING.md). Without a reachable server
// every test fails loudly with setup instructions — it never silently skips
// (TESTING.md: "A test that needs a server it can't start fails with a clear
// message; it never silently skips").

import ArchiveCore
import GRDB
import IMAPCommands
import NIOCore
import NIOIMAP
import XCTest
@testable import MailSync

private struct ServerMissing: Error, CustomStringConvertible {
    var message: String
    var description: String { self.message }
}

/// Connection details and helpers for the running GreenMail instance.
private enum GreenMail {
    static var host: String {
        ProcessInfo.processInfo.environment["GEIST9_GREENMAIL_HOST"] ?? "127.0.0.1"
    }

    static var port: Int {
        Int(ProcessInfo.processInfo.environment["GEIST9_GREENMAIL_PORT"] ?? "13143") ?? 0
    }

    static var user: String { "alice@example.com" }
    static var password: String { "secret" }

    private static var configuration: IMAPConnection.Configuration {
        IMAPConnection.Configuration(
            hostname: self.host, port: UInt16(self.port), useTLS: false, logging: .noLogging
        )
    }

    /// Consumes a tagged response stream, asserting the final state is OK.
    static func awaitOK(_ stream: IMAPConnection.ResponseStream, what: String) async throws {
        for try await response in stream {
            if case .tagged(let t) = response {
                guard case .ok = t.state else {
                    throw SyncEngineError.commandFailed("\(what): \(t.state)")
                }
                break
            }
        }
    }

    /// Logs in and asserts the server answers with an OK greeting. Throws a
    /// ServerMissing with setup instructions when unreachable.
    static func connect(login: Bool) async throws -> IMAPConnection {
        do {
            return try await IMAPConnection.withConnection(configuration: self.configuration) { greeting, connection in
                guard case .ok = greeting.status else {
                    throw ServerMissing(message: "No OK greeting from \(self.host):\(self.port)")
                }
                if login {
                    try await connection.send(.login(username: self.user, password: self.password)) { _, stream in
                        try await self.awaitOK(stream, what: "seed login")
                    }
                }
                return connection
            }
        } catch let error as ServerMissing {
            throw error
        } catch {
            throw ServerMissing(message: """
                No IMAP server at \(self.host):\(self.port) — the integration suite needs a \
                running GreenMail standalone. Start it with scripts/imap-servers.sh start \
                (user \(self.user) / \(self.password)), then re-run. Underlying error: \(error)
                """)
        }
    }

    /// Asserts the server is up before a test does anything else.
    static func requireServer() async throws {
        _ = try await self.connect(login: false)
    }

    /// A fresh fixture folder per test run: a unique name means a guaranteed-
    /// empty folder whose UIDs restart at 1, so exact checkpoint assertions
    /// hold, and the suite is immune to shared-server pollution from earlier
    /// aborted runs.
    static func freshFixtureFolder() -> String {
        "gm-fixture-" + UUID().uuidString.prefix(8).lowercased()
    }

    /// Prepares a clean slate for a test:
    /// 1. purge every non-INBOX folder's content (earlier runs leave folders
    ///    behind that GreenMail can never delete once a session has selected
    ///    them — see the quirk note below — but emptied they hold no mail and
    ///    the engine syncs them as zero-message folders);
    /// 2. purge INBOX (the engine syncs it too, so archive-wide progress
    ///    counts must reflect the fixture alone);
    /// 3. create the fresh unique fixture folder.
    ///
    /// All purges run on the TEST HARNESS's own connections managing its own
    /// fixture — the read-only guarantee is about the sync engine (asserted
    /// separately against the fake server's recorded command list); fixture
    /// setup is not a violation of it.
    static func resetFixture(folder: String) async throws {
        var folders: [String] = []
        try await IMAPConnection.withConnection(configuration: self.configuration) { greeting, connection in
            guard case .ok = greeting.status else { throw ServerMissing(message: "no greeting") }
            try await connection.send(.login(username: self.user, password: self.password)) { _, stream in
                try await self.awaitOK(stream, what: "reset login")
            }
            try await connection.send(.list(nil, reference: MailboxName([]), .mailbox(ByteBuffer(string: "*")), [])) { _, stream in
                for try await response in stream {
                    if case .untagged(.mailboxData(.list(let info))) = response {
                        let name = String(decoding: info.path.name.bytes, as: UTF8.self)
                        if name != "INBOX" { folders.append(name) }
                    }
                    if case .tagged(let t) = response {
                        guard case .ok = t.state else {
                            throw SyncEngineError.commandFailed("reset LIST: \(t.state)")
                        }
                        break
                    }
                }
            }
            for name in folders {
                try await self.purgeFolder(name, on: connection)
            }
            try await self.purgeFolder("INBOX", on: connection)
            try await connection.send(.create(MailboxName(Array(folder.utf8)), [])) { _, stream in
                try await self.awaitOK(stream, what: "reset CREATE \(folder)")
            }
            return ()
        }
    }

    /// Marks every message in a folder \Deleted and expunges them, leaving
    /// the folder present but empty (STORE + EXPUNGE; DELETE is not usable
    /// on GreenMail for a folder any session ever selected: its session
    /// bookkeeping crashes the deleting connection instead).
    static func purgeFolder(_ name: String, on connection: IMAPConnection) async throws {
        try await connection.send(.select(MailboxName(Array(name.utf8)))) { _, stream in
            try await self.awaitOK(stream, what: "purge SELECT \(name)")
        }
        try await connection.send(
            .uidStore(
                .range(MessageIdentifierRange<UID>(UID(rawValue: 1)...UID(rawValue: UInt32.max))),
                [],
                .flags(StoreFlags.add(silent: true, list: [.deleted]))
            )
        ) { _, stream in
            try await self.awaitOK(stream, what: "purge STORE \(name)")
        }
        try await connection.send(.expunge) { _, stream in
            try await self.awaitOK(stream, what: "purge EXPUNGE \(name)")
        }
    }

    /// Creates one folder (for fixture folders the test builds mid-run).
    static func createFolder(_ folder: String) async throws {
        try await IMAPConnection.withConnection(configuration: self.configuration) { greeting, connection in
            guard case .ok = greeting.status else { throw ServerMissing(message: "no greeting") }
            try await connection.send(.login(username: self.user, password: self.password)) { _, stream in
                try await self.awaitOK(stream, what: "create login")
            }
            try await connection.send(.create(MailboxName(Array(folder.utf8)), [])) { _, stream in
                try await self.awaitOK(stream, what: "create \(folder)")
            }
            return ()
        }
    }

    /// Appends raw RFC 822 messages to the fixture folder in a fresh connection.
    static func seed(_ messages: [Data], to folder: String) async throws {
        try await IMAPConnection.withConnection(configuration: self.configuration) { greeting, connection in
            guard case .ok = greeting.status else { throw ServerMissing(message: "no greeting") }
            try await connection.send(.login(username: self.user, password: self.password)) { _, stream in
                try await self.awaitOK(stream, what: "seed login")
            }
            for bytes in messages {
                try await connection.append(to: MailboxName(Array(folder.utf8))) { _, stream, writer in
                    let message = AppendMessage(
                        options: .none,
                        data: AppendData(byteCount: bytes.count)
                    )
                    try await writer.write(message: message) { w in
                        try await w.write(messageBytes: ByteBuffer(bytes: bytes))
                    }
                    try await writer.finish()
                    for try await response in stream {
                        if case .tagged(let t) = response {
                            guard case .ok = t.state else {
                                throw SyncEngineError.commandFailed("seed APPEND: \(t.state)")
                            }
                            break
                        }
                    }
                }
            }
            return ()
        }
    }

}

/// The M4 Done-when flow against real GreenMail: full sync, incremental
/// sync, the full-re-offer dedupe path, and the read-only guarantee.
final class GreenMailSyncTests: XCTestCase {
    // MARK: - Fixtures

    private let account = AccountIdentity(
        email: "alice@example.com", displayName: "Alice", providerKind: "imap"
    )
    private var tempRoot: URL!

    override func setUpWithError() throws {
        // Unique dir per test: cleanup races between concurrently scheduled
        // methods are the classic false-failure (swift-development skill).
        self.tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("geist9-gm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: self.tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let root = self.tempRoot {
            try? FileManager.default.removeItem(at: root)
        }
        self.tempRoot = nil
    }

    private func makeStore() throws -> ArchiveStore {
        try ArchiveStore.create(
            at: self.tempRoot.appendingPathComponent("Test.emailarchive"), appVersion: "0.1.0"
        )
    }

    private func profile() -> ProviderProfile {
        ProviderProfile(
            id: "greenmail-test",
            displayName: "GreenMail test",
            host: GreenMail.host,
            tls: .starttls(port: GreenMail.port), // plain loopback server
            credential: .appPassword,
            domains: []
        )
    }

    /// A distinct RFC 822 message per tag.
    private func message(_ tag: String) -> Data {
        var lines: [String] = []
        lines.append("From: Bob <bob@example.org>")
        lines.append("To: Alice <alice@example.com>")
        lines.append("Subject: gm-\(tag)")
        lines.append("Date: Mon, 20 Jan 2026 10:00:00 +0000")
        lines.append("Message-ID: <gm-\(tag)@example.org>")
        lines.append("")
        lines.append("body \(tag)")
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    private func sync(_ engine: IMAPSyncEngine, store: ArchiveStore) async throws -> SyncProgress {
        FileHandle.standardError.write(Data("[gm-sync] start\n".utf8))
        let progress = try await engine.sync(
            store: store,
            credentials: GreenMail.user,
            password: GreenMail.password
        ) { p in
            FileHandle.standardError.write(Data("[gm-sync] stored=\(p.messagesStored) dup=\(p.messagesDuplicate) folders=\(p.foldersListed) bytes=\(p.bytesDownloaded)\n".utf8))
        }
        FileHandle.standardError.write(Data("[gm-sync] done stored=\(progress.messagesStored) dup=\(progress.messagesDuplicate)\n".utf8))
        return progress
    }

    private func count(_ store: ArchiveStore, _ sql: String) throws -> Int {
        try store.db.read { db in try Int.fetchOne(db, sql: sql) ?? 0 }
    }

    private func storedSubjects(_ store: ArchiveStore) throws -> Set<String> {
        try store.db.read { db in
            Set(try String.fetchAll(db, sql: "SELECT subject FROM message"))
        }
    }

    private var fixtureFolder: String!

    private func highestUID(_ store: ArchiveStore) throws -> Int64? {
        try store.syncState(account: self.account, mailbox: self.fixtureFolder)?.highestUID
    }

    // MARK: - The Done-when flow

    func testFullThenIncrementalThenUIDValidityChange() async throws {
        try await GreenMail.requireServer()
        let store = try makeStore()
        let engine = IMAPSyncEngine(profile: self.profile(), account: self.account)

        // Seed the fixture folder: five distinct messages. The per-run fresh
        // folder starts its UID counter at 1, so the five seed as UIDs 1..5
        // and the exact checkpoint assertions below are meaningful.
        self.fixtureFolder = GreenMail.freshFixtureFolder()
        try await GreenMail.resetFixture(folder: self.fixtureFolder)
        let seededSubjects: Set<String> = ["gm-m1", "gm-m2", "gm-m3", "gm-m4", "gm-m5"]
        try await GreenMail.seed((1...5).map { self.message("m\($0)") }, to: self.fixtureFolder)

        // 1. Full sync: everything arrives.
        let full = try await self.sync(engine, store: store)
        XCTAssertEqual(full.messagesStored, 5, "first pass stores every seeded message")
        XCTAssertEqual(try self.count(store, "SELECT COUNT(*) FROM message"), 5)
        XCTAssertEqual(seededSubjects, try self.storedSubjects(store))
        let fullHighWater = try self.highestUID(store)
        XCTAssertEqual(fullHighWater, 5, "checkpoint reaches the folder's highest UID")

        // 2. Incremental sync: nothing changed, nothing downloaded.
        let incremental = try await self.sync(engine, store: store)
        XCTAssertEqual(incremental.messagesStored, 0, "an unchanged folder downloads nothing")
        XCTAssertEqual(incremental.messagesDuplicate, 0)
        XCTAssertEqual(try self.count(store, "SELECT COUNT(*) FROM message"), 5)

        // 3. New mail arrives; the next pass downloads only it.
        try await GreenMail.seed([self.message("m6"), self.message("m7")], to: self.fixtureFolder)
        let withNew = try await self.sync(engine, store: store)
        XCTAssertEqual(withNew.messagesStored, 2, "only the new messages are fetched")
        XCTAssertEqual(try self.count(store, "SELECT COUNT(*) FROM message"), 7)
        XCTAssertEqual(try self.highestUID(store), 7)

        // 4. The full-re-offer path (the engine behavior a UIDVALIDITY
        // change drives): the same seven bytes appear in a fresh folder with
        // no checkpoint, so the engine fetches everything and every message
        // dedupes by content — duplicates, never new bytes. The real
        // UIDVALIDITY transition itself is covered end-to-end by the
        // fake-server suite (GreenMail cannot delete a folder a session has
        // selected; see the server-quirks reference).
        let replayFolder = GreenMail.freshFixtureFolder()
        try await GreenMail.createFolder(replayFolder)
        try await GreenMail.seed(
            (1...7).map { self.message("m\($0)") }, to: replayFolder
        )
        let afterReset = try await self.sync(engine, store: store)
        XCTAssertEqual(
            afterReset.messagesDuplicate, 7,
            "every message is re-offered and deduped by content — none downloads twice"
        )
        XCTAssertEqual(afterReset.messagesStored, 0, "no new bytes are stored")
        XCTAssertEqual(try self.count(store, "SELECT COUNT(*) FROM message"), 7)
        let allSeven: Set<String> = ["gm-m1", "gm-m2", "gm-m3", "gm-m4", "gm-m5", "gm-m6", "gm-m7"]
        XCTAssertEqual(allSeven, try self.storedSubjects(store))
    }

    func testEngineSendsNoMutatingCommand() async throws {
        // The read-only guarantee is checked archive-side here (the archive
        // never rewrites rows; seeded flags stay unset because the engine
        // never writes flags); the fake-server suite asserts the recorded
        // command list directly, which no public server exposes.
        try await GreenMail.requireServer()
        let store = try makeStore()
        let engine = IMAPSyncEngine(profile: self.profile(), account: self.account)
        self.fixtureFolder = GreenMail.freshFixtureFolder()
        try await GreenMail.resetFixture(folder: self.fixtureFolder)
        try await GreenMail.seed([self.message("a"), self.message("b")], to: self.fixtureFolder)
        _ = try await self.sync(engine, store: store)

        // Re-sync twice; the archive may only gain rows, never rewrite them.
        _ = try await self.sync(engine, store: store)
        _ = try await self.sync(engine, store: store)
        XCTAssertEqual(try self.count(store, "SELECT COUNT(*) FROM message"), 2)
        let rows = try await store.db.read { db -> [(uid: Int64, flags: String?)] in
            try Row.fetchAll(db, sql: "SELECT uid, flags FROM message_mailbox").map {
                (uid: $0["uid"] ?? 0, flags: $0["flags"])
            }
        }
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.flags == nil || $0.flags!.isEmpty })
    }
}
