import ArchiveCore
import GRDB
import IMAPCommands
import XCTest
@testable import MailSync

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

    private func sync(
        _ engine: IMAPSyncEngine, store: ArchiveStore,
        progress observe: @escaping @Sendable (SyncProgress) -> Void = { _ in }
    ) async throws -> SyncProgress {
        FileHandle.standardError.write(Data("[gm-sync] start\n".utf8))
        let progress = try await engine.sync(
            store: store,
            credentials: GreenMail.user,
            password: GreenMail.password
        ) { progressPoint in
            FileHandle.standardError.write(
                Data("[gm-sync] stored=\(progressPoint.messagesStored) dup=\(progressPoint.messagesDuplicate) folders=\(progressPoint.foldersListed) bytes=\(progressPoint.bytesDownloaded)\n".utf8)
            )
            observe(progressPoint)
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

    /// Every server-touching test runs under this cross-process lock:
    /// `swift test --parallel` schedules more than one runner process for a
    /// single test bundle, and the tests share one server whose fixture
    /// reset (a global content purge) must never interleave with another
    /// test's sync pass. Serial within a process and across processes.
    func locked<T>(_ body: () async throws -> T) async throws -> T {
        try await FileLock(name: "geist9-greenmail-\(GreenMail.port).lock").withLock(body)
    }

    /// The Done-when "kill tests during sync pass with next sync resuming
    /// from last checkpoint": five messages, an engine with a tiny batch
    /// budget so the pass fetches them in several batches, and a kill
    /// (task cancellation) the moment the second batch has been ingested.
    /// The retry pass must fill in exactly what the killed pass had not
    /// made durable — every message stored once, none lost, and the
    /// checkpoint afterwards at the folder's highest UID.
    func testKillMidPassResumesFromTheLastCheckpoint() async throws {
        try await self.locked {
            try await GreenMail.requireServer()
            let store = try makeStore()
            let engine = IMAPSyncEngine(
                profile: self.profile(), account: self.account, batchBytes: 300,
                // Pace the batches so the kill can land mid-pass: after each
                // checkpoint commit the pass sleeps here, giving the poll
                // loop a guaranteed window to cancel before the next batch.
                betweenBatches: { try await Task.sleep(for: .milliseconds(200)) }
            )

            self.fixtureFolder = GreenMail.freshFixtureFolder()
            try await GreenMail.resetFixture(folder: self.fixtureFolder)
            try await GreenMail.seed((1...5).map { self.message("m\($0)") }, to: self.fixtureFolder)

            // Pass 1: killed mid-sync. A detached task runs the pass; the
            // parent polls the archive's checkpoint and cancels the pass
            // task as soon as a second batch is durable. Detached because
            // cancelling a child structured task from the parent body
            // requires the closure not to capture the parent's isolation —
            // and the kill must race nothing but the checkpoint.
            let passTask = Task.detached(priority: .medium) {
                do {
                    _ = try await engine.sync(
                        store: store, credentials: GreenMail.user, password: GreenMail.password
                    )
                    return false  // completed without ever being killed
                } catch is CancellationError {
                    return true
                } catch {
                    return false  // failed for another reason
                }
            }
            // Wait until the pass has made a checkpoint durable, then kill it.
            while true {
                let state = try store.syncState(
                    account: self.account, mailbox: self.fixtureFolder
                )
                // The first checkpoint already proves per-batch durability;
                // killing there leaves the widest window (two more batches
                // to race the cancel against) for the kill to land mid-pass.
                if let state, state.highestUID >= 1 { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            passTask.cancel()
            let wasKilled = await passTask.value
            XCTAssertTrue(wasKilled, "the pass was killed mid-sync")

            // Whatever the kill left: a prefix of the five messages is
            // stored, and the checkpoint names it.
            let storedBefore = try self.count(store, "SELECT COUNT(*) FROM message")
            let checkpointBefore = try store.syncState(
                account: self.account, mailbox: self.fixtureFolder
            )?.highestUID
            XCTAssertEqual(
                Int64(storedBefore), checkpointBefore,
                "every stored message is behind the checkpoint (per-batch durability)"
            )
            XCTAssertGreaterThan(storedBefore, 0)
            XCTAssertLessThan(storedBefore, 5, "the pass was killed mid-sync, not at the end")

            // Pass 2: the retry downloads exactly the rest — the killed
            // pass's uncheckpointed tail is re-fetched or deduped, but
            // nothing is lost and nothing is stored twice as new bytes.
            let resumed = try await self.sync(engine, store: store)
            XCTAssertEqual(resumed.messagesStored + resumed.messagesDuplicate, 5 - storedBefore)
            XCTAssertEqual(try self.count(store, "SELECT COUNT(*) FROM message"), 5)
            let allFive: Set<String> = ["gm-m1", "gm-m2", "gm-m3", "gm-m4", "gm-m5"]
            XCTAssertEqual(allFive, try self.storedSubjects(store))
            XCTAssertEqual(try self.highestUID(store), 5, "the checkpoint reaches the top")
        }
    }

    func testFullThenIncrementalThenUIDValidityChange() async throws {
        try await self.locked {
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
    }

    func testEngineSendsNoMutatingCommand() async throws {
        // The read-only guarantee is checked archive-side here (the archive
        // never rewrites rows; seeded flags stay unset because the engine
        // never writes flags); the fake-server suite asserts the recorded
        // command list directly, which no public server exposes.
        try await self.locked {
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
}
