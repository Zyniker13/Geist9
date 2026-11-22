import ArchiveCore
import GRDB
import IMAPCommands
import XCTest
@testable import MailSync

/// The M4 Done-when flows against REAL local IMAP servers (TESTING.md,
/// Protocol row): full sync, incremental sync, the full-re-offer dedupe
/// path, mid-pass kill + checkpoint resume, and the read-only guarantee —
/// each run against GreenMail AND against Dovecot. `scripts/imap-servers.sh
/// start` starts both; the fixture fails loudly when one is missing, never
/// silently skips.
final class RealServerSyncTests: XCTestCase {
    // MARK: - Fixtures

    private let account = AccountIdentity(
        email: MailServer.user, displayName: "Alice", providerKind: "imap"
    )
    private var tempRoot: URL!

    override func setUpWithError() throws {
        // Unique dir per test: cleanup races between concurrently scheduled
        // methods are the classic false-failure (swift-development skill).
        self.tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("geist9-imap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: self.tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let root = self.tempRoot {
            try? FileManager.default.removeItem(at: root)
        }
        self.tempRoot = nil
    }

    /// The named server, unless the environment explicitly deselected it via
    /// GEIST9_SKIP_SERVERS (a deliberate operator choice, surfaced as a
    /// visible skip — not a silent one).
    private func server(_ kind: MailServer.Kind) async throws -> MailServer {
        guard let server = MailServer.configured().first(where: { $0.kind == kind }) else {
            throw XCTSkip("\(kind.rawValue) excluded via GEIST9_SKIP_SERVERS")
        }
        try await server.requireServer()
        return server
    }

    private func makeStore() throws -> ArchiveStore {
        try ArchiveStore.create(
            at: self.tempRoot.appendingPathComponent("Test.emailarchive"), appVersion: "0.1.0"
        )
    }

    private func profile(for server: MailServer) -> ProviderProfile {
        ProviderProfile(
            id: "imap-test-\(server.kind.rawValue)",
            displayName: "Real server test (\(server.name))",
            host: server.host,
            tls: .starttls(port: server.port), // plain loopback server
            credential: .appPassword,
            domains: []
        )
    }

