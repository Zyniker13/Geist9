// The semantic-search vector index (decision 0045). One float16 vector per
// message lives in the `message_embedding` table (core-v13); the row id is
// the message id, so deleting a message cascades its embedding. Search is a
// chunked full cosine scan: id-ordered batches, scored with Accelerate on
// Apple silicon (vImage binary16 expand + two GEMVs per batch) and the
// identical scalar math elsewhere, keeping only the best `limit` hits.
// Results agree across platforms to float rounding.

import Foundation
import GRDB

#if canImport(Accelerate) && arch(arm64)
import Accelerate
#endif

/// One semantic-search hit: the message row id and its cosine similarity to
/// the query vector, in [−1, 1].
public struct VectorHit: Equatable, Sendable {
    public let messageID: Int64
    public let score: Float

    public init(messageID: Int64, score: Float) {
        self.messageID = messageID
        self.score = score
    }
}

public enum VectorIndexError: Error, Equatable {
    /// A vector's dimension count disagrees with the dimension already
    /// stored for its model (one dimension per model keeps every query's
    /// comparison well-defined).
    case dimensionMismatch(expected: Int, got: Int)
    /// An empty vector carries no direction; storing one would make every
    /// cosine undefined.
    case emptyVector
}

public enum VectorIndex {
    // MARK: - IEEE binary16 codec (round-to-nearest-even on encode, exact
    // on decode; no reliance on a platform `Float16`)

    /// Encode a float32 vector as little-endian binary16 (2 bytes per
    /// dimension).
    public static func encode(_ vector: [Float]) -> Data {
        var data = Data(capacity: vector.count * 2)
        for value in vector {
            var bits = UInt16(truncatingIfNeeded: halfBits(of: value)).littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Decode a binary16 BLOB of exactly `dimension` elements. Returns nil
    /// when the byte count does not match.
    public static func decode(_ data: Data, dimension: Int) -> [Float]? {
        guard dimension >= 0, data.count == dimension * 2 else { return nil }
        var vector = [Float](repeating: 0, count: dimension)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<dimension {
                let low = UInt32(raw[i * 2])
                let high = UInt32(raw[i * 2 + 1])
                vector[i] = float(ofHalfBits: (high << 8) | low)
            }
        }
        return vector
    }

    /// Float32 → binary16 bits, round-to-nearest-even, ties to even.
    static func halfBits(of value: Float) -> UInt32 {
        let bits = value.bitPattern
        let sign = (bits >> 16) & 0x8000
        let biased = (bits >> 23) & 0xFF
        let fraction = bits & 0x007F_FFFF

        // Infinity and NaN pass through (NaN payload truncated to the quiet
        // bit so the result stays a NaN).
        if biased == 0xFF {
            if fraction == 0 { return sign | 0x7C00 }
            return sign | 0x7E00
        }

        var exponent = Int(biased) - 127 + 15

        // Overflow to infinity (round-to-nearest-even boundary honoured by
        // the mantissa rounding below).
        if exponent >= 31 { return sign | 0x7C00 }

        // Underflow to subnormal or zero: keep the hidden bit and shift with
        // round-to-nearest-even. The carry out of the subnormal mantissa
        // lands in the exponent, which is exactly the smallest-normal step.
        if exponent <= 0 {
            if exponent < -10 { return sign }
            let mantissa = fraction | 0x0080_0000
            let shift = UInt32(14 - exponent)
            var half = mantissa >> shift
            let remainder = mantissa & ((1 << shift) - 1)
            let halfUlp = 1 << (shift - 1)
            if remainder > halfUlp || (remainder == halfUlp && half & 1 == 1) {
                half += 1
            }
            return sign | half
        }

        // Normal: round the 23-bit fraction to 10 bits.
        var mantissa = fraction >> 13
        let remainder = fraction & 0x1FFF
        if remainder > 0x1000 || (remainder == 0x1000 && mantissa & 1 == 1) {
            mantissa += 1
            if mantissa == 0x400 {
                mantissa = 0
                exponent += 1
                if exponent >= 31 { return sign | 0x7C00 }
            }
        }
        return sign | (UInt32(exponent) << 10) | mantissa
    }

    /// Binary16 bits → float32, exact.
    static func float(ofHalfBits bits: UInt32) -> Float {
        let sign = (bits & 0x8000) << 16
        let exponent = (bits >> 10) & 0x1F
        let fraction = bits & 0x03FF

        if exponent == 0 {
            // Zero or subnormal: value = ±fraction × 2^−24, exact in float32.
            if fraction == 0 { return Float(bitPattern: sign) }
            let magnitude = Float(fraction) * 0x1p-24
            return sign == 0 ? magnitude : -magnitude
        }
        if exponent == 0x1F {
            if fraction == 0 { return Float(bitPattern: sign | 0x7F80_0000) }
            // Quiet NaN with the payload shifted into float32 position.
            return Float(bitPattern: sign | 0x7F80_0000 | (fraction << 13) | 0x0040_0000)
        }
        return Float(bitPattern: sign | ((exponent + 112) << 23) | (fraction << 13))
    }

    // MARK: - Similarity

    /// Cosine similarity; nil when the dimensions differ or either vector
    /// has no direction (all zeros).
    public static func cosine(_ a: [Float], _ b: [Float]) -> Float? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        if normA == 0 || normB == 0 { return nil }
        return dot / (normA * normB).squareRoot()
    }

