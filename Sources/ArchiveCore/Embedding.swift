/// A text-embedding model (decision 0045): turns one string of text into
/// a fixed-dimension vector, or nil when the text cannot be embedded. The
/// identifier is the value stored in `message_embedding.model`; every
/// vector written under it must have exactly `dimension` components.
/// Models are Sendable and stateless per call: search embeds the query,
/// the backfill embeds message text, and neither mutates shared state.
public protocol EmbeddingModel: Sendable {
    var identifier: String { get }
    var dimension: Int { get }
    func embed(_ text: String) -> [Float]?
}

/// A deterministic, dependency-free embedding used for tests and dogfood
/// runs, never for shipped relevance (decision 0045): it maps text to a
/// pseudo-random unit vector, so unrelated texts get unrelated vectors —
/// it cannot stand in for real similarity. It exists so the hybrid path,
/// the backfill and the executor wiring run identically on every platform
/// ArchiveCore builds for, with no Core ML and no model file.
public struct DeterministicEmbedding: EmbeddingModel {
    public let identifier: String
    public let dimension: Int

    public init(identifier: String = "deterministic-v1", dimension: Int = 4) {
        self.identifier = identifier
        self.dimension = dimension
    }

    /// FNV-1a over the text's UTF-8 bytes seeds a splitmix64 stream whose
    /// outputs become one component each, L2-normalized. Integer-only, so
    /// the same text yields the same vector on every platform.
    public func embed(_ text: String) -> [Float]? {
        var state: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            state = (state ^ UInt64(byte)) &* 0x100000001b3
        }
        if state == 0 { state = 0x9e3779b97f4a7c15 }
        var vector = [Float]()
        vector.reserveCapacity(dimension)
        for _ in 0..<dimension {
            state &+= 0x9e3779b97f4a7c15
            var z = state
            z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
            z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
            z ^= z >> 31
            let bits = UInt32(truncatingIfNeeded: z)
            let magnitude = Float(bits & 0x7fff_ffff) / Float(0x7fff_ffff)
            let sign: Float = (bits & 0x8000_0000) == 0 ? 1 : -1
            vector.append(sign * magnitude)
        }
        var norm = 0.0
        for value in vector { norm += Double(value) * Double(value) }
        norm = norm.squareRoot()
        guard norm > 0 else { return nil }
        return vector.map { Float(Double($0) / norm) }
    }
}
