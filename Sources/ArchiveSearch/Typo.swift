// Typo tolerance (decision 0035): when an exact-token query finds nothing,
// the search executor generates one-edit variants of the query's terms and
// checks them against the vocabulary. A variant that is a real indexed term
// is a candidate correction; the corrected terms are then matched with the
// normal ranked query. This rescues single typos (a swapped, missing, extra
// or wrong letter) that the trigram fallback misses, because the trigram
// path is substring-based and cannot see an edit.
//
// The variant generator is pure and DB-free: it enumerates every string one
// edit away from a term. The vocabulary lookup (in ArchiveCore) is what
// keeps the result small — only variants that actually occur in the archive
// survive.

import Foundation

public enum Typo {
    /// Every string that differs from `term` by exactly one edit: a
    /// substitution, a transposition of two adjacent characters, a
    /// deletion, or an insertion. Deduplicated, the original term excluded,
    /// and bounded to the index's token length range so a variant can
    /// actually be an indexed term. Order is deterministic (substitutions,
    /// then transpositions, deletions, insertions; each in index order) so
    /// tests can assert on it.
    public static func oneEditVariants(of term: String) -> [String] {
        let chars = Array(term)
        let n = chars.count
        guard n >= 1 else { return [] }
        var seen: Set<String> = [term]
        var out: [String] = []
        func add(_ s: String) {
            guard s.count >= 2, s.count <= TokenPipeline.maxTokenLength,
                  seen.insert(s).inserted else { return }
            out.append(s)
        }
        let letters = Array("abcdefghijklmnopqrstuvwxyz")

        // Substitution: replace each position with each other letter.
        for i in 0..<n {
            for c in letters where c != chars[i] {
                var v = chars
                v[i] = c
                add(String(v))
            }
        }
        // Transposition: swap each adjacent pair (only when they differ).
        for i in 0..<(n - 1) where chars[i] != chars[i + 1] {
            var v = chars
            v.swapAt(i, i + 1)
            add(String(v))
        }
        // Deletion: drop each character.
        for i in 0..<n {
            var v = chars
            v.remove(at: i)
            add(String(v))
        }
        // Insertion: insert each letter at each gap (before the first,
        // between, after the last).
        for i in 0...n {
            for c in letters {
                var v = chars
                v.insert(c, at: i)
                add(String(v))
            }
        }
        return out
    }
}