    // MARK: - Store-backed index

    /// Store or replace the embedding for one message.
    public static func upsert(
        _ db: Database, messageID: Int64, model: String, vector: [Float]
    ) throws {
        if vector.isEmpty { throw VectorIndexError.emptyVector }
        if let existing = try Int.fetchOne(
            db,
            sql: "SELECT dim FROM message_embedding WHERE model = ? LIMIT 1",
            arguments: [model]
        ), existing != vector.count {
            throw VectorIndexError.dimensionMismatch(expected: existing, got: vector.count)
        }
        try db.execute(
            sql: """
            INSERT INTO message_embedding (id, model, dim, vector, cluster)
            VALUES (?, ?, ?, ?, NULL)
            ON CONFLICT(id, model) DO UPDATE SET
                dim = excluded.dim, vector = excluded.vector, cluster = NULL
            """,
            arguments: [messageID, model, vector.count, encode(vector)]
        )
    }

    /// Remove the embedding for one message (also happens implicitly when
    /// the message row is deleted).
    public static func remove(_ db: Database, messageID: Int64) throws {
        try db.execute(
            sql: "DELETE FROM message_embedding WHERE id = ?", arguments: [messageID]
        )
    }

    /// Number of rows fetched and scored per pass of the scan. Bounded
    /// batches keep the scan's memory independent of archive size.
    public static let scanBatchSize = 4096

    /// Nearest messages by cosine similarity, best first, ties by ascending
    /// message id. Rows of other models, unreadable vectors, and all-zero
    /// vectors are skipped. A query whose dimension disagrees with the
    /// model's stored dimension throws.
    ///
    /// With no centroids for the model (or `nprobe` nil/0) the scan is
    /// exact: every stored vector for the model is read and scored. With
    /// centroids (decision 0046) the query is first scored against each
    /// centroid with the scalar cosine, and only the `nprobe` best clusters
    /// plus every yet-unassigned row are scanned — scores for the rows
    /// actually scored stay exact, so the result is approximate only in
    /// which rows are considered.
    ///
    /// The scan runs in id-ordered batches: each batch is decoded and scored
    /// in one vectorized pass where Accelerate is available (Apple silicon),
    /// with the same per-row scalar math elsewhere. Only the best `limit`
    /// hits survive each pass, so memory stays bounded, and ties resolve
    /// exactly as the previous full-sort scan did.
    public static func search(
        _ db: Database, model: String, query: [Float], limit: Int,
        batchSize: Int = VectorIndex.scanBatchSize,
        nprobe: Int? = VectorIndex.defaultProbeCount
    ) throws -> [VectorHit] {
        guard limit > 0 else { return [] }
        if let storedDim = try Int.fetchOne(
            db,
            sql: "SELECT dim FROM message_embedding WHERE model = ? LIMIT 1",
            arguments: [model]
        ), storedDim != query.count {
            throw VectorIndexError.dimensionMismatch(expected: storedDim, got: query.count)
        }
        var keeper = TopKeeper(limit: limit)
        let clusters = try VectorIndex.clusters(db, model: model)
        if let nprobe, nprobe > 0, !clusters.isEmpty {
            try scanClusters(
                db, model: model, query: query, clusters: clusters, nprobe: nprobe,
                into: &keeper, batchSize: batchSize
            )
        } else {
            var lastID: Int64 = 0
            try scan(db, model: model, query: query, lastID: &lastID, into: &keeper,
                     batchSize: batchSize, scope: .all)
        }
        return keeper.best()
    }

