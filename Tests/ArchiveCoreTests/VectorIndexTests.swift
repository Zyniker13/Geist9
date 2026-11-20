import XCTest
import GRDB
@testable import ArchiveCore

/// Tests for the semantic-search vector index and reciprocal rank fusion
/// (decision 0045): the `message_embedding` table stores one float16 vector
/// per message, search scans by cosine similarity, and `RankFusion.rrf`
/// merges keyword and semantic ranked lists into one ordering.
final class VectorIndexTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("vectorindex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        _ = try ArchiveStore.create(at: archiveURL, appVersion: "0.1.0")
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: scratch)
    }

    private var archiveURL: URL { scratch.appendingPathComponent("Archive") }

    private let account = AccountIdentity(email: "alice@example.com", displayName: "Alice", providerKind: "import")

    private func makeMessage(_ subject: String) -> IngestedMessage {
        let record = MessageRecord(
            subject: subject,
            dateSent: Timestamp.date("2024-03-05T14:23:05Z"),
            dateReceived: Timestamp.date("2024-03-05T14:23:05Z"),
            messageID: "<\(subject)@example.com>",
            from: Recipient(name: "Alice", email: "alice@example.com"),
            to: [Recipient(name: "Bob", email: "bob@example.org")]
        )
        let data = Data("""
        From: Alice <alice@example.com>
        To: Bob <bob@example.org>
        Subject: \(subject)
        Message-ID: <\(subject)@example.com>

        body of \(subject)
        """.utf8)
        return IngestedMessage(
            record: record,
            data: data,
            memberships: [Membership(mailbox: "INBOX", uid: 1, flags: [])]
        )
    }

    /// Ingest `count` messages and return their row ids in order.
    private func ingest(_ store: ArchiveStore, count: Int) throws -> [Int64] {
        var ids: [Int64] = []
        for n in 1...count {
            let result = try store.ingest(makeMessage("Vector test \(n)"), into: account)
            guard case let .created(id) = result else {
                XCTFail("expected a new row")
                return []
            }
            ids.append(id)
        }
        return ids
    }

    // MARK: - Cosine and float16 codec

    func testCosineRanksAlignedAboveOrthogonal() throws {
        let aligned = VectorIndex.cosine([1, 0, 0, 0], [1, 0, 0, 0])
        let tilted = VectorIndex.cosine([1, 0, 0, 0], [0.6, 0.8, 0, 0])
        let orthogonal = VectorIndex.cosine([1, 0, 0, 0], [0, 0, 1, 0])
        XCTAssertEqual(aligned!, 1.0, accuracy: 0.0001)
        XCTAssertEqual(tilted!, 0.6, accuracy: 0.0001)
        XCTAssertEqual(orthogonal!, 0.0, accuracy: 0.0001)
    }

    func testCosineRejectsDimensionMismatchAndZeroVectors() throws {
        XCTAssertNil(VectorIndex.cosine([1, 0, 0], [1, 0, 0, 0]))
        XCTAssertNil(VectorIndex.cosine([0, 0, 0, 0], [1, 0, 0, 0]))
        XCTAssertNil(VectorIndex.cosine([1, 0, 0, 0], [0, 0, 0, 0]))
    }

    func testFloat16RoundtripAccuracy() throws {
        let vector: [Float] = [0, 1, -1, 0.5, -0.25, 3.14159, -2.71828, 0.001]
        let decoded = VectorIndex.decode(VectorIndex.encode(vector), dimension: vector.count)
        XCTAssertEqual(decoded?.count, vector.count)
        for (a, b) in zip(vector, decoded!) {
            XCTAssertEqual(a, b, accuracy: 0.002)
        }
        // Two bytes per element.
        XCTAssertEqual(VectorIndex.encode(vector).count, vector.count * 2)
    }

    func testDecodeRejectsTruncatedBlob() throws {
        XCTAssertNil(VectorIndex.decode(Data([0x3c, 0x00, 0x00]), dimension: 2))
        XCTAssertNil(VectorIndex.decode(Data(), dimension: 4))
    }

    // MARK: - Store-backed search

    func testUpsertThenSearchRanksByCosineDescending() throws {
        let store = try ArchiveStore.open(at: archiveURL)
        let ids = try ingest(store, count: 3)
        try store.db.write { db in
            try VectorIndex.upsert(db, messageID: ids[0], model: "bge-small-en-v1.5", vector: [1, 0, 0, 0])
            try VectorIndex.upsert(db, messageID: ids[1], model: "bge-small-en-v1.5", vector: [0.6, 0.8, 0, 0])
            try VectorIndex.upsert(db, messageID: ids[2], model: "bge-small-en-v1.5", vector: [0, 0, 1, 0])
        }
        let hits = try store.db.read { db in
            try VectorIndex.search(db, model: "bge-small-en-v1.5", query: [1, 0, 0, 0], limit: 10)
        }
        XCTAssertEqual(hits.map(\.messageID), [ids[0], ids[1], ids[2]])
        XCTAssertEqual(hits[0].score, 1.0, accuracy: 0.01)
        XCTAssertEqual(hits[1].score, 0.6, accuracy: 0.01)
        XCTAssertEqual(hits[2].score, 0.0, accuracy: 0.01)
    }

    func testUpsertReplacesPreviousVectorForSameMessage() throws {
        let store = try ArchiveStore.open(at: archiveURL)
        let ids = try ingest(store, count: 1)
        try store.db.write { db in
            try VectorIndex.upsert(db, messageID: ids[0], model: "m", vector: [1, 0, 0, 0])
            try VectorIndex.upsert(db, messageID: ids[0], model: "m", vector: [0, 1, 0, 0])
        }
        let rows = try store.db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message_embedding WHERE id = ?", arguments: [ids[0]])
        }
        XCTAssertEqual(rows, 1)
        let hits = try store.db.read { db in
            try VectorIndex.search(db, model: "m", query: [0, 1, 0, 0], limit: 10)
        }
        XCTAssertEqual(hits.first?.messageID, ids[0])
        XCTAssertEqual(hits.first?.score ?? 0, 1.0, accuracy: 0.01)
    }

    func testSearchIgnoresOtherModels() throws {
        let store = try ArchiveStore.open(at: archiveURL)
        let ids = try ingest(store, count: 2)
        try store.db.write { db in
            try VectorIndex.upsert(db, messageID: ids[0], model: "model-a", vector: [1, 0, 0, 0])
            try VectorIndex.upsert(db, messageID: ids[1], model: "model-b", vector: [0.99, 0.1, 0, 0])
        }
        let hits = try store.db.read { db in
            try VectorIndex.search(db, model: "model-a", query: [1, 0, 0, 0], limit: 10)
        }
        XCTAssertEqual(hits.map(\.messageID), [ids[0]])
    }

    func testSearchRejectsQueryDimensionMismatch() throws {
        let store = try ArchiveStore.open(at: archiveURL)
        let ids = try ingest(store, count: 1)
        try store.db.write { db in
            try VectorIndex.upsert(db, messageID: ids[0], model: "m", vector: [1, 0, 0, 0])
        }
        XCTAssertThrowsError(try store.db.read { db in
            try VectorIndex.search(db, model: "m", query: [1, 0], limit: 10)
        })
    }

    func testUpsertRejectsDimensionChangeForSameModel() throws {
        let store = try ArchiveStore.open(at: archiveURL)
        let ids = try ingest(store, count: 1)
        try store.db.write { db in
            try VectorIndex.upsert(db, messageID: ids[0], model: "m", vector: [1, 0, 0, 0])
            XCTAssertThrowsError(
                try VectorIndex.upsert(db, messageID: ids[0], model: "m", vector: [1, 0])
            )
        }
    }

    func testUpsertRejectsEmptyVector() throws {
        let store = try ArchiveStore.open(at: archiveURL)
        let ids = try ingest(store, count: 1)
        XCTAssertThrowsError(try store.db.write { db in
            try VectorIndex.upsert(db, messageID: ids[0], model: "m", vector: [])
        })
    }

    func testRemoveDropsTheRow() throws {
        let store = try ArchiveStore.open(at: archiveURL)
        let ids = try ingest(store, count: 2)
        try store.db.write { db in
            try VectorIndex.upsert(db, messageID: ids[0], model: "m", vector: [1, 0, 0, 0])
            try VectorIndex.upsert(db, messageID: ids[1], model: "m", vector: [0, 1, 0, 0])
            try VectorIndex.remove(db, messageID: ids[0])
        }
        let hits = try store.db.read { db in
            try VectorIndex.search(db, model: "m", query: [0, 1, 0, 0], limit: 10)
        }
        XCTAssertEqual(hits.map(\.messageID), [ids[1]])
    }

    func testDeletingMessageCascadesTheEmbeddingRow() throws {
        let store = try ArchiveStore.open(at: archiveURL)
        let ids = try ingest(store, count: 1)
        try store.db.write { db in
            try VectorIndex.upsert(db, messageID: ids[0], model: "m", vector: [1, 0, 0, 0])
            try db.execute(sql: "DELETE FROM message WHERE id = ?", arguments: [ids[0]])
            let remaining = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM message_embedding"
            )
            XCTAssertEqual(remaining, 0)
        }
    }

    func testSearchTreatsUnreadableVectorRowAsAbsent() throws {
        let store = try ArchiveStore.open(at: archiveURL)
        let ids = try ingest(store, count: 2)
        try store.db.write { db in
            try VectorIndex.upsert(db, messageID: ids[0], model: "m", vector: [1, 0, 0, 0])
            try VectorIndex.upsert(db, messageID: ids[1], model: "m", vector: [0, 1, 0, 0])
            // Corrupt one stored vector; the row must be skipped, not crash.
            try db.execute(sql: "UPDATE message_embedding SET vector = x'0000' WHERE id = ?", arguments: [ids[0]])
        }
        let hits = try store.db.read { db in
            try VectorIndex.search(db, model: "m", query: [0, 1, 0, 0], limit: 10)
        }
        XCTAssertEqual(hits.map(\.messageID), [ids[1]])
    }

    func testSearchLimitTruncates() throws {
        let store = try ArchiveStore.open(at: archiveURL)
        let ids = try ingest(store, count: 4)
        // Cosine is magnitude-blind, so distinct scores need distinct angles:
        // 1.0, 0.6, 0.0, −1.0 against the query [1, 0].
        let angles: [[Float]] = [[1, 0], [0.6, 0.8], [0, 1], [-1, 0]]
        try store.db.write { db in
            for (i, id) in ids.enumerated() {
                try VectorIndex.upsert(db, messageID: id, model: "m", vector: angles[i])
            }
        }
        let hits = try store.db.read { db in
            try VectorIndex.search(db, model: "m", query: [1, 0], limit: 2)
        }
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits[0].score, 1.0, accuracy: 0.01)
        XCTAssertEqual(hits[1].score, 0.6, accuracy: 0.01)
    }

    func testSearchTieBreaksByMessageIDAscending() throws {
        let store = try ArchiveStore.open(at: archiveURL)
        let ids = try ingest(store, count: 3)
        try store.db.write { db in
            for id in ids {
                try VectorIndex.upsert(db, messageID: id, model: "m", vector: [1, 0, 0, 0])
            }
        }
        let hits = try store.db.read { db in
            try VectorIndex.search(db, model: "m", query: [1, 0, 0, 0], limit: 10)
        }
        XCTAssertEqual(hits.map(\.messageID), ids.sorted())
    }

    func testSearchOnEmptyIndexReturnsEmpty() throws {
        let store = try ArchiveStore.open(at: archiveURL)
        let hits = try store.db.read { db in
            try VectorIndex.search(db, model: "m", query: [1, 0, 0, 0], limit: 10)
        }
        XCTAssertEqual(hits, [])
    }

    /// An index written before the embedding table existed migrates forward
    /// on open, and the new table works on the migrated rows.
    func testIndexMigratesV11ArchiveToCurrentSchema() throws {
        let indexURL = archiveURL.appendingPathComponent(ArchiveStore.indexName)
        let pool = try DatabasePool(path: indexURL.path)
        try IndexSchema.migrator(through: "core-v11").migrate(pool)
        try pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO account (email, displayName, providerKind)
                VALUES ('alice@example.com', 'Alice', 'import')
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
        try store.db.write { db in
            try VectorIndex.upsert(db, messageID: 1, model: "m", vector: [1, 0, 0, 0])
        }
        let hits = try store.db.read { db in
            try VectorIndex.search(db, model: "m", query: [1, 0, 0, 0], limit: 10)
        }
        XCTAssertEqual(hits.map(\.messageID), [1])
    }

    // MARK: - Reciprocal rank fusion

    func testRRFSumsContributionsAcrossLists() throws {
        // Document 7 is first in both lists (2 × 1/61 ≈ 0.0328) and must
        // outrank document 2, first in one list only (1/61 ≈ 0.0164).
        let merged = RankFusion.rrf([[7, 2], [7, 3]], limit: 10)
        XCTAssertEqual(merged.first?.id, 7)
        XCTAssertEqual(merged[0].score, 2.0 / 61.0, accuracy: 0.0001)
        XCTAssertEqual(merged[1].id, 2)
        XCTAssertEqual(merged[2].id, 3)
        // Positions 1 in each list tie exactly; deterministic order by id.
        XCTAssertEqual(merged[1].score, merged[2].score, accuracy: 0.0001)
    }

    func testRRFRankPositionMatters() throws {
        // Rank 1 beats rank 2 within a single list.
        let merged = RankFusion.rrf([[5, 6]], limit: 10)
        XCTAssertEqual(merged.map(\.id), [5, 6])
        XCTAssertEqual(merged[0].score, 1.0 / 61.0, accuracy: 0.0001)
        XCTAssertEqual(merged[1].score, 1.0 / 62.0, accuracy: 0.0001)
    }

    func testRRFLimitTruncates() throws {
        let merged = RankFusion.rrf([[1, 2, 3, 4, 5]], limit: 2)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.map(\.id), [1, 2])
    }

    func testRRFHandlesEmptyLists() throws {
        XCTAssertEqual(RankFusion.rrf([], limit: 10).count, 0)
        XCTAssertEqual(RankFusion.rrf([[], []], limit: 10).count, 0)
        XCTAssertEqual(RankFusion.rrf([[], [9]], limit: 10).map(\.id), [9])
    }

    func testRRFTieBreaksDeterministically() throws {
        // Two documents with identical contributions sort by ascending id.
        let merged = RankFusion.rrf([[40, 30], [30, 40]], limit: 10)
        XCTAssertEqual(merged.map(\.id), [30, 40])
        XCTAssertEqual(merged[0].score, merged[1].score, accuracy: 0.0001)
    }
}
