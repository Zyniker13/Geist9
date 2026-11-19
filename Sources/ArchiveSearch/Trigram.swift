// Trigram fallback (DESIGN 6A, M2.1): alongside the exact-token FTS5 index,
// a trigram table over the same columns holds raw folded text, so substring
// and partial-word queries ("2214" inside INV221488) and CJK queries whose
// segmentation differs from the indexed text still find messages. Exact
// token matching and ranking stay with message_text: a leaf's trigram
// condition runs only when the exact match found nothing, or eagerly for
// CJK leaves, where query and text can segment differently.

import Foundation

/// One text leaf's compiled form: the exact-token MATCH expression for
/// message_text, plus its optional trigram fallback for message_trigram.
public struct FTSLeaf: Sendable, Equatable {
    /// MATCH expression over the message_text columns.
    public var expression: String
    /// MATCH expression over the message_trigram columns, or nil when no
    /// term is long enough to form trigrams (fewer than three characters).
    public var trigramFallback: String?
    /// CJK leaves union their trigram match eagerly in the predicate path:
    /// the query's segmentation can differ from the indexed text's, and the
    /// predicate path has no zero-hit retry to fall back on.
    public var trigramEager: Bool

    public init(
        expression: String, trigramFallback: String? = nil, trigramEager: Bool = false
    ) {
        self.expression = expression
        self.trigramFallback = trigramFallback
        self.trigramEager = trigramEager
    }
}

enum TrigramPlan {
    /// A trigram MATCH phrase: quoted, with embedded quotes flattened to
    /// spaces (the same escape the exact path uses for phrases). Inside
    /// quotes every other character is literal, which is what substring
    /// matching wants.
    static func phrase(_ text: String) -> String {
        "\"\(text.replacingOccurrences(of: "\"", with: " "))\""
    }

    /// Builds the trigram fallback MATCH expression for one leaf over the
    /// brace-free `columns` list. Each phrase is split into maximal runs of
    /// a single script class (CJK vs everything else), and a run shorter
    /// than three characters cannot form trigrams, so it is dropped; what
    /// remains must appear as a substring of the stored folded text. Splitting
    /// matters for CJK: a CJK run stays whole (its characters have no spaces
    /// to break on), so a query matches even when the exact index segmented
    /// the stored text differently from the query. Returns nil when nothing
    /// long enough remains — the leaf then matches only through the exact path.
    static func fallback(columns: String, phrases: [String]) -> String? {
        var usable: [String] = []
        for raw in phrases {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            for piece in pieces(trimmed) {
                let clean = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                if clean.count >= 3 { usable.append(phrase(clean)) }
            }
        }
        guard !usable.isEmpty else { return nil }
        return "{\(columns)} : \(usable.joined(separator: " AND "))"
    }

    /// Splits one phrase into maximal runs of a single script class (CJK
    /// vs everything else). Punctuation never splits a run: "don't" and
    /// "INV-221488" stay whole, and the trigram tokenizer matches their
    /// characters literally.
    static func pieces(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        var currentCJK = false
        for ch in text {
            let cjk = ch.unicodeScalars.contains { TokenPipeline.scalars.cjk.contains($0) }
            if !current.isEmpty && cjk != currentCJK {
                out.append(current)
                current = ""
            }
            currentCJK = cjk
            current.append(ch)
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}
