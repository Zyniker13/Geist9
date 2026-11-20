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

    // MARK: - Clustering (decision 0046)

    /// A unit vector at `degrees` in a smooth family: with the half-period
    /// spread across `dim` coordinates the cosine between two of these is
    /// the cosine of their angle difference, so tests can reason in angles.
    private func vector(atDegrees degrees: Double, dim: Int = 64) -> [Float] {
        var v = [Float](repeating: 0, count: dim)
        let radians = degrees * .pi / 180
        for i in 0..<dim {
            v[i] = Float(sin(radians + Double(i) * .pi / Double(dim)))
        }
        return v
    }

    /// Writes `rows` vectors: family `j` of `families`, its slots spread
    /// evenly around the family angle (families 45° apart), ids
    /// `j * rows + slot`.
    private func seedFamilies(
        _ pool: DatabaseWriter, families: Int, slots: Int, dim: Int = 64
    ) throws {
        try pool.write { db in
            for j in 0..<families {
                for slot in 0..<slots {
                    let degrees = Double(j) * 45 + Double(slot - slots / 2) * 2
                    try VectorIndex.upsert(
                        db, messageID: Int64(j * slots + slot + 1),
                        model: "m", vector: vector(atDegrees: degrees, dim: dim)
                    )
                }
            }
        }
    }

    /// A bare pool for synthetic vector rows: no message rows exist behind
    /// them, so referential enforcement is off. Message-deletion cascade
    /// behavior is covered separately on a full ArchiveStore with FKs on.
    private func vectorPool(_ index: String = ArchiveStore.indexName) throws -> DatabasePool {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = false
        return try DatabasePool(
            path: archiveURL.appendingPathComponent(index).path,
            configuration: configuration
        )
    }

    /// Clustering keeps the exact scores of the rows it visits: the result
    /// equals the exact flat scan pairwise, not just as a set.
    func testClusteredSearchMatchesExactScanOrder() throws {
        let pool = try vectorPool()
        try seedFamilies(pool, families: 3, slots: 30)
        let count = try pool.write { db in
            try VectorIndex.buildClusters(db, model: "m", clusterCount: 3, seed: 1)
        }
        XCTAssertEqual(count, 3)
        let clustered = try pool.read { db in
            try VectorIndex.search(db, model: "m", query: vector(atDegrees: 5), limit: 5)
        }
        let exact = try pool.read { db in
            try VectorIndex.search(db, model: "m", query: vector(atDegrees: 5), limit: 5, nprobe: nil)
        }
        XCTAssertEqual(clustered.map(\.messageID), exact.map(\.messageID))
        for (clusteredHit, exactHit) in zip(clustered, exact) {
            XCTAssertEqual(clusteredHit.score, exactHit.score, accuracy: 0.000001)
        }
        // The top of the list is the east family, and every visited row
        // reports its exact float16-rounded score.
        XCTAssertEqual(clustered.first?.score ?? 0, 1.0, accuracy: 0.001)
    }

    /// Only probed clusters are scanned: with two of four families probed,
    /// rows of the far families cannot appear even when the keeper has room.
    func testClusteredScanProbesNearestClusters() throws {
        let pool = try vectorPool()
        try seedFamilies(pool, families: 4, slots: 3)
        let count = try pool.write { db in
            try VectorIndex.buildClusters(db, model: "m", clusterCount: 4, seed: 3)
        }
        XCTAssertEqual(count, 4)
        // Query near the east family (0°): the two probed clusters are east
        // and northeast (45°); the 135° family is never scanned.
        let clustered = try pool.read { db in
            try VectorIndex.search(db, model: "m", query: vector(atDegrees: 5), limit: 4, nprobe: 2)
        }
        XCTAssertEqual(clustered.count, 4)
        for hit in clustered {
            let family = (hit.messageID - 1) / 3
            XCTAssertLessThan(family, 2, "row \(hit.messageID) is outside the probed families")
        }
        let ids = Set(clustered.map(\.messageID))
        // An east row is present.
        XCTAssertTrue(ids.contains(1))
        // A northeast row is present.
        XCTAssertTrue(ids.contains(4))
        // No 135°-family row: ids 10..12 belong to that family.
        XCTAssertTrue(ids.isDisjoint(with: [10, 11, 12]))
    }

    /// With too few probes the clustered scan misses rows the exact scan
    /// returns — the honest cost of the approximation, pinned here so any
    /// accidental fallback to exactness (or over-probing) is visible.
    func testClusteredSearchAndExactDisagreeAtLowProbeCount() throws {
        let pool = try vectorPool()
        try seedFamilies(pool, families: 8, slots: 8)
        let count = try pool.write { db in
            try VectorIndex.buildClusters(db, model: "m", clusterCount: 8, seed: 5)
        }
        XCTAssertEqual(count, 8)
        // Query between the 0° and 45° families, slightly closer to 0°, so
        // one probe covers only the 0° family.
        let clustered = try pool.read { db in
            try VectorIndex.search(db, model: "m", query: vector(atDegrees: 21), limit: 8, nprobe: 1)
        }
        let exact = try pool.read { db in
            try VectorIndex.search(db, model: "m", query: vector(atDegrees: 21), limit: 8, nprobe: nil)
        }
        // Clustered: only 0°-family rows (ids 1..8), best first.
        XCTAssertEqual(clustered.map(\.messageID), [8, 7, 6, 5, 4, 3, 2, 1])
        // Exact: four 0°-family rows (the near side) and four 45°-family rows.
        XCTAssertEqual(
            Set(exact.map(\.messageID)),
            Set([5, 6, 7, 8, 9, 10, 11, 12])
        )
    }

    /// Clustering thresholds: nothing to cluster when there are no rows or
    /// too few of them, and no rebuild until enough rows lost assignment.
    func testClusteringThresholdsGateRun() throws {
        let pool = try vectorPool()
        let empty = try pool.write { db in
            try VectorIndex.maybeCluster(db, model: "m")
        }
        XCTAssertEqual(empty, 0)
        try seedFamilies(pool, families: 3, slots: 1)
        let tiny = try pool.write { db in
            try VectorIndex.maybeCluster(db, model: "m")
        }
        XCTAssertEqual(tiny, 0, "below clusterMinRows the exact scan stays")
    }

    /// The stored centroids: count, per-cluster membership counters, ordered
    /// indexes, and float16 storage (two bytes per coordinate).
    func testClustersListCountersAndFloat16Storage() throws {
        let pool = try vectorPool()
        try seedFamilies(pool, families: 2, slots: 3)
        try pool.write { db in
            try VectorIndex.buildClusters(db, model: "m", clusterCount: 2, seed: 7)
        }
        let clusters = try pool.read { db in
            try VectorIndex.clusters(db, model: "m")
        }
        XCTAssertEqual(clusters.map(\.index), [0, 1])
        XCTAssertEqual(clusters.map(\.count), [3, 3])
        XCTAssertEqual(clusters.map(\.centroid.count), [64, 64])
        let blobLength = try pool.read { db in
            try Data.fetchOne(
                db, sql: "SELECT centroid FROM embedding_cluster WHERE cluster = 0"
            )?.count
        }
        XCTAssertEqual(blobLength, 128)
    }

    /// Re-embedding a message clears its assignment; the other rows keep
    /// theirs, and once enough rows are stale the next maybeCluster run
    /// rebuilds and reassigns everything.
    func testReembeddingResetsAssignmentAndTriggersRebuild() throws {
        let pool = try vectorPool()
        try seedFamilies(pool, families: 2, slots: 3)
        try pool.write { db in
            try VectorIndex.buildClusters(db, model: "m", clusterCount: 2, seed: 9)
        }
        var assigned = try pool.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM message_embedding WHERE cluster IS NULL"
            ) ?? -1
        }
        XCTAssertEqual(assigned, 0)
        try pool.write { db in
            try VectorIndex.upsert(db, messageID: 1, model: "m", vector: vector(atDegrees: 3))
        }
        let reembedded = try pool.read { db in
            try Int.fetchOne(
                db, sql: "SELECT cluster FROM message_embedding WHERE id = 1"
            )
        }
        XCTAssertNil(reembedded, "a rewritten vector must lose its stale assignment")
        assigned = try pool.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM message_embedding WHERE cluster IS NULL"
            ) ?? -1
        }
        XCTAssertEqual(assigned, 1)
        // 1 stale row of 6 is above the 10% threshold: rebuild reassigns all.
        // (The rebuilt count itself is the default k for 6 rows, not 2.)
        let rebuilt = try pool.write { db in
            try VectorIndex.maybeCluster(db, model: "m")
        }
        XCTAssertGreaterThan(rebuilt, 0)
        assigned = try pool.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM message_embedding WHERE cluster IS NULL"
            ) ?? -1
        }
        XCTAssertEqual(assigned, 0)
    }

    /// Scan results are independent of the internal batch size — the
    /// keeper sees the same rows in the same order either way. Forces a
    /// multi-batch scan (13 batches at batchSize 7), which is what caught
    /// the stale-WHERE-argument regression: a cursor whose id argument
    /// never advanced re-fetched the first batch forever.
    func testScanOrderUnaffectedByBatchSize() throws {
        let pool = try vectorPool()
        try seedFamilies(pool, families: 3, slots: 30)
        try pool.write { db in
            try VectorIndex.buildClusters(db, model: "m", clusterCount: 3, seed: 11)
        }
        let small = try pool.read { db in
            try VectorIndex.search(db, model: "m", query: vector(atDegrees: 40), limit: 10, batchSize: 7)
        }
        let large = try pool.read { db in
            try VectorIndex.search(db, model: "m", query: vector(atDegrees: 40), limit: 10, batchSize: 512)
        }
        XCTAssertEqual(small.map(\.messageID), large.map(\.messageID))
        XCTAssertEqual(small.map(\.score), large.map(\.score))
    }

    /// Clustering a fresh archive is reproducible: same seed, same
    /// centroids; different seed, different centroids.
    func testClusteringIsReproducibleForSameSeed() throws {
        let first = try vectorPool()
        try seedFamilies(first, families: 2, slots: 10)
        try first.write { db in
            try VectorIndex.buildClusters(db, model: "m", clusterCount: 2, seed: 13)
        }
        let fromFirst = try first.read { db in
            try VectorIndex.clusters(db, model: "m")
        }

        // The second pool is a fresh archive: create it so the schema is
        // migrated, then reopen its index file with FKs off for the
        // synthetic vector rows.
        let secondRoot = archiveURL.deletingLastPathComponent()
            .appendingPathComponent("Archive2")
        _ = try ArchiveStore.create(at: secondRoot, appVersion: "0.1.0")
        var secondConfig = Configuration()
        secondConfig.foreignKeysEnabled = false
        let second = try DatabasePool(
            path: secondRoot.appendingPathComponent(ArchiveStore.indexName).path,
            configuration: secondConfig
        )
        try seedFamilies(second, families: 2, slots: 10)
        try second.write { db in
            try VectorIndex.buildClusters(db, model: "m", clusterCount: 2, seed: 13)
        }
        let fromSecond = try second.read { db in
            try VectorIndex.clusters(db, model: "m")
        }
        XCTAssertEqual(fromFirst, fromSecond)

        // A different seed is a different run: it must still produce a
        // valid two-cluster partition of all 20 rows. (Well-separated data
        // can converge to the same means either way, so no inequality is
        // asserted on the centroids themselves.)
        try second.write { db in
            try VectorIndex.buildClusters(db, model: "m", clusterCount: 2, seed: 14)
        }
        let otherSeed = try second.read { db in
            try VectorIndex.clusters(db, model: "m")
        }
        XCTAssertEqual(otherSeed.count, 2)
        XCTAssertEqual(otherSeed.reduce(0) { $0 + $1.count }, 20)
    }

    /// The vectorized trainer math and the scalar fallback agree on
    /// cluster assignments for well-separated synthetic data.
    func testGemmAndScalarNearestCentroidsAgree() throws {
        let dim = 64
        var flat: [Float] = []
        var expected: [Int] = []
        var centroids: [[Float]] = []
        for j in 0..<3 { centroids.append(vector(atDegrees: Double(j) * 90, dim: dim)) }
        for row in 0..<300 {
            let family = row % 3
            let degrees = Double(family) * 90 + Double(row % 5 - 2) * 2
            flat.append(contentsOf: vector(atDegrees: degrees, dim: dim))
            expected.append(family)
        }
        let accelerated = VectorIndex.nearestCentroids(
            flat: flat, count: 300, dim: dim, centroids: centroids, useAccelerate: true
        )
        let scalar = VectorIndex.nearestCentroids(
            flat: flat, count: 300, dim: dim, centroids: centroids, useAccelerate: false
        )
        XCTAssertEqual(accelerated, expected)
        XCTAssertEqual(scalar, expected)
    }

    /// An index written before the clustered-scan tables existed migrates
    /// forward on open: stored vectors survive, every row starts unassigned,
    /// and search still works.
    func testIndexMigratesV13ArchiveToCurrentSchema() throws {
        let indexURL = archiveURL.appendingPathComponent(ArchiveStore.indexName)
        let pool = try DatabasePool(path: indexURL.path)
        try IndexSchema.migrator(through: "core-v13").migrate(pool)
        try pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO message (hash, size, subject, normalizedSubject, dateSent, messageID, fromEmail)
                VALUES (x'01020304', 12, 'Old subject', 'old subject',
                        '2024-03-05T14:23:01Z', '<old@example.com>', 'alice@example.com')
                """
            )
            try db.execute(
                sql: """
                INSERT INTO message (hash, size, subject, normalizedSubject, dateSent, messageID, fromEmail)
                VALUES (x'05060708', 12, 'Older subject', 'older subject',
                        '2024-03-05T14:23:02Z', '<older@example.com>', 'alice@example.com')
                """
            )
            try db.execute(
                sql: "INSERT INTO message_embedding (id, model, dim, vector) VALUES (1, 'm', 4, ?)",
                arguments: [VectorIndex.encode([1, 0, 0, 0])]
            )
            try db.execute(
                sql: "INSERT INTO message_embedding (id, model, dim, vector) VALUES (2, 'm', 4, ?)",
                arguments: [VectorIndex.encode([0, 1, 0, 0])]
            )
        }

        let store = try ArchiveStore.open(at: archiveURL)
        let migrated = try store.db.read { db in
            try VectorIndex.search(db, model: "m", query: [1, 0, 0, 0], limit: 10)
        }
        XCTAssertEqual(migrated.map(\.messageID), [1, 2])
        let unassigned = try store.db.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM message_embedding WHERE cluster IS NULL"
            )
        }
        XCTAssertEqual(unassigned, 2, "migrated rows start unassigned, not in a stale cluster")
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

    /// Two models coexist: writing vectors under a second model must never
    /// touch the first model's rows (core-v13 regression — under core-v12
    /// the id-alone primary key let a second model overwrite the first).
    func testSecondModelCoexistsWithTheFirst() throws {
        let store = try ArchiveStore.open(at: archiveURL)
        let ids = try ingest(store, count: 2)
        try store.db.write { db in
            try VectorIndex.upsert(db, messageID: ids[0], model: "m", vector: [1, 0, 0, 0])
            try VectorIndex.upsert(db, messageID: ids[0], model: "other", vector: [0, 1, 0, 0])
            try VectorIndex.upsert(db, messageID: ids[1], model: "other", vector: [1, 0, 0, 0])
        }
        let modelRows = try store.db.read { db in
            try VectorIndex.search(db, model: "m", query: [1, 0, 0, 0], limit: 10)
        }
        let otherRows = try store.db.read { db in
            try VectorIndex.search(db, model: "other", query: [1, 0, 0, 0], limit: 10)
        }
        XCTAssertEqual(modelRows.map(\.messageID), [ids[0]])
        XCTAssertEqual(otherRows.map(\.messageID), [ids[1], ids[0]])
    }

    /// A core-v12 index (embedding rows keyed by id alone) migrates forward
    /// on open with its rows intact, and the migrated table keeps models
    /// separate.
    func testIndexMigratesV12ArchiveToCurrentSchema() throws {
        let indexURL = archiveURL.appendingPathComponent(ArchiveStore.indexName)
        let pool = try DatabasePool(path: indexURL.path)
        try IndexSchema.migrator(through: "core-v12").migrate(pool)
        try pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO message (hash, size, subject, normalizedSubject, dateSent, messageID, fromEmail)
                VALUES (x'01020304', 12, 'Old subject', 'old subject',
                        '2024-03-05T14:23:01Z', '<old@example.com>', 'alice@example.com')
                """
            )
            try db.execute(
                sql: """
                INSERT INTO message (hash, size, subject, normalizedSubject, dateSent, messageID, fromEmail)
                VALUES (x'05060708', 12, 'Older subject', 'older subject',
                        '2024-03-05T14:23:02Z', '<older@example.com>', 'alice@example.com')
                """
            )
            try db.execute(
                sql: "INSERT INTO message_embedding (id, model, dim, vector) VALUES (1, 'm', 4, ?)",
                arguments: [VectorIndex.encode([1, 0, 0, 0])]
            )
            try db.execute(
                sql: "INSERT INTO message_embedding (id, model, dim, vector) VALUES (2, 'm', 4, ?)",
                arguments: [VectorIndex.encode([0, 1, 0, 0])]
            )
        }

        let store = try ArchiveStore.open(at: archiveURL)
        try store.db.write { db in
            try VectorIndex.upsert(db, messageID: 1, model: "other", vector: [0, 0, 1, 0])
        }
        let migrated = try store.db.read { db in
            try VectorIndex.search(db, model: "m", query: [1, 0, 0, 0], limit: 10)
        }
        let added = try store.db.read { db in
            try VectorIndex.search(db, model: "other", query: [0, 0, 1, 0], limit: 10)
        }
        XCTAssertEqual(migrated.map(\.messageID), [1, 2])
        XCTAssertEqual(added.map(\.messageID), [1])
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
