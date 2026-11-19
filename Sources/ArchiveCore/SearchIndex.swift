// Query execution (DESIGN 6A): runs a compiled query tree against the
// archive index. A query that reduces to a single text leaf runs as one
// ranked FTS5 MATCH with the bm25 field weights; anything with filters or
// boolean structure runs as SQL over the message table, with text leaves
// contributing rowid-set subqueries. Ranking is a text-leaf concern:
// filtered browsing answers newest first.

import ArchiveSearch
import Foundation
import GRDB

/// One search result: the message row's id, its bm25 rank when the query
/// was a text query (lower is better, so best matches come first), the
/// thread the message belongs to, and a text snippet when the caller asked
/// for snippets.
public struct SearchHit: Sendable, Equatable {
    public var messageID: Int64
    public var rank: Double?
    public var threadID: Int64?
    public var snippet: String?
    /// True when the hit came from the trigram fallback (a substring or
    /// CJK match) rather than the exact token index (DESIGN 6A, M2.1).
    public var viaTrigram: Bool

    public init(
        messageID: Int64, rank: Double? = nil, threadID: Int64? = nil,
        snippet: String? = nil, viaTrigram: Bool = false
    ) {
        self.messageID = messageID
        self.rank = rank
        self.threadID = threadID
        self.snippet = snippet
        self.viaTrigram = viaTrigram
    }
}

public enum SearchExecutor {
    /// Executes a compiled query tree, best matches (or newest messages)
    /// first, capped at `limit` with `offset` pages skipped. With
    /// `groupByThread`, only each thread's best hit is returned (DESIGN 6A:
    /// results collapse to conversations).
    public static func run(
        _ node: CompiledNode,
        in db: Database,
        limit: Int = 200,
        offset: Int = 0,
        withSnippets: Bool = false,
        groupByThread: Bool = false
    ) throws -> [SearchHit] {
        if case .fts(let leaf) = node {
            let hits = try ranked(
                leaf.expression, in: db, limit: limit, offset: offset,
                withSnippets: withSnippets, groupByThread: groupByThread
            )
            // Zero exact hits and a trigram fallback exists: retry as a
            // plain substring match over the trigram table (DESIGN 6A,
            // M2.1). Hits keep the same shape and carry viaTrigram so
            // callers can say honestly where they came from.
            if hits.isEmpty, let fallback = leaf.trigramFallback {
                return try ranked(
                    fallback, in: db, limit: limit, offset: offset,
                    withSnippets: withSnippets, groupByThread: groupByThread,
                    table: "message_trigram", weightSQL: trigramWeights,
                    viaTrigram: true
                )
            }
            return hits
        }
        let (whereSQL0, arguments0) = predicate(for: node)
        let selected = "m.id AS id, m.threadID AS threadID"
        func fetch(_ whereSQL: String, _ arguments: [String]) throws -> [Row] {
            if groupByThread {
                // Window-function dedup: the best hit per thread (a thread with
                // no row keeps its own partition via the COALESCE) survives, so
                // paging stays correct no matter how much collapses.
                return try Row.fetchAll(
                    db,
                    sql: """
                    SELECT id, threadID FROM (
                        SELECT \(selected),
                               COALESCE(m.dateSent, m.dateReceived) AS sent,
                               ROW_NUMBER() OVER (
                                   PARTITION BY COALESCE(m.threadID, -m.id)
                                   ORDER BY COALESCE(m.dateSent, m.dateReceived) DESC, m.id DESC
                               ) AS rn
                        FROM message m
                        WHERE \(whereSQL)
                    )
                    WHERE rn = 1
                    ORDER BY sent DESC, id DESC
                    LIMIT \(max(0, limit)) OFFSET \(max(0, offset))
                    """,
                    arguments: StatementArguments(arguments)
                )
            }
            return try Row.fetchAll(
                db,
                sql: """
                SELECT \(selected)
                FROM message m
                WHERE \(whereSQL)
                ORDER BY COALESCE(m.dateSent, m.dateReceived) DESC, m.id DESC
                LIMIT \(max(0, limit)) OFFSET \(max(0, offset))
                """,
                arguments: StatementArguments(arguments)
            )
        }
        var rows = try fetch(whereSQL0, arguments0)
        var viaTrigram = false
        if rows.isEmpty, hasFallbackableLeaf(node) {
            // Whole-tree zero-hit retry: the exact form found nothing, so
            // every text leaf that carries a trigram fallback unions it in
            // (DESIGN 6A, M2.1 — "acct 4417"). Exact matching stays
            // preferred: the retry only rescues queries that found nothing
            // at all, and the hits say honestly that they came from the
            // trigram.
            let (whereSQL, arguments) = predicate(for: node, useFallbacks: true)
            rows = try fetch(whereSQL, arguments)
            viaTrigram = true
        }
        return rows.map { row -> SearchHit in
            let id: Int64 = row["id"] ?? 0
            return SearchHit(messageID: id, threadID: row["threadID"], viaTrigram: viaTrigram)
        }
    }