    /// Which rows a batched scan considers: every row of the model, the rows
    /// assigned to one cluster, or the rows not yet assigned to any cluster.
    enum ScanScope {
        case all
        case assigned(Int)
        case unassigned

        var clause: String {
            switch self {
            case .all: return "WHERE model = ? AND id > ?"
            case .assigned: return "WHERE model = ? AND id > ? AND cluster = ?"
            case .unassigned: return "WHERE model = ? AND id > ? AND cluster IS NULL"
            }
        }
    }

    /// Streams one scan scope in id-ordered batches into the shared keeper.
    static func scan(
        _ db: Database, model: String, query: [Float], lastID: inout Int64,
        into keeper: inout TopKeeper, batchSize: Int, scope: ScanScope
    ) throws {
        while true {
            // Rebuilt every iteration: lastID advances between batches. A
            // snapshot taken outside the loop carried a stale id and
            // re-fetched the first batch forever (regression covered by
            // testScanOrderUnaffectedByBatchSize, which forces 13 batches).
            var arguments: [DatabaseValue] = [model.databaseValue, lastID.databaseValue]
            if case .assigned(let cluster) = scope { arguments.append(cluster.databaseValue) }
            var batch: [(id: Int64, blob: Data)] = []
            batch.reserveCapacity(batchSize)
            let cursor = try Row.fetchCursor(
                db,
                sql: """
                SELECT id, vector FROM message_embedding
                \(scope.clause) ORDER BY id LIMIT ?
                """,
                arguments: StatementArguments(arguments + [batchSize.databaseValue])
            )
            while let row = try cursor.next() {
                let id: Int64 = row[0]
                let blob: Data = row[1]
                batch.append((id, blob))
            }
            if batch.isEmpty { break }
            lastID = batch[batch.count - 1].id
            score(batch, query: query, into: &keeper)
        }
    }

    /// The clustered path: scores the query against each centroid, probes
    /// the `nprobe` best clusters plus the unassigned rows, and keeps one
    /// shared keeper across every probed scan so ordering and ties stay
    /// exactly the flat scan's.
    static func scanClusters(
        _ db: Database, model: String, query: [Float], clusters: [VectorCluster],
        nprobe: Int, into keeper: inout TopKeeper, batchSize: Int
    ) throws {
        let ranked = clusters.enumerated().map { (index: $0.offset, cluster: $0.element) }
            .compactMap { entry -> (index: Int, score: Float)? in
                guard let score = cosine(query, entry.cluster.centroid) else { return nil }
                return (entry.index, score)
            }
            .sorted { a, b in
                a.score == b.score ? a.index < b.index : a.score > b.score
            }
            .prefix(max(1, min(nprobe, clusters.count)))
        for entry in ranked {
            var lastID: Int64 = 0
            try scan(db, model: model, query: query, lastID: &lastID, into: &keeper,
                     batchSize: batchSize, scope: .assigned(clusters[entry.index].index))
        }
        var lastID: Int64 = 0
        try scan(db, model: model, query: query, lastID: &lastID, into: &keeper,
                 batchSize: batchSize, scope: .unassigned)
    }

    // MARK: - Batch scoring

    /// Scores one fetched batch against the query and offers the survivors
    /// to the keeper. On Apple silicon the decode and the products run
    /// through Accelerate; elsewhere the identical math runs per row. The
    /// two paths agree to float rounding (see the agreement test).
    static func score(
        _ batch: [(id: Int64, blob: Data)], query: [Float], into keeper: inout TopKeeper
    ) {
        #if canImport(Accelerate) && arch(arm64)
        accelerateScore(batch, query: query, into: &keeper)
        #else
        scalarScore(batch, query: query, into: &keeper)
        #endif
    }

    /// The scalar reference path: the same per-row decode and cosine the
    /// scan used before it was vectorized.
    static func scalarScore(
        _ batch: [(id: Int64, blob: Data)], query: [Float], into keeper: inout TopKeeper
    ) {
        for row in batch {
            guard let vector = decode(row.blob, dimension: query.count),
                  let score = cosine(query, vector) else { continue }
            keeper.offer(VectorHit(messageID: row.id, score: score))
        }
    }

