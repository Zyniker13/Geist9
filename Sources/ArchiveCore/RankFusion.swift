// Reciprocal rank fusion (decision 0045): the merge that combines the
// keyword (BM25) ranking and the semantic (cosine) ranking into one list.
// RRF uses only positions — no calibration between score scales — which is
// why it was chosen over a weighted linear combination.

public enum RankFusion {
    /// Fuse ranked identifier lists. Each list is ordered best-first; an
    /// identifier's score is the sum over lists of 1/(k + position) with
    /// positions starting at 1 and `k` = 60 (the standard constant from the
    /// RRF paper). Duplicate identifiers inside one list contribute once per
    /// occurrence — callers pass deduplicated lists. Result: descending
    /// score, ties by ascending identifier for determinism, truncated to
    /// `limit`.
    public static func rrf(
        _ lists: [[Int64]], k: Double = 60, limit: Int
    ) -> [(id: Int64, score: Double)] {
        guard limit > 0 else { return [] }
        var scores: [Int64: Double] = [:]
        for list in lists {
            for (index, id) in list.enumerated() {
                scores[id, default: 0] += 1 / (k + Double(index + 1))
            }
        }
        let merged = scores.map { (id: $0.key, score: $0.value) }
        let sorted = merged.sorted { a, b in
            a.score == b.score ? a.id < b.id : a.score > b.score
        }
        return Array(sorted.prefix(limit))
    }
}
