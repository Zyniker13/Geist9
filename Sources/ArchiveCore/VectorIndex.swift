// The semantic-search vector index (decision 0045). One float16 vector per
// message lives in the `message_embedding` table (core-v12); the row id is
// the message id, so deleting a message cascades its embedding. Search is a
// full cosine scan — scalar and deterministic on every platform for this
// slice; the Accelerate path lands with the scale-measurement slice. The
// embedding model itself (decision 0009: bge-small-en-v1.5 through Core ML)
// is a later slice; until it writes rows, search returns empty.

import Foundation
import GRDB

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

    /// Nearest messages by cosine similarity, best first, ties by ascending
    /// message id. Rows of other models, unreadable vectors, and all-zero
    /// vectors are skipped. A query whose dimension disagrees with the
    /// model's stored dimension throws.
    public static func search(
        _ db: Database, model: String, query: [Float], limit: Int
    ) throws -> [VectorHit] {
        guard limit > 0 else { return [] }
        if let storedDim = try Int.fetchOne(
            db,
            sql: "SELECT dim FROM message_embedding WHERE model = ? LIMIT 1",
            arguments: [model]
        ), storedDim != query.count {
            throw VectorIndexError.dimensionMismatch(expected: storedDim, got: query.count)
        }
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT id, vector FROM message_embedding WHERE model = ?",
            arguments: [model]
        )
        var hits: [VectorHit] = []
        hits.reserveCapacity(rows.count)
        for row in rows {
            let id: Int64 = row["id"]
            let blob: Data = row["vector"]
            guard let vector = decode(blob, dimension: query.count),
                  let score = cosine(query, vector) else { continue }
            hits.append(VectorHit(messageID: id, score: score))
        }
        hits.sort { a, b in
            a.score == b.score ? a.messageID < b.messageID : a.score > b.score
        }
        if hits.count > limit { hits.removeLast(hits.count - limit) }
        return hits
    }
}