    // MARK: Ranked text path

    /// Recency boost (DESIGN 6A): a multiplicative bump on the bm25 score.
    /// bm25() is negative (more negative is better), so a factor just above
    /// 1.0 favors newer messages in proportion to their match strength — a
    /// fresh weak match never outranks a strong old one. The factor decays
    /// like 1/(1 + age/30 days); a message without a usable date gets no
    /// boost. Personal boosts (sent, replied, starred) and the semantic
    /// hybrid are later-milestone ranking work.
    private static let recencyFactorSQL = """
        (1.0 + 0.10 * COALESCE(
            1.0 / (1.0 + MAX(0.0, julianday('now')
                - julianday(COALESCE(m.dateSent, m.dateReceived))) / 30.0),
            0.0))
        """

    /// Field weights for the trigram fallback: all columns equal, because a
    /// substring hit carries no per-field strength the exact path's weights
    /// would agree with.
    private static let trigramWeights = Array(repeating: "1.0", count: 7).joined(separator: ", ")

    /// A single text leaf: one ranked FTS5 query over `table`. The bm25
    /// field weights times the recency factor order the rows; a lower value
    /// is a better match. `rank` on the hit is the raw bm25 score. The
    /// exact path runs over message_text with the tuned weights; the
    /// trigram fallback runs over message_trigram with equal weights.
    static func ranked(
        _ expression: String, in db: Database, limit: Int, offset: Int,
        withSnippets: Bool, groupByThread: Bool,
        table: String = "message_text", weightSQL: String? = nil, viaTrigram: Bool = false
    ) throws -> [SearchHit] {
        let weights = weightSQL
            ?? QueryCompiler.bm25Weights
                .split(separator: ",")
                .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                .map { String(format: "%.1f", $0) }
                .joined(separator: ", ")
        let snippetColumn = withSnippets
            ? ", snippet(\(table), -1, '[[', ']]', ' … ', 16) AS snip"
            : ""
        // bm25() with the field weights both scores and orders the rows;
        // the implicit `rank` column would rank with default weights (all
        // fields equal), which the search contract does not want.
        let base = """
            SELECT m.id AS id, m.threadID AS threadID,
                   bm25(\(table), \(weights)) AS score,
                   bm25(\(table), \(weights)) * \(recencyFactorSQL) AS final\(snippetColumn)
            FROM \(table)
            JOIN message m ON m.id = \(table).rowid
            WHERE \(table) MATCH ?
            """
        let outer = withSnippets ? "id, threadID, score, snip" : "id, threadID, score"
        let sql: String
        if groupByThread {
            // Same window-function dedup as the predicate path, keyed on
            // rank order: each thread's best-scoring hit survives, and
            // paging stays correct no matter how much collapses.
            sql = """
            SELECT \(outer) FROM (
                SELECT *, ROW_NUMBER() OVER (
                    PARTITION BY COALESCE(threadID, -id) ORDER BY final
                ) AS rn
                FROM (\(base))
            )
            WHERE rn = 1
            ORDER BY final
            LIMIT \(max(0, limit)) OFFSET \(max(0, offset))
            """
        } else {
            sql = """
            \(base)
            ORDER BY final
            LIMIT \(max(0, limit)) OFFSET \(max(0, offset))
            """
        }
        let rows = try Row.fetchAll(db, sql: sql, arguments: [expression])
        return rows.map { row -> SearchHit in
            let id: Int64 = row["id"] ?? 0
            let snippet: String? = withSnippets ? row["snip"] : nil
            return SearchHit(
                messageID: id, rank: row["score"], threadID: row["threadID"],
                snippet: snippet, viaTrigram: viaTrigram
            )
        }
    }

