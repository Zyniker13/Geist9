// As-you-type vocabulary (decision 0025): term completions served from a
// precomputed first-letter table for a one-character prefix and from a live
// FTS5 vocabulary range scan for longer prefixes. The match-set size is the
// sum of document frequencies over the prefix's terms, computed in the same
// query as the completions (the gate adds no extra query).

import ArchiveSearch
import Foundation
import GRDB

/// One vocabulary term completion: the term and its document frequency.
public struct TermCompletion: Sendable, Equatable {
    public var term: String
    public var doc: Int

    public init(term: String, doc: Int) {
        self.term = term
        self.doc = doc
    }
}

/// The result of an as-you-type completion query: the term completions and
/// the match-set size (the sum of document frequencies over the prefix's
/// terms — an upper bound on the true match set, decision 0025).
public struct CompletionResult: Sendable, Equatable {
    public var completions: [TermCompletion]
    public var matchSet: Int

    public init(completions: [TermCompletion], matchSet: Int) {
        self.completions = completions
        self.matchSet = matchSet
    }
}

/// The as-you-type vocabulary (decision 0025). Completions are served from a
/// precomputed first-letter table for a one-character prefix and from a live
/// FTS5 vocabulary range scan for longer prefixes. The match-set size is the
/// sum of document frequencies over the prefix's terms, computed in the same
/// query as the completions.
public enum Vocabulary {
    /// The gate threshold: if the match-set size is at or below this, the
    /// as-you-type path runs the full ranked search and shows ranked results;
    /// otherwise it shows completions only. Conservative: 50 ms ÷ 730 ns/doc
    /// ≈ 68k, rounded down (decision 0025).
    public static let gateThreshold = 60_000

    /// The number of top terms kept per leading letter in the first-letter
    /// table (and returned per completion query).
    static let topN = 20

    /// The name of the temporary FTS5 vocabulary table used for the live
    /// range scans and the first-letter rebuild. Created and dropped per
    /// connection.
    static let vocabTable = "temp._bcon_vocab"

    /// Rebuilds the first-letter tables from the current FTS5 vocabulary.
    /// Called at the end of an import and by the backfill. Never touches
    /// stored message rows.
    public static func rebuildFirstLetterTable(in db: Database) throws {
        try db.execute(sql: "CREATE VIRTUAL TABLE IF NOT EXISTS \(vocabTable) USING fts5vocab(main, 'message_text', 'row')")
        defer { try? db.execute(sql: "DROP TABLE IF EXISTS \(vocabTable)") }
        try db.execute(sql: "DELETE FROM first_letter")
        try db.execute(sql: "DELETE FROM first_letter_terms")
        try db.execute(sql: """
            INSERT INTO first_letter (letter, total_doc)
            SELECT substr(term, 1, 1), SUM(doc)
            FROM \(vocabTable)
            GROUP BY substr(term, 1, 1)
            """)
        try db.execute(sql: """
            INSERT INTO first_letter_terms (letter, ord, term, doc)
            SELECT letter, ord, term, doc FROM (
                SELECT substr(term, 1, 1) AS letter, term, doc,
                       ROW_NUMBER() OVER (PARTITION BY substr(term, 1, 1) ORDER BY doc DESC, term) AS ord
                FROM \(vocabTable)
            )
            WHERE ord <= \(topN)
            """)
    }

    /// Completes a prefix with vocabulary terms. A one-character prefix is
    /// served from the precomputed first-letter table (point lookup,
    /// sub-millisecond); a longer prefix is served from a live FTS5
    /// vocabulary range scan. The match-set size is the sum of document
    /// frequencies over the prefix's terms (an upper bound on the true match
    /// set), computed in the same query as the completions.
    public static func complete(prefix: String, in db: Database) throws -> CompletionResult {
        let folded = TokenPipeline.folded(prefix)
        guard !folded.isEmpty else {
            return CompletionResult(completions: [], matchSet: 0)
        }
        if folded.count == 1 {
            let letter = folded
            let matchSet = try Int.fetchOne(
                db,
                sql: "SELECT total_doc FROM first_letter WHERE letter = ?",
                arguments: [letter]
            ) ?? 0
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT term, doc FROM first_letter_terms WHERE letter = ? ORDER BY ord LIMIT ?",
                arguments: [letter, topN]
            )
            let completions = rows.map {
                TermCompletion(
                    term: ($0["term"] as String?) ?? "",
                    doc: ($0["doc"] as Int?) ?? 0
                )
            }
            return CompletionResult(completions: completions, matchSet: matchSet)
        } else {
            let lo = folded
            let hi = folded + "\u{FFFF}"
            try db.execute(sql: "CREATE VIRTUAL TABLE IF NOT EXISTS \(vocabTable) USING fts5vocab(main, 'message_text', 'row')")
            defer { try? db.execute(sql: "DROP TABLE IF EXISTS \(vocabTable)") }
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT term, doc, SUM(doc) OVER () AS match_set
                    FROM \(vocabTable)
                    WHERE term >= ? AND term < ?
                    ORDER BY doc DESC, term
                    LIMIT ?
                    """,
                arguments: [lo, hi, topN]
            )
            let completions = rows.map {
                TermCompletion(
                    term: ($0["term"] as String?) ?? "",
                    doc: ($0["doc"] as Int?) ?? 0
                )
            }
            let matchSet: Int = (rows.first?["match_set"] as Int?) ?? 0
            return CompletionResult(completions: completions, matchSet: matchSet)
        }
    }
}

extension ArchiveStore {
    /// Rebuilds the as-you-type vocabulary tables from the current FTS5
    /// vocabulary (decision 0025). Called at the end of every import entry
    /// point, by the backfill, and by the core-v7 migration. Only the
    /// vocabulary tables change; stored message rows are never touched.
    public func refreshAsYouTypeVocabulary() throws {
        try db.write { db in
            try Vocabulary.rebuildFirstLetterTable(in: db)
        }
    }
}
