@testable import ArchiveCore
import ArchiveSearch
import GRDB
import XCTest

/// The hybrid search wiring (decision 0045, slice 2): a registered
/// embedding model turns every query into a second, semantic ranked list
/// that merges with the keyword list by reciprocal rank fusion. With no
/// model, with the off switch set, or when the model cannot embed the
/// query, the answer is exactly the keyword-only search — the semantic
/// path can only add hits, never remove or reorder what keyword search
/// would have returned on its own. A hit found only by the semantic side
/// carries `viaSemantic` and no snippet or keyword rank. The backfill
/// fills in vectors for messages that lack them, is resumable, and never
/// rewrites a vector that already exists. Every test runs in a temporary
/// directory and uses the deterministic double, never the real model.
final class HybridSearchTests: XCTestCase {
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

    private let account = AccountIdentity(email: "alice@example.com", displayName: "Alice", providerKind: "import")

    private func makeMessage(
        subject: String,
        body: String,
        date: String = "2024-03-05T14:23:05Z"
    ) -> IngestedMessage {
        let record = MessageRecord(
            subject: subject,
            dateSent: Timestamp.date(date),
            dateReceived: Timestamp.date(date),
            messageID: "<\(subject)@example.com>",
            from: Recipient(name: "Alice", email: "alice@example.com"),
            to: [Recipient(name: "Bob", email: "bob@example.org")]
        )
        let data = Data("""
        From: Alice <alice@example.com>
        To: Bob <bob@example.org>
        Subject: \(subject)
        Message-ID: <\(subject)@example.com>

        \(body)
        """.utf8)
        return IngestedMessage(
            record: record,
            data: data,
            memberships: [Membership(mailbox: "INBOX", uid: 1, flags: [])],
            searchText: SearchText(body: body, quoted: nil)
        )
    }

    /// Ingests `count` messages and returns their message ids in order.
    private func ingest(_ store: ArchiveStore, count: Int) throws -> [Int64] {
        var ids: [Int64] = []
        for i in 1...count {
            let result = try store.ingest(
                makeMessage(subject: "Note \(i)", body: "plain body number \(i)"),
                into: account
            )
            guard case .created(let id) = result else {
                XCTFail("expected .created")
                continue
            }
            ids.append(id)
        }
        return ids
    }