    // MARK: Predicate path

    /// Builds the WHERE clause for a compiled tree. Text leaves contribute
    /// rowid-set subqueries over the FTS table (CJK leaves union their
    /// trigram match eagerly); filters contribute their SQL verbatim.
    /// Boolean structure groups with parentheses.
    static func predicate(
        for node: CompiledNode, useFallbacks: Bool = false
    ) -> (sql: String, arguments: [String]) {
        switch node {
        case .fts(let leaf):
            guard let trigram = leaf.trigramFallback else {
                return (
                    "m.id IN (SELECT rowid FROM message_text WHERE message_text MATCH ?)",
                    [leaf.expression]
                )
            }
            // Two cases union the trigram match in: a CJK leaf always (the
            // query's segmentation can differ from the indexed text's, so
            // its exact match is unreliable — DESIGN 6A, M2.1), and any
            // other fallback-able leaf when the whole exact tree found
            // nothing and the zero-hit retry substituted fallbacks.
            guard useFallbacks || leaf.trigramEager else {
                return (
                    "m.id IN (SELECT rowid FROM message_text WHERE message_text MATCH ?)",
                    [leaf.expression]
                )
            }
            return (
                """
                m.id IN (SELECT rowid FROM message_text WHERE message_text MATCH ?)
                OR m.id IN (SELECT rowid FROM message_trigram WHERE message_trigram MATCH ?)
                """,
                [leaf.expression, trigram]
            )
        case .filter(let filter):
            return (filter.sql, filter.arguments)
        case .and(let children):
            let parts = children.map { wrap($0, useFallbacks: useFallbacks) }
            return (
                parts.map(\.sql).joined(separator: " AND "),
                parts.flatMap(\.arguments)
            )
        case .or(let children):
            let parts = children.map { wrap($0, useFallbacks: useFallbacks) }
            return (
                parts.map(\.sql).joined(separator: " OR "),
                parts.flatMap(\.arguments)
            )
        case .not(let inner):
            let (sql, arguments) = wrap(inner, useFallbacks: useFallbacks)
            return ("NOT (\(sql))", arguments)
        }
    }

    /// Whether any text leaf in the tree carries a trigram fallback — the
    /// condition for the predicate path's whole-tree zero-hit retry.
    static func hasFallbackableLeaf(_ node: CompiledNode) -> Bool {
        switch node {
        case .fts(let leaf):
            return leaf.trigramFallback != nil
        case .filter:
            return false
        case .and(let children), .or(let children):
            return children.contains { hasFallbackableLeaf($0) }
        case .not(let inner):
            return hasFallbackableLeaf(inner)
        }
    }

    /// Parenthesized form, for nesting under OR and NOT.
    static func wrap(
        _ node: CompiledNode, useFallbacks: Bool = false
    ) -> (sql: String, arguments: [String]) {
        let (sql, arguments) = predicate(for: node, useFallbacks: useFallbacks)
        return ("(\(sql))", arguments)
    }
}

extension ArchiveStore {
    /// A full search answer: hits plus any compile warnings (e.g. amount:
    /// matching nothing until entity extraction lands).
    public struct SearchResults: Sendable, Equatable {
        public var hits: [SearchHit]
        public var warnings: [String]

        public init(hits: [SearchHit], warnings: [String]) {
            self.hits = hits
            self.warnings = warnings
        }
    }

    /// Parses and runs one query line (DESIGN 6A). Throws QueryError for a
    /// malformed query so callers can surface it; an empty query returns
    /// no hits rather than everything. With `groupByThread`, results
    /// collapse to conversations: one hit per thread, the thread's best.
    public func search(
        _ query: String,
        limit: Int = 200,
        offset: Int = 0,
        withSnippets: Bool = false,
        groupByThread: Bool = false
    ) throws -> SearchResults {
        guard let node = try QueryParser.parse(query) else {
            return SearchResults(hits: [], warnings: [])
        }
        let compiled = try QueryCompiler.compile(node)
        let hits = try db.read { db in
            try SearchExecutor.run(
                compiled.root, in: db, limit: limit, offset: offset,
                withSnippets: withSnippets, groupByThread: groupByThread
            )
        }
        return SearchResults(hits: hits, warnings: compiled.warnings)
    }
}
