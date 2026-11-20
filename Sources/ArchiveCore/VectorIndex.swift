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
            INSERT INTO message_embedding (id, model, dim, vector)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(id, model) DO UPDATE SET
                dim = excluded.dim, vector = excluded.vector
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
    /// The scan runs in id-ordered batches: each batch is decoded and scored
    /// in one vectorized pass where Accelerate is available (Apple silicon),
    /// with the same per-row scalar math elsewhere. Only the best `limit`
    /// hits survive each pass, so memory stays bounded, and ties resolve
    /// exactly as the previous full-sort scan did.
    public static func search(
        _ db: Database, model: String, query: [Float], limit: Int,
        batchSize: Int = VectorIndex.scanBatchSize
    ) throws -> [VectorHit] {
        guard limit > 0 else { return [] }
        if let storedDim = try Int.fetchOne(
            db,
            sql: "SELECT dim FROM message_embedding WHERE model = ? LIMIT 1",
            arguments: [model]
        ), storedDim != query.count {
            throw VectorIndexError.dimensionMismatch(expected: storedDim, got: query.count)
        }
        var lastID: Int64 = 0
        var keeper = TopKeeper(limit: limit)
        while true {
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, vector FROM message_embedding
                WHERE model = ? AND id > ? ORDER BY id LIMIT ?
                """,
                arguments: [model, lastID, batchSize]
            )
            if rows.isEmpty { break }
            let last: Int64 = rows[rows.count - 1]["id"]
            lastID = last
            let batch: [(id: Int64, blob: Data)] = rows.map { row in
                let id: Int64 = row["id"]
                let blob: Data = row["vector"]
                return (id, blob)
            }
            score(batch, query: query, into: &keeper)
        }
        return keeper.best()
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
                blob.withUnsafeBytes { src in
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
                var ones = [Float](repeating: 1, count: dim)
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