    private func embeddingRowCount(_ store: ArchiveStore, model: String) throws -> Int {
        try store.db.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM message_embedding WHERE model = ?", arguments: [model]
            ) ?? 0
        }
    }

    private func storedVector(_ store: ArchiveStore, id: Int64, model: String) throws -> [Float]? {
        try store.db.read { db in
            let row = try Row.fetchOne(
                db, sql: "SELECT vector, dim FROM message_embedding WHERE id = ? AND model = ?",
                arguments: [id, model]
            )
            guard let row else { return nil }
            let data: Data? = row["vector"]
            let dim: Int = row["dim"]
            return data.flatMap { VectorIndex.decode($0, dimension: dim) }
        }
    }

    // MARK: - Hybrid search

    func testSemanticHitMergesWhenModelRegistered() throws {
        let store = try makeStore()
        let ids = try ingest(store, count: 3)
        let model = DeterministicEmbedding()
        // Give the third message exactly the query's vector: it ranks first
        // on the semantic side despite sharing no keyword with the query
        // (the query's tokens appear nowhere in any stored message).
        let queryVector = try XCTUnwrap(model.embed("zebra quantum pickle"))
        try store.db.write { db in
            try VectorIndex.upsert(db, messageID: ids[2], model: model.identifier, vector: queryVector)
        }
        let results = try store.search("zebra quantum pickle", semanticModel: model)
        let semanticHit = try XCTUnwrap(results.hits.first { $0.messageID == ids[2] })
        XCTAssertTrue(semanticHit.viaSemantic)
    }

    func testNoModelIsKeywordOnly() throws {
        let store = try makeStore()
        try ingest(store, count: 3)
        let plain = try store.search("plain body")
        let hybrid = try store.search("plain body", semanticModel: nil)
        XCTAssertEqual(hybrid, plain)
    }

    func testSemanticOffSwitchReturnsKeywordOnly() throws {
        let store = try makeStore()
        let ids = try ingest(store, count: 3)
        let model = DeterministicEmbedding()
        // Every message gets the query's exact vector: with the model on,
        // the semantic side would reorder everything, so any difference in
        // order proves the switch actually turned the semantic side off.
        let queryVector = try XCTUnwrap(model.embed("plain body"))
        try store.db.write { db in
            for id in ids {
                try VectorIndex.upsert(
                    db, messageID: id, model: model.identifier, vector: queryVector
                )
            }
        }
        let plain = try store.search("plain body", semanticModel: model, semanticEnabled: false)
        let hybrid = try store.search("plain body", semanticModel: model)
        // With the switch off the answer must be exactly the keyword list.
        XCTAssertEqual(hybrid.hits.map(\.messageID), plain.hits.map(\.messageID))
        XCTAssertFalse(hybrid.hits.contains { $0.viaSemantic })
    }

    func testSemanticOnlyHitHasNoSnippetAndNoKeywordRank() throws {
        let store = try makeStore()
        let ids = try ingest(store, count: 3)
        let model = DeterministicEmbedding()
        let queryVector = try XCTUnwrap(model.embed("zebra quantum pickle"))
        try store.db.write { db in
            try VectorIndex.upsert(db, messageID: ids[1], model: model.identifier, vector: queryVector)
        }
        let results = try store.search("zebra quantum pickle", semanticModel: model)
        let hit = try XCTUnwrap(results.hits.first { $0.messageID == ids[1] })
        XCTAssertTrue(hit.viaSemantic)
        XCTAssertNil(hit.snippet)
        XCTAssertNil(hit.rank)
    }

    func testMessageHitByBothSidesOutranksSingleSideHits() throws {
        let store = try makeStore()
        let ids = try ingest(store, count: 3)
        let model = DeterministicEmbedding()
        // Message 3 matches the query on the keyword side, and its vector
        // is set to the query's, so it matches on both sides; messages 1
        // and 2 are found only by the semantic side. Reciprocal rank
        // fusion must rank the both-sides hit first, and a hit found by
        // both sides keeps its keyword data, not the semantic-only flag.
        let queryVector = try XCTUnwrap(model.embed("number 3"))
        try store.db.write { db in
            try VectorIndex.upsert(db, messageID: ids[0], model: model.identifier, vector: [1, 0, 0, 0])
            try VectorIndex.upsert(db, messageID: ids[1], model: model.identifier, vector: [0, 1, 0, 0])
            try VectorIndex.upsert(db, messageID: ids[2], model: model.identifier, vector: queryVector)
        }
        let results = try store.search("number 3", semanticModel: model)
        XCTAssertEqual(results.hits.first?.messageID, ids[2])
        XCTAssertFalse(results.hits.first?.viaSemantic ?? true)
        XCTAssertTrue(results.hits.contains { $0.messageID == ids[0] })
    }

    func testEmbeddingNilFallsBackToKeywordOnly() throws {
        let store = try makeStore()
        try ingest(store, count: 3)
        let model = NeverEmbedding()
        let plain = try store.search("plain body")
        let hybrid = try store.search("plain body", semanticModel: model)
        XCTAssertEqual(hybrid, plain)
    }

    /// Records which entry point search used: the query must travel
    /// through `queryEmbed`, never the document path, so a model like bge
    /// can put its instruction prefix on queries only (decision 0045).
    private final class QueryProbeEmbedding: EmbeddingModel, @unchecked Sendable {
        var identifier: String { "probe-v1" }
        var dimension: Int { 4 }
        let documentVector: [Float] = [0, 0, 0, 1]
        let queryVector: [Float] = [1, 0, 0, 0]
        private let lock = NSLock()
        private var queried: [String] = []
        private var embedded: [String] = []
        func embed(_ text: String) -> [Float]? {
            lock.lock(); embedded.append(text); lock.unlock()
            return documentVector
        }
        func queryEmbed(_ text: String) -> [Float]? {
            lock.lock(); queried.append(text); lock.unlock()
            return queryVector
        }
        var queryCalls: [String] { lock.withLock { queried } }
        var embedCalls: [String] { lock.withLock { embedded } }
    }

    func testSearchEmbedsQueryThroughQueryEmbedOnly() throws {
        let store = try makeStore()
        let ids = try ingest(store, count: 2)
        let probe = QueryProbeEmbedding()
        try store.db.write { db in
            try VectorIndex.upsert(db, messageID: ids[0], model: probe.identifier, vector: probe.queryVector)
            try VectorIndex.upsert(db, messageID: ids[1], model: probe.identifier, vector: probe.documentVector)
        }
        // The planted vector for message 1 equals queryEmbed("find me");
        // if search routed the query through the document path, message 2
        // (the document vector) would rank first instead.
        let results = try store.search("find me", semanticModel: probe)
        XCTAssertEqual(results.hits.first?.messageID, ids[0])
        XCTAssertEqual(probe.queryCalls, ["find me"], "search embeds the query exactly once, via queryEmbed")
        XCTAssertTrue(probe.embedCalls.isEmpty, "search never embeds message text")
    }

    func testHybridOffsetPagesFusedList() throws {
        let store = try makeStore()
        let ids = try ingest(store, count: 3)
        let model = DeterministicEmbedding()
        // Every message matches the query's keywords, and message 2's
        // vector matches the query exactly, so fusion puts message 2
        // first; page one (offset 1) must then show the remaining
        // keyword-only hits.
        let queryVector = try XCTUnwrap(model.embed("plain body"))
        try store.db.write { db in
            try VectorIndex.upsert(db, messageID: ids[1], model: model.identifier, vector: queryVector)
        }
        let pageOne = try store.search("plain body", limit: 10, offset: 1, semanticModel: model)
        XCTAssertEqual(pageOne.hits.count, 2)
        XCTAssertFalse(pageOne.hits.contains { $0.messageID == ids[1] })
    }

    // MARK: - Backfill

    func testBackfillEmbedsEveryMessageMissingVectors() throws {
        let store = try makeStore()
        let ids = try ingest(store, count: 4)
        let model = DeterministicEmbedding()
        let added = try EmbeddingBackfill.run(store, model: model)
        XCTAssertEqual(added, 4)
        XCTAssertEqual(try embeddingRowCount(store, model: model.identifier), 4)
        // The stored vector for each message is the model's embedding of
        // the documented text basis (subject + opening text). Storage is
        // little-endian binary16, so compare with float16 tolerance.
        let expected = try XCTUnwrap(
            model.embed(EmbeddingBackfill.documentText(subject: "Note 1", body: "plain body number 1"))
        )
        assertVectorsClose(
            try XCTUnwrap(storedVector(store, id: ids[0], model: model.identifier)),
            expected
        )
    }

    func testBackfillSkipsMessagesThatAlreadyHaveVectors() throws {
        let store = try makeStore()
        let ids = try ingest(store, count: 2)
        let model = DeterministicEmbedding()
        let sentinel: [Float] = [1, 0, 0, 0]
        try store.db.write { db in
            try VectorIndex.upsert(db, messageID: ids[0], model: model.identifier, vector: sentinel)
        }
        let added = try EmbeddingBackfill.run(store, model: model)
        XCTAssertEqual(added, 1)
        XCTAssertEqual(try storedVector(store, id: ids[0], model: model.identifier), sentinel)
    }

    func testBackfillIsBoundedForOnePass() throws {
        let store = try makeStore()
        try ingest(store, count: 5)
        let model = DeterministicEmbedding()
        let added = try EmbeddingBackfill.run(store, model: model, maxMessages: 2)
        XCTAssertEqual(added, 2)
        XCTAssertEqual(try embeddingRowCount(store, model: model.identifier), 2)
        // A second pass finishes the rest.
        let rest = try EmbeddingBackfill.run(store, model: model)
        XCTAssertEqual(rest, 3)
        XCTAssertEqual(try embeddingRowCount(store, model: model.identifier), 5)
    }

    func testBackfillKeepsModelsSeparate() throws {
        let store = try makeStore()
        try ingest(store, count: 2)
        let first = DeterministicEmbedding(identifier: "model-a")
        let second = DeterministicEmbedding(identifier: "model-b")
        let firstAdded = try EmbeddingBackfill.run(store, model: first)
        XCTAssertEqual(firstAdded, 2)
        XCTAssertEqual(try embeddingRowCount(store, model: "model-a"), 2)
        let added = try EmbeddingBackfill.run(store, model: second)
        XCTAssertEqual(added, 2, "a second model backfills from scratch")
        XCTAssertEqual(try embeddingRowCount(store, model: "model-a"), 2)
        XCTAssertEqual(try embeddingRowCount(store, model: "model-b"), 2)
    }
}

/// A double that never produces a vector, to prove the hybrid path
/// degrades to keyword-only without surfacing an error.
private struct NeverEmbedding: EmbeddingModel {
    var identifier: String { "never-v1" }
    var dimension: Int { 4 }
    func embed(_ text: String) -> [Float]? { nil }
}

/// Vectors travel through little-endian binary16 storage, so a stored
/// vector matches the model's float32 output only to float16 precision.
private func assertVectorsClose(
    _ stored: [Float],
    _ expected: [Float],
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(stored.count, expected.count, "stored vector dimension", file: file, line: line)
    for (got, want) in zip(stored, expected) {
        XCTAssertEqual(got, want, accuracy: 0.002, file: file, line: line)
    }
}