    #if canImport(Accelerate) && arch(arm64)
    /// Vectorized batch scoring. The blobs are little-endian binary16 and
    /// Apple silicon is little-endian, so the raw bytes are copied as-is;
    /// one vImage call expands the whole batch to float32, and two GEMVs
    /// then produce the dot products and the row norms in bulk. Unreadable
    /// blobs and all-zero vectors fall out naturally: their row stays zero
    /// and a zero norm is skipped, matching the scalar path.
    static func accelerateScore(
        _ batch: [(id: Int64, blob: Data)], query: [Float], into keeper: inout TopKeeper
    ) {
        let dim = query.count
        guard dim > 0 else { return }
        var normQuery: Float = 0
        for q in query { normQuery += q * q }
        if normQuery == 0 { return }
        let n = batch.count

        // One contiguous half buffer for the whole batch. Rows whose blob
        // size disagrees with the model dimension stay zero and are skipped
        // below, exactly like the scalar path skips them.
        var halves = [UInt16](repeating: 0, count: n * dim)
        var readable = [Bool](repeating: false, count: n)
        halves.withUnsafeMutableBytes { hRaw in
            let dst = hRaw.baseAddress!.assumingMemoryBound(to: UInt16.self)
            for i in 0..<n {
                let blob = batch[i].blob
                guard blob.count == dim * 2 else { continue }
                readable[i] = true
                _ = blob.withUnsafeBytes { src in
                    memcpy(dst + i * dim, src.baseAddress, dim * 2)
                }
            }
        }

        // One bulk pass expands the whole batch from little-endian binary16
        // to float32 (Apple silicon is little-endian, so the raw bytes are
        // copied as-is).
        var flat = [Float](repeating: 0, count: n * dim)
        halves.withUnsafeMutableBytes { hBuf in
            flat.withUnsafeMutableBytes { fBuf in
                var source = vImage_Buffer(
                    data: hBuf.baseAddress, height: 1,
                    width: vImagePixelCount(n * dim), rowBytes: n * dim * 2
                )
                var destination = vImage_Buffer(
                    data: fBuf.baseAddress, height: 1,
                    width: vImagePixelCount(n * dim), rowBytes: n * dim * 4
                )
                vImageConvert_Planar16FtoPlanarF(&source, &destination, vImage_Flags(kvImageDoNotTile))
            }
        }

        // dots[i] = query · row[i]: vDSP_mmul reads row-major, so the GEMV
        // runs as flat (n × dim) times query (dim × 1) into dots (n × 1).
        var dots = [Float](repeating: 0, count: n)
        dots.withUnsafeMutableBufferPointer { dotsPtr in
            flat.withUnsafeBufferPointer { flatPtr in
                query.withUnsafeBufferPointer { queryPtr in
                    vDSP_mmul(
                        flatPtr.baseAddress!, 1,
                        queryPtr.baseAddress!, 1,
                        dotsPtr.baseAddress!, 1,
                        vDSP_Length(n), 1, vDSP_Length(dim)
                    )
                }
            }
        }

        // norms[i] = |row[i]|² via a second GEMV over the squared matrix.
        var squared = [Float](repeating: 0, count: n * dim)
        squared.withUnsafeMutableBufferPointer { sqPtr in
            flat.withUnsafeBufferPointer { flatPtr in
                vDSP_vsq(flatPtr.baseAddress!, 1, sqPtr.baseAddress!, 1, vDSP_Length(n * dim))
            }
        }
        var norms = [Float](repeating: 0, count: n)
        norms.withUnsafeMutableBufferPointer { normsPtr in
            squared.withUnsafeBufferPointer { sqPtr in
                let ones = [Float](repeating: 1, count: dim)
                ones.withUnsafeBufferPointer { onesPtr in
                    vDSP_mmul(
                        sqPtr.baseAddress!, 1,
                        onesPtr.baseAddress!, 1,
                        normsPtr.baseAddress!, 1,
                        vDSP_Length(n), 1, vDSP_Length(dim)
                    )
                }
            }
        }

        for i in 0..<n where readable[i] {
            let norm = norms[i]
            if norm == 0 { continue }
            let score = dots[i] / (normQuery * norm).squareRoot()
            keeper.offer(VectorHit(messageID: batch[i].id, score: score))
        }
    }
    #endif

    // MARK: - Clustering (decision 0046)

