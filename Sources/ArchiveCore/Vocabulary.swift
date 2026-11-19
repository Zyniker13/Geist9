// As-you-type vocabulary (decisions 0025 and 0027): term completions are
// served from a precomputed first-letter table for a one-character prefix
// and from the persistent vocabulary table for longer prefixes. The
// match-set size is the sum of document frequencies over the prefix's
// terms, computed in the same query as the completions (the gate adds no
// extra query). The persistent vocabulary table mirrors the FTS5 index's
// term set exactly: populated from the live fts5vocab on migration and on
// every full rebuild, and kept current by per-message deltas applied in
// the ingest transaction (decision 0027).

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

/// The as-you-type vocabulary (decisions 0025 and 0027). Completions are
/// served from a precomputed first-letter table for a one-character prefix
/// and from the persistent vocabulary table for longer prefixes. The
/// match-set size is the sum of document frequencies over the prefix's
/// terms, computed in the same query as the completions.
public enum Vocabulary {
    /// The gate threshold: if the match-set size is at or below this, the
    /// as-you-type path runs the full ranked search and shows ranked results;
    /// otherwise it shows completions only. Conservative: 50 ms ÷ 730 ns/doc
    /// ≈ 68k, rounded down (decision 0025).
    public static let gateThreshold = 60_000

    /// The number of top terms kept per leading letter in the first-letter
    /// table (and returned per completion query).
    static let topN = 20

    /// The name of the persistent vocabulary table (decision 0027): one row
    /// per distinct FTS5 term with its exact document frequency, keyed on
    /// the term so prefix range scans walk a single b-tree.
    static let termTable = "vocabulary"

    /// The name of the temporary FTS5 vocabulary table used for the live
    /// range scans during a full rebuild and for the core-v7 first-letter
    /// migration. Created and dropped per connection.
    static let vocabTable = "temp._bcon_vocab"

    /// Rebuilds the persistent vocabulary table and the first-letter tables
    /// from the current FTS5 vocabulary (decision 0027). Called by the
    /// core-v9 migration, at the end of an import, and by the backfill.
    /// Never touches stored message rows.
    public static func rebuildAll(in db: Database) throws {
        try db.execute(sql: "CREATE VIRTUAL TABLE IF NOT EXISTS \(vocabTable) USING fts5vocab(main, 'message_text', 'row')")
        defer { try? db.execute(sql: "DROP TABLE IF EXISTS \(vocabTable)") }
        try db.execute(sql: "DELETE FROM \(termTable)")
        try db.execute(sql: "INSERT INTO \(termTable) (term, doc) SELECT term, doc FROM \(vocabTable)")
        try rebuildFirstLetterTables(in: db)
    }

    /// Rebuilds the first-letter tables from the persistent vocabulary
    /// table (decision 0027).
    static func rebuildFirstLetterTables(in db: Database) throws {
        try db.execute(sql: "DELETE FROM first_letter")
        try db.execute(sql: "DELETE FROM first_letter_terms")
        try db.execute(sql: """
            INSERT INTO first_letter (letter, total_doc)
            SELECT substr(term, 1, 1), SUM(doc)
            FROM \(termTable)
            GROUP BY substr(term, 1, 1)
            """)
        try db.execute(sql: """
            INSERT INTO first_letter_terms (letter, ord, term, doc)
            SELECT letter, ord, term, doc FROM (
                SELECT substr(term, 1, 1) AS letter, term, doc,
                       ROW_NUMBER() OVER (PARTITION BY substr(term, 1, 1) ORDER BY doc DESC, term) AS ord
                FROM \(termTable)
            )
            WHERE ord <= \(topN)
            """)
    }

    /// Applies a transaction-local document-frequency delta to the
    /// persistent vocabulary table (decision 0027): +1 for a term new in
    /// this message, -1 for a term the re-indexed message no longer holds.
    /// Called once per ingest transaction, in the same transaction as the
    /// message_text rows the delta describes, so the table can neither lead
    /// nor lag the index rows it mirrors.
    static func applyDeltas(_ deltas: [String: Int], in db: Database) throws {
        for (term, delta) in deltas where delta != 0 {
            try db.execute(
                sql: """
                INSERT INTO \(termTable) (term, doc) VALUES (?, ?)
                ON CONFLICT(term) DO UPDATE SET doc = doc + excluded.doc
                """,
                arguments: [term, delta]
            )
        }
        // A term that just lost its last document (or, if a delta were ever
        // miscounted, went negative) must not linger: the table mirrors the
        // FTS5 term set exactly, and the FTS index has no such row.
        try db.execute(sql: "DELETE FROM \(termTable) WHERE doc <= 0")
    }

    /// Rebuilds the first-letter tables from the current FTS5 vocabulary.
    /// Called by the core-v7 migration, which runs before the persistent
    /// vocabulary table exists (core-v9). Never touches stored message rows.
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
    /// sub-millisecond); a longer prefix is served from a single b-tree
    /// range scan over the persistent vocabulary table (decision 0027). The
    /// match-set size is the sum of document frequencies over the prefix's
    /// terms (an upper bound on the true match set), computed in the same
    /// query as the completions.
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
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT term, doc, SUM(doc) OVER () AS match_set
                    FROM \(termTable)
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
    /// vocabulary (decisions 0025 and 0027): the persistent vocabulary table
    /// and the first-letter tables. Called at the end of every import entry
    /// point, by the backfill, by the core-v9 migration, and after a full
    /// reindex. Only the vocabulary tables change; stored message rows are
    /// never touched.
    public func refreshAsYouTypeVocabulary() throws {
        try db.write { db in
            try Vocabulary.rebuildAll(in: db)
        }
    }
}
