import ArchiveCore
import GRDB
import XCTest
@testable import MailSync

/// Regression test for the global-concurrent-pool starvation deadlock:
/// `ArchiveStore.ingest` runs its token stage with
/// `DispatchQueue.concurrentPerform`. When a batch ingest is called from an
/// arbitrary dispatch queue — the engine's `offPool` serial queue, GRDB's
/// writer queue, any third-party queue — concurrentPerform's calling thread
/// (a global-pool worker) blocks waiting for child work items that need the
/// same saturated global pool. With enough concurrent batch ingests the pool
/// fills with blocked parents and every child starves: the pass never
/// returns. The engine's real shape is: many `offPool { store.ingest(batch) }`
/// hops in flight at once, each inside a batch.
///
/// The test mirrors that shape on one store: concurrent batch ingests hopped
/// through dedicated serial dispatch queues (like `geist9.sync.store` and
/// GRDB's writer queue). Without the fix this deadlocks (the test hangs and
/// the suite's watchdog fails it); with it, ingest completes in milliseconds.
final class IngestPoolStarvationTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("geist9-starve-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
    }

    private func makeMessage(_ n: Int) -> IngestedMessage {
        let data = Data("""
        From: Alice <alice@example.com>\r
        To: Bob <bob@example.org>\r
        Subject: starve-\(n)\r
        Message-ID: <starve-\(n)@example.com>\r
        \r
        body \(n) words words words\r
        """.utf8)
        let parsed = MailBridge.parse(for: data, ocr: .deferred)
        return IngestedMessage(
            record: parsed.record,
            data: data,
            memberships: [Membership(mailbox: "INBOX", uid: Int64(n), flags: [], dateReceived: parsed.record.dateSent)],
            searchText: parsed.searchText
        )
    }

    /// N concurrent batch ingests, each hopped through its own serial queue
    /// (the engine's offPool pattern), all waited on with a hard deadline.
    func testConcurrentBatchIngestsFromDispatchQueuesDoNotStarve() async throws {
        let store = try ArchiveStore.create(
            at: tempDir.appendingPathComponent("Test.emailarchive"), appVersion: "0.1.0"
        )
        let account = AccountIdentity(email: "alice@example.com", displayName: "Alice", providerKind: "imap")

        // The engine's real shape: several ingest hops in flight at once,
        // each hopped through a serial queue (offPool / GRDB's writer), each
        // a batch whose token stage runs DispatchQueue.concurrentPerform.
        // 32 hops × batch of 13 is enough to fill the global pool with
        // blocked parents when the deadlock exists.
        let hops = 32
        let batch: [IngestedMessage] = (1...13).map { self.makeMessage($0) }

        let done = DispatchSemaphore(value: 0)
        final class ErrorBox: @unchecked Sendable {
            private let lock = NSLock()
            private var value: Error?
            func set(_ e: Error) { self.lock.lock(); if self.value == nil { self.value = e }; self.lock.unlock() }
            var error: Error? { self.lock.lock(); defer { self.lock.unlock() }; return self.value }
        }
        let box = ErrorBox()
        let queue = DispatchQueue(label: "geist9.test.hop")
        for _ in 0..<hops {
            queue.async {
                do {
                    // A write through GRDB first (the real path enters via
                    // the store's writer queue too), then the batch ingest.
                    try store.db.write { db in
                        _ = try Int.fetchOne(db, sql: "SELECT 1")
                    }
                    _ = try store.ingest(batch, into: account)
                } catch {
                    box.set(error)
                }
                done.signal()
            }
        }
        // All hops must finish within 10 seconds; a starvation deadlock
        // leaves them hung forever. The bounded wait runs on a plain
        // pthread (never the cooperative pool) bridged by a continuation:
        // on timeout the test fails at the deadline instead of parking
        // the task until the CI job cap.
        let ingestError: Error? = try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                var hop = 0
                do {
                    // Each hop's wait carries the deadline; the first one
                    // that expires fails the test instead of waiting more.
                    while hop < hops {
                        guard done.wait(timeout: .now() + 10) == .success else {
                            throw IngestHopTimedOut()
                        }
                        hop += 1
                    }
                    continuation.resume(returning: box.error)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        if let ingestError = ingestError { throw ingestError }
        let stored = try await store.db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message") }
        XCTAssertEqual(stored, 13)
    }
}

/// Thrown when the concurrent hops do not all finish within their
/// deadline: a starvation deadlock now fails the test at the deadline
/// instead of parking the task until the CI job cap.
private struct IngestHopTimedOut: Error {}