    /// Rows aimed at per cluster when the trainer picks the cluster count.
    public static let clusterTargetSize = 768
    /// Upper bound on clusters per model: enough for ~1M rows at ~1k each,
    /// and small enough that scoring every centroid stays trivial.
    public static let clusterMaxCount = 1024
    /// Rows sampled for k-means training; more only slow the build without
    /// moving centroids much at this scale.
    public static let clusterSampleSize = 65_536
    /// Lloyd iterations per clustering run.
    public static let clusterIterations = 16
    /// Clusters probed per query by default (decision 0046). The operating
    /// point is confirmed by bench-search vector-recall (STATUS).
    public static let defaultProbeCount = 16
    /// Rows a model needs before clustering pays off; below this the exact
    /// scan is fast enough and stays exact.
    public static let clusterMinRows = 65_536
    /// Rebuild when at least this many percent of rows have no assignment
    /// (fresh or rewritten vectors), or when no clusters exist yet.
    public static let clusterStalePercent = 10
    /// Rows fetched per batch while assigning every row to its centroid.
    static let assignBatchSize = 8_192

    /// One stored centroid: its 0-based index, its coordinates decoded to
    /// float32 (the stored form is float16, same as the vectors), and the
    /// number of rows assigned to it.
    public struct VectorCluster: Equatable, Sendable {
        public let index: Int
        public let centroid: [Float]
        public let count: Int
    }