    /// A distinct RFC 822 message per tag.
    private func message(_ tag: String) -> Data {
        var lines: [String] = []
        lines.append("From: Bob <bob@example.org>")
        lines.append("To: Alice <alice@example.com>")
        lines.append("Subject: srv-\(tag)")
        lines.append("Date: Mon, 20 Jan 2026 10:00:00 +0000")
        lines.append("Message-ID: <srv-\(tag)@example.org>")
        lines.append("")
        lines.append("body \(tag)")
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    private func sync(
        _ engine: IMAPSyncEngine, store: ArchiveStore, server: MailServer,
        progress observe: @escaping @Sendable (SyncProgress) -> Void = { _ in }
    ) async throws -> SyncProgress {
        FileHandle.standardError.write(Data("[\(server.name)-sync] start\n".utf8))
        let progress = try await engine.sync(
            store: store,
            credentials: MailServer.user,
            password: MailServer.password
        ) { progressPoint in
            FileHandle.standardError.write(
                Data("[\(server.name)-sync] stored=\(progressPoint.messagesStored) dup=\(progressPoint.messagesDuplicate) folders=\(progressPoint.foldersListed) bytes=\(progressPoint.bytesDownloaded)\n".utf8)
            )
            observe(progressPoint)
        }
        FileHandle.standardError.write(
            Data("[\(server.name)-sync] done stored=\(progress.messagesStored) dup=\(progress.messagesDuplicate)\n".utf8)
        )
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

    private func highestUID(_ store: ArchiveStore, folder: String) throws -> Int64? {
        try store.syncState(account: self.account, mailbox: folder)?.highestUID
    }

    // MARK: - Shared machinery

    /// Every server-touching test runs under this cross-process lock:
    /// `swift test --parallel` schedules more than one runner process for a
    /// single test bundle, and the tests share one server whose fixture
    /// reset (a global content purge) must never interleave with another
    /// test's sync pass. Serial within a process and across processes.
    /// One lock per server port: two servers can be driven concurrently by
    /// different test methods without fighting over the same fixture.
    private func locked<T>(on server: MailServer, _ body: () async throws -> T) async throws -> T {
        try await FileLock(name: "geist9-imap-\(server.kind.rawValue)-\(server.port).lock").withLock(body)
    }

    // MARK: - Flow 1: full sync, incremental sync, full-re-offer dedupe

    private func fullThenIncrementalThenReplay(on server: MailServer) async throws {
        try await self.locked(on: server) {
            let store = try makeStore()
            let engine = IMAPSyncEngine(profile: self.profile(for: server), account: self.account)

            // Seed the fixture folder: five distinct messages. The per-run
            // fresh folder starts its UID counter at 1, so the five seed as
            // UIDs 1..5 and the exact checkpoint assertions below are
            // meaningful.
            let folder = server.freshFixtureFolder()
            try await server.resetFixture(folder: folder)
            let seededSubjects: Set<String> = ["srv-m1", "srv-m2", "srv-m3", "srv-m4", "srv-m5"]
            try await server.seed((1...5).map { self.message("m\($0)") }, to: folder)

            // 1. Full sync: everything arrives.
            let full = try await self.sync(engine, store: store, server: server)
            XCTAssertEqual(full.messagesStored, 5, "\(server.name): first pass stores every seeded message")
            XCTAssertEqual(try self.count(store, "SELECT COUNT(*) FROM message"), 5)
            XCTAssertEqual(seededSubjects, try self.storedSubjects(store))
            XCTAssertEqual(try self.highestUID(store, folder: folder), 5, "\(server.name): checkpoint reaches the folder's highest UID")

            // 2. Incremental sync: nothing changed, nothing downloaded.
            let incremental = try await self.sync(engine, store: store, server: server)
            XCTAssertEqual(incremental.messagesStored, 0, "\(server.name): an unchanged folder downloads nothing")
            XCTAssertEqual(incremental.messagesDuplicate, 0)
            XCTAssertEqual(try self.count(store, "SELECT COUNT(*) FROM message"), 5)

            // 3. New mail arrives; the next pass downloads only it.
            try await server.seed([self.message("m6"), self.message("m7")], to: folder)
            let withNew = try await self.sync(engine, store: store, server: server)
            XCTAssertEqual(withNew.messagesStored, 2, "\(server.name): only the new messages are fetched")
            XCTAssertEqual(try self.count(store, "SELECT COUNT(*) FROM message"), 7)
            XCTAssertEqual(try self.highestUID(store, folder: folder), 7)

            // 4. The full-re-offer path (the engine behavior a UIDVALIDITY
            // change drives): the same seven bytes appear in a fresh folder
            // with no checkpoint, so the engine fetches everything and every
            // message dedupes by content — duplicates, never new bytes. The
            // real UIDVALIDITY transition itself is covered end-to-end by
            // the fake-server suite (GreenMail cannot delete a folder a
            // session has selected; see the server-quirks reference).
            let replayFolder = server.freshFixtureFolder()
            try await server.createFolder(replayFolder)
            try await server.seed((1...7).map { self.message("m\($0)") }, to: replayFolder)
            let afterReset = try await self.sync(engine, store: store, server: server)
            XCTAssertEqual(
                afterReset.messagesDuplicate, 7,
                "\(server.name): every message is re-offered and deduped by content — none downloads twice"
            )
            XCTAssertEqual(afterReset.messagesStored, 0, "\(server.name): no new bytes are stored")
            XCTAssertEqual(try self.count(store, "SELECT COUNT(*) FROM message"), 7)
            let allSeven: Set<String> = ["srv-m1", "srv-m2", "srv-m3", "srv-m4", "srv-m5", "srv-m6", "srv-m7"]
            XCTAssertEqual(allSeven, try self.storedSubjects(store))
        }
    }

    func testFullThenIncrementalThenFullReOfferDedupeOnGreenMail() async throws {
        try await self.fullThenIncrementalThenReplay(on: try await self.server(.greenmail))
    }

    func testFullThenIncrementalThenFullReOfferDedupeOnDovecot() async throws {
        try await self.fullThenIncrementalThenReplay(on: try await self.server(.dovecot))
    }

    // MARK: - Flow 2: read-only guarantee

    private func engineSendsNoMutatingCommand(on server: MailServer) async throws {
        // The read-only guarantee is checked archive-side here (the archive
        // never rewrites rows; seeded flags stay unset because the engine
        // never writes flags); the fake-server suite asserts the recorded
        // command list directly, which no public server exposes.
        try await self.locked(on: server) {
            let store = try makeStore()
            let engine = IMAPSyncEngine(profile: self.profile(for: server), account: self.account)
            let folder = server.freshFixtureFolder()
            try await server.resetFixture(folder: folder)
            try await server.seed([self.message("a"), self.message("b")], to: folder)
            _ = try await self.sync(engine, store: store, server: server)

            // Re-sync twice; the archive may only gain rows, never rewrite them.
            _ = try await self.sync(engine, store: store, server: server)
            _ = try await self.sync(engine, store: store, server: server)
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

    func testEngineSendsNoMutatingCommandOnGreenMail() async throws {
        try await self.engineSendsNoMutatingCommand(on: try await self.server(.greenmail))
    }

    func testEngineSendsNoMutatingCommandOnDovecot() async throws {
        try await self.engineSendsNoMutatingCommand(on: try await self.server(.dovecot))
    }

    // MARK: - Flow 3: kill mid-pass, resume from the last checkpoint

    /// The Done-when "kill tests during sync pass with next sync resuming
    /// from last checkpoint": five messages, an engine with a tiny batch
    /// budget so the pass fetches them in several batches, and a kill
    /// (task cancellation) the moment a checkpoint is durable. The retry
    /// pass must fill in exactly what the killed pass had not made durable
    /// — every message stored once, none lost, and the checkpoint
    /// afterwards at the folder's highest UID.
    private func killMidPassResumesFromTheLastCheckpoint(on server: MailServer) async throws {
        try await self.locked(on: server) {
            let store = try makeStore()
            let engine = IMAPSyncEngine(
                profile: self.profile(for: server), account: self.account, batchBytes: 300,
                // Pace the batches so the kill can land mid-pass: after each
                // checkpoint commit the pass sleeps here, giving the poll
                // loop a guaranteed window to cancel before the next batch.
                betweenBatches: { try await Task.sleep(for: .milliseconds(200)) }
            )

            let folder = server.freshFixtureFolder()
            try await server.resetFixture(folder: folder)
            try await server.seed((1...5).map { self.message("m\($0)") }, to: folder)

            // Pass 1: killed mid-sync. A detached task runs the pass; the
            // parent polls the archive's checkpoint and cancels the pass
            // task as soon as one is durable. Detached because cancelling a
            // child structured task from the parent body requires the
            // closure not to capture the parent's isolation — and the kill
            // must race nothing but the checkpoint.
            let passTask = Task.detached(priority: .medium) {
                do {
                    _ = try await engine.sync(
                        store: store, credentials: MailServer.user, password: MailServer.password
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
                let state = try store.syncState(account: self.account, mailbox: folder)
                // The first checkpoint already proves per-batch durability;
                // killing there leaves the widest window (more batches to
                // race the cancel against) for the kill to land mid-pass.
                if let state, state.highestUID >= 1 { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            passTask.cancel()
            let wasKilled = await passTask.value
            XCTAssertTrue(wasKilled, "\(server.name): the pass was killed mid-sync")

            // Whatever the kill left: a prefix of the five messages is
            // stored, and the checkpoint names it.
            let storedBefore = try self.count(store, "SELECT COUNT(*) FROM message")
            let checkpointBefore = try store.syncState(
                account: self.account, mailbox: folder
            )?.highestUID
            XCTAssertEqual(
                Int64(storedBefore), checkpointBefore,
                "\(server.name): every stored message is behind the checkpoint (per-batch durability)"
            )
            XCTAssertGreaterThan(storedBefore, 0)
            XCTAssertLessThan(storedBefore, 5, "\(server.name): the pass was killed mid-sync, not at the end")

            // Pass 2: the retry downloads exactly the rest — the killed
            // pass's uncheckpointed tail is re-fetched or deduped, but
            // nothing is lost and nothing is stored twice as new bytes.
            let resumed = try await self.sync(engine, store: store, server: server)
            XCTAssertEqual(resumed.messagesStored + resumed.messagesDuplicate, 5 - storedBefore)
            XCTAssertEqual(try self.count(store, "SELECT COUNT(*) FROM message"), 5)
            let allFive: Set<String> = ["srv-m1", "srv-m2", "srv-m3", "srv-m4", "srv-m5"]
            XCTAssertEqual(allFive, try self.storedSubjects(store))
            XCTAssertEqual(try self.highestUID(store, folder: folder), 5, "\(server.name): the checkpoint reaches the top")
        }
    }

    func testKillMidPassResumesFromTheLastCheckpointOnGreenMail() async throws {
        try await self.killMidPassResumesFromTheLastCheckpoint(on: try await self.server(.greenmail))
    }

    func testKillMidPassResumesFromTheLastCheckpointOnDovecot() async throws {
        try await self.killMidPassResumesFromTheLastCheckpoint(on: try await self.server(.dovecot))
    }

    // MARK: - Flow 4: a real UIDVALIDITY change, forced via RENAME

    /// The fake-server suite covers the engine's UIDVALIDITY-change behavior
    /// directly; this flow proves the transition against real servers, where
    /// the change is *forced*: the synced folder is renamed aside (RENAME,
    /// RFC 3501 §6.3.5 — DELETE is unusable on GreenMail for a folder any
    /// session ever selected, see the server-quirks reference), its remains
    /// are purged, and the original name is created anew — a brand-new
    /// mailbox with a new validity and UIDs restarting at 1. The next pass
    /// must notice the change, reset the checkpoint, refetch everything,
    /// store only the genuinely new bytes, dedupe the rest by content, and
    /// land on the new validity with the full highest UID.
    private func forcedUIDValidityChangeRefetchesAndDedupes(on server: MailServer) async throws {
        try await self.locked(on: server) {
            let store = try makeStore()
            let engine = IMAPSyncEngine(profile: self.profile(for: server), account: self.account)

            let folder = server.freshFixtureFolder()
            try await server.resetFixture(folder: folder)
            try await server.seed((1...5).map { self.message("m\($0)") }, to: folder)

            let full = try await self.sync(engine, store: store, server: server)
            XCTAssertEqual(full.messagesStored, 5, "\(server.name): first pass stores everything")
            let originalState = try store.syncState(account: self.account, mailbox: folder)
            let originalValidity = try XCTUnwrap(originalState?.uidValidity, "\(server.name): checkpoint exists after the first pass")

            // Force the change. The pause keeps the new mailbox's creation
            // second distinct from the old one's, so a time-derived validity
            // cannot collide with the original one.
            let tombstone = folder + "-tomb"
            try await server.renameFolder(from: folder, to: tombstone)
            try await server.purgeFolder(tombstone)
            try await Task.sleep(for: .milliseconds(1100))
            try await server.createFolder(folder)
            try await server.seed((1...7).map { self.message("m\($0)") }, to: folder)

            let after = try await self.sync(engine, store: store, server: server)
            let newState = try store.syncState(account: self.account, mailbox: folder)
            let newValidity = try XCTUnwrap(newState?.uidValidity, "\(server.name): checkpoint exists after the change")
            XCTAssertNotEqual(newValidity, originalValidity, "\(server.name): the engine saw and recorded a UIDVALIDITY change")
            XCTAssertEqual(newState?.highestUID, 7, "\(server.name): checkpoint reaches the new mailbox's top UID")
            XCTAssertEqual(after.messagesStored, 2, "\(server.name): only the two genuinely new messages store bytes")
            XCTAssertEqual(after.messagesDuplicate, 5, "\(server.name): the five re-offered messages dedupe by content")
            XCTAssertEqual(try self.count(store, "SELECT COUNT(*) FROM message"), 7, "\(server.name): nothing lost, nothing double-stored")
            let allSeven: Set<String> = ["srv-m1", "srv-m2", "srv-m3", "srv-m4", "srv-m5", "srv-m6", "srv-m7"]
            XCTAssertEqual(allSeven, try self.storedSubjects(store))
        }
    }

    func testForcedUIDValidityChangeRefetchesAndDedupesOnGreenMail() async throws {
        try await self.forcedUIDValidityChangeRefetchesAndDedupes(on: try await self.server(.greenmail))
    }

    func testForcedUIDValidityChangeRefetchesAndDedupesOnDovecot() async throws {
        try await self.forcedUIDValidityChangeRefetchesAndDedupes(on: try await self.server(.dovecot))
    }
}