    /// The stored centroids for a model, ordered by cluster index, or an
    /// empty array when the model is not clustered. Centroid blobs whose
    /// size does not decode cleanly are skipped.
    public static func clusters(_ db: Database, model: String) throws -> [VectorCluster] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT cluster, centroid, count FROM embedding_cluster
            WHERE model = ? ORDER BY cluster
            """,
            arguments: [model]
        )
        return rows.compactMap { row in
            let index: Int = row[0]
            let blob: Data = row[1]
            let count: Int = row[2]
            guard blob.count % 2 == 0, blob.count > 0,
                  let centroid = decode(blob, dimension: blob.count / 2)
            else { return nil }
            return VectorCluster(index: index, centroid: centroid, count: count)
        }
    }

    /// Clusters a model's vectors when there are enough rows and enough
    /// stale assignments (decision 0046): no centroids yet, or at least
    /// `clusterStalePercent` of the rows unassigned. Returns the cluster
    /// count, zero when clustering was skipped or the model has no rows.
    @discardableResult
    public static func maybeCluster(_ db: Database, model: String, seed: UInt64 = 0) throws -> Int {
        let rows = try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM message_embedding WHERE model = ?",
            arguments: [model]
        ) ?? 0
        guard rows > 0 else { return 0 }
        let existing = try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM embedding_cluster WHERE model = ?",
            arguments: [model]
        ) ?? 0
        if existing > 0 {
            let unassigned = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM message_embedding WHERE model = ? AND cluster IS NULL",
                arguments: [model]
            ) ?? 0
            guard unassigned * 100 >= rows * clusterStalePercent else { return 0 }
        } else {
            // Auto-clustering only pays for itself at scale; below the
            // threshold the exact scan stays (decision 0046). Explicit
            // buildClusters calls are not gated: tests and tooling may
            // cluster small sets.
            guard rows >= clusterMinRows else { return 0 }
        }
        return try buildClusters(db, model: model, seed: seed)
    }

    /// Trains k-means on a stride sample of the model's vectors, rounds the
    /// centroids to the stored float16 precision, reassigns every row to its
    /// nearest rounded centroid, and replaces the model's stored centroids —
    /// all inside the caller's transaction. Deterministic for a given
    /// archive and seed. Returns the cluster count (0 when there is nothing
    /// to cluster, which also clears any stale centroids).
    @discardableResult
    public static func buildClusters(
        _ db: Database, model: String,
        clusterCount: Int? = nil,
        sampleSize: Int = clusterSampleSize,
        iterations: Int = clusterIterations,
        seed: UInt64 = 0
    ) throws -> Int {
        let rows = try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM message_embedding WHERE model = ?",
            arguments: [model]
        ) ?? 0
        let storedDim = try Int.fetchOne(
            db, sql: "SELECT dim FROM message_embedding WHERE model = ? LIMIT 1",
            arguments: [model]
        )
        guard rows > 0, let dim = storedDim else {
            try db.execute(
                sql: "DELETE FROM embedding_cluster WHERE model = ?", arguments: [model]
            )
            return 0
        }
        var k = clusterCount ?? min(clusterMaxCount, max(1, rows / clusterTargetSize))
        k = min(k, max(1, rows))

        // Stride sampling: the rowid predicate keeps the scan cheap and the
        // sample deterministic. Rounded up so the sample never exceeds the
        // requested size by much.
        let stride = max(1, (rows + max(1, sampleSize) - 1) / max(1, sampleSize))
        let sampleRows = try Row.fetchAll(
            db,
            sql: "SELECT vector FROM message_embedding WHERE model = ? AND id % ? = 0",
            arguments: [model, stride]
        )
        var flat: [Float] = []
        flat.reserveCapacity(min(sampleRows.count, sampleSize) * dim)
        var sampleCount = 0
        for row in sampleRows {
            let blob: Data = row[0]
            if let vector = decode(blob, dimension: dim) {
                flat.append(contentsOf: vector)
                sampleCount += 1
            }
        }
        guard sampleCount > 0 else {
            try db.execute(
                sql: "DELETE FROM embedding_cluster WHERE model = ?", arguments: [model]
            )
            return 0
        }
        k = min(k, max(1, sampleCount))

        var centroids = kMeans(
            flat: flat, count: sampleCount, dim: dim, clusters: k,
            iterations: iterations, seed: seed
        )
        // Assign against the centroids exactly as search will see them:
        // float16-rounded, not the full float32 trainer output.
        centroids = centroids.map { centroid in
            decode(encode(centroid), dimension: dim) ?? centroid
        }

        // A rebuild starts clean: stale assignments would otherwise survive
        // for rows whose blob no longer decodes.
        try db.execute(
            sql: "UPDATE message_embedding SET cluster = NULL WHERE model = ?",
            arguments: [model]
        )
        var counts = [Int](repeating: 0, count: centroids.count)
        try assignRows(
            db, model: model, dim: dim, centroids: centroids, counts: &counts
        )

        try db.execute(
            sql: "DELETE FROM embedding_cluster WHERE model = ?", arguments: [model]
        )
        for (index, centroid) in centroids.enumerated() {
            try db.execute(
                sql: """
                INSERT INTO embedding_cluster (model, cluster, centroid, count)
                VALUES (?, ?, ?, ?)
                """,
                arguments: [model, index, encode(centroid), counts[index]]
            )
        }
        return centroids.count
    }

    /// Lloyd's k-means with k-means++ seeding over a flat row-major sample.
    /// Nearest-centroid assignment runs the vectorized GEMM where
    /// Accelerate is available and the identical scalar math elsewhere;
    /// rounding differences between the two are float noise (the agreement
    /// test pins the dot products, not boundary-row assignments).
    static func kMeans(
        flat: [Float], count: Int, dim: Int, clusters: Int,
        iterations: Int, seed: UInt64
    ) -> [[Float]] {
        var rng = SeededGenerator(seed: seed)
        var centroids = kMeansPlusPlus(
            flat: flat, count: count, dim: dim, clusters: clusters, rng: &rng
        )
        var assignment = [Int](repeating: 0, count: count)
        for _ in 0..<max(1, iterations) {
            assignment = nearestCentroids(
                flat: flat, count: count, dim: dim, centroids: centroids
            )
            var sums = [[Float]](
                repeating: [Float](repeating: 0, count: dim), count: centroids.count
            )
            var counts = [Int](repeating: 0, count: centroids.count)
            for i in 0..<count {
                let target = assignment[i]
                counts[target] += 1
                let base = i * dim
                var row = sums[target]
                for d in 0..<dim { row[d] += flat[base + d] }
                sums[target] = row
            }
            for c in 0..<centroids.count {
                if counts[c] == 0 {
                    // Reseed an empty cluster to the sample point farthest
                    // from its current centroid; ties pick the lowest row.
                    var far = 0
                    var farDistance: Float = -1
                    for i in 0..<count {
                        let distance = squaredDistance(
                            flat, row: i, dim: dim, to: centroids[assignment[i]]
                        )
                        if distance > farDistance {
                            farDistance = distance
                            far = i
                        }
                    }
                    centroids[c] = Array(flat[far * dim..<(far + 1) * dim])
                    counts[assignment[far]] -= 1
                    counts[c] += 1
                    assignment[far] = c
                } else {
                    let n = Float(counts[c])
                    centroids[c] = sums[c].map { $0 / n }
                }
            }
        }
        return centroids
    }

    /// k-means++ seeding: each next centroid is drawn with probability
    /// proportional to its squared distance from the nearest chosen one.
    static func kMeansPlusPlus(
        flat: [Float], count: Int, dim: Int, clusters: Int,
        rng: inout SeededGenerator
    ) -> [[Float]] {
        var chosen: [[Float]] = []
        chosen.reserveCapacity(clusters)
        var minD2 = [Float](repeating: .infinity, count: count)
        var norms = [Float](repeating: 0, count: count)
        for i in 0..<count {
            var sum: Float = 0
            let base = i * dim
            for d in 0..<dim { let v = flat[base + d]; sum += v * v }
            norms[i] = sum
        }
        for step in 0..<clusters {
            let index: Int
            if step == 0 {
                index = Int(rng.next() % UInt64(count))
            } else {
                let total = minD2.reduce(0, +)
                if total <= 0 {
                    index = Int(rng.next() % UInt64(count))
                } else {
                    var threshold = Float(Double(rng.next() &>> 11) * 0x1p-53) * total
                    var walk = 0
                    while walk < count - 1 {
                        threshold -= minD2[walk]
                        if threshold <= 0 { break }
                        walk += 1
                    }
                    index = walk
                }
            }
            let base = index * dim
            chosen.append(Array(flat[base..<(base + dim)]))
            let centroidLength = squaredLength(chosen[step])
            for i in 0..<count {
                let d2 = norms[i] - 2 * dot(flat, at: i, dim: dim, with: chosen[step])
                    + centroidLength
                if d2 < minD2[i] { minD2[i] = d2 }
            }
        }
        return chosen
    }

    /// Nearest centroid per sample row, by cosine — parallel to the scan:
    /// the dot with each centroid divided by its length (the row's own
    /// length is constant per row). Batched through the GEMM where
    /// Accelerate is available, identical scalar math elsewhere.
    static func nearestCentroids(
        flat: [Float], count: Int, dim: Int, centroids: [[Float]],
        batchSize: Int = 8_192, useAccelerate: Bool = true
    ) -> [Int] {
        let k = centroids.count
        var norms = [Float](repeating: 0, count: k)
        for c in 0..<k { norms[c] = squaredLength(centroids[c]).squareRoot() }
        // Centroids transposed to (dim × k) for the GEMM layout.
        var transposed = [Float](repeating: 0, count: dim * k)
        for c in 0..<k {
            for d in 0..<dim { transposed[d * k + c] = centroids[c][d] }
        }
        var result = [Int](repeating: 0, count: count)
        var scratch = [Float](repeating: 0, count: min(batchSize, max(1, count)) * k)
        var start = 0
        while start < count {
            let rows = min(batchSize, count - start)
            scratch.withUnsafeMutableBufferPointer { scratchBuffer in
                transposed.withUnsafeBufferPointer { b in
                    flat.withUnsafeBufferPointer { a in
                        let aBase = a.baseAddress! + start * dim
                        #if canImport(Accelerate) && arch(arm64)
                        if useAccelerate {
                            // vDSP strides multiply the element index
                            // (A[m][p] = A[(m*P+p)*IA], per vDSP.h), so
                            // contiguous row-major inputs all use stride 1.
                            vDSP_mmul(
                                aBase, 1, b.baseAddress!, 1,
                                scratchBuffer.baseAddress!, 1,
                                vDSP_Length(rows), vDSP_Length(k), vDSP_Length(dim)
                            )
                        } else {
                            scalarGemm(aBase, b: b.baseAddress!, out: scratchBuffer.baseAddress!,
                                       rows: rows, dim: dim, k: k)
                        }
                        #else
                        scalarGemm(aBase, b: b.baseAddress!, out: scratchBuffer.baseAddress!,
                                   rows: rows, dim: dim, k: k)
                        #endif
                    }
                }
            }
            for r in 0..<rows {
                var best = 0
                var bestScore: Float = -.infinity
                for c in 0..<k where norms[c] > 0 {
                    let score = scratch[r * k + c] / norms[c]
                    if score > bestScore { bestScore = score; best = c }
                }
                result[start + r] = best
            }
            start += rows
        }
        return result
    }

    /// Assigns every stored vector of the model to its nearest centroid and
    /// records per-cluster counts. Rows whose blob no longer decodes keep
    /// the NULL assignment set by the caller's clearing step.
    static func assignRows(
        _ db: Database, model: String, dim: Int, centroids: [[Float]], counts: inout [Int]
    ) throws {
        let update = try db.cachedStatement(
            sql: "UPDATE message_embedding SET cluster = ? WHERE id = ?"
        )
        var lastID: Int64 = 0
        while true {
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, vector FROM message_embedding
                WHERE model = ? AND id > ? ORDER BY id LIMIT ?
                """,
                arguments: [model, lastID, assignBatchSize]
            )
            if rows.isEmpty { break }
            let lastRowID: Int64 = rows[rows.count - 1][0]
            lastID = lastRowID
            var flat: [Float] = []
            var ids: [Int64] = []
            flat.reserveCapacity(rows.count * dim)
            ids.reserveCapacity(rows.count)
            for row in rows {
                let blob: Data = row[1]
                if let vector = decode(blob, dimension: dim) {
                    flat.append(contentsOf: vector)
                    ids.append(row[0])
                }
            }
            guard !ids.isEmpty else { continue }
            let assignments = nearestCentroids(
                flat: flat, count: ids.count, dim: dim, centroids: centroids
            )
            for (position, id) in ids.enumerated() {
                try update.execute(arguments: [assignments[position], id])
                counts[assignments[position]] += 1
            }
        }
    }

    /// SplitMix64: a tiny deterministic generator. The clustering build
    /// needs reproducibility, not cryptographic strength.
    struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
        mutating func next() -> UInt64 {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Scalar dot-product GEMM over a (rows × dim) row-major block against
    /// a (dim × k) transposed centroid matrix — the exact math the
    /// Accelerate path must agree with (pinned by the trainer test).
    static func scalarGemm(
        _ a: UnsafePointer<Float>, b: UnsafePointer<Float>, out: UnsafeMutablePointer<Float>,
        rows: Int, dim: Int, k: Int
    ) {
        for r in 0..<rows {
            for c in 0..<k {
                var sum: Float = 0
                for d in 0..<dim { sum += a[r * dim + d] * b[d * k + c] }
                out[r * k + c] = sum
            }
        }
    }

    static func squaredLength(_ v: [Float]) -> Float {
        var sum: Float = 0
        for x in v { sum += x * x }
        return sum
    }

    /// Squared distance from sample row `row` of `flat` to `vector`.
    static func squaredDistance(
        _ flat: [Float], row: Int, dim: Int, to vector: [Float]
    ) -> Float {
        var sum: Float = 0
        let base = row * dim
        for d in 0..<dim {
            let diff = flat[base + d] - vector[d]
            sum += diff * diff
        }
        return sum
    }

    static func dot(_ flat: [Float], at row: Int, dim: Int, with vector: [Float]) -> Float {
        var sum: Float = 0
        let base = row * dim
        for d in 0..<dim { sum += flat[base + d] * vector[d] }
        return sum
    }

    /// Bounded best-first collector for the scan: keeps at most `limit`
    /// hits and evicts the worst, where worse means the lower score, or the
    /// larger message id at an equal score — so ties resolve exactly as the
    /// previous full-sort scan resolved them (smallest ids win).
    struct TopKeeper {
        private let limit: Int
        private var heap: [VectorHit] = []

        /// A min-heap under "worse": the root is the worst kept hit.
        init(limit: Int) { self.limit = limit }

        var count: Int { heap.count }

        mutating func offer(_ hit: VectorHit) {
            if limit <= 0 { return }
            if heap.count < limit {
                heap.append(hit)
                siftUp(heap.count - 1)
            } else if isWorse(heap[0], hit) {
                heap[0] = hit
                siftDown(0)
            }
        }

        /// The kept hits, best first, ties by ascending message id.
        func best() -> [VectorHit] {
            heap.sorted { a, b in
                a.score == b.score ? a.messageID < b.messageID : a.score > b.score
            }
        }

        private func isWorse(_ a: VectorHit, _ b: VectorHit) -> Bool {
            a.score != b.score ? a.score < b.score : a.messageID > b.messageID
        }

        private mutating func siftUp(_ start: Int) {
            var child = start
            while child > 0 {
                let parent = (child - 1) / 2
                guard isWorse(heap[child], heap[parent]) else { break }
                heap.swapAt(child, parent)
                child = parent
            }
        }

        private mutating func siftDown(_ start: Int) {
            var parent = start
            while true {
                let left = 2 * parent + 1
                let right = left + 1
                var worst = parent
                if left < heap.count, isWorse(heap[left], heap[worst]) { worst = left }
                if right < heap.count, isWorse(heap[right], heap[worst]) { worst = right }
                if worst == parent { return }
                heap.swapAt(parent, worst)
                parent = worst
            }
        }
    }
}
