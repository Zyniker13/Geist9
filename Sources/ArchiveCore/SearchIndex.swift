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

    public init(
        messageID: Int64, rank: Double? = nil, threadID: Int64? = nil, snippet: String? = nil
    ) {
        self.messageID = messageID
        self.rank = rank
        self.threadID = threadID
        self.snippet = snippet
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
        if case .fts(let expression) = node {
            return try ranked(
                expression, in: db, limit: limit, offset: offset,
                withSnippets: withSnippets, groupByThread: groupByThread
            )
        }
        let (whereSQL, arguments) = predicate(for: node)
        let selected = "m.id AS id, m.threadID AS threadID"
        let rows: [Row]
        if groupByThread {
            // Window-function dedup: the best hit per thread (a thread with
            // no row keeps its own partition via the COALESCE) survives, so
            // paging stays correct no matter how much collapses.
            rows = try Row.fetchAll(
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
        } else {
            rows = try Row.fetchAll(
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
        return rows.map { row -> SearchHit in
            let id: Int64 = row["id"] ?? 0
            return SearchHit(messageID: id, threadID: row["threadID"])
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

    /// A single text leaf: one ranked FTS5 query. The bm25 field weights
    /// times the recency factor order the rows; a lower value is a better
    /// match. `rank` on the hit is the raw bm25 score.
    static func ranked(
        _ expression: String, in db: Database, limit: Int, offset: Int,
        withSnippets: Bool, groupByThread: Bool
    ) throws -> [SearchHit] {
        let weightSQL = QueryCompiler.bm25Weights
            .split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            .map { String(format: "%.1f", $0) }
            .joined(separator: ", ")
        let snippetColumn = withSnippets
            ? ", snippet(message_text, -1, '[[', ']]', ' … ', 16) AS snip"
            : ""
        // bm25() with the field weights both scores and orders the rows;
        // the implicit `rank` column would rank with default weights (all
        // fields equal), which the search contract does not want.
        let base = """
            SELECT m.id AS id, m.threadID AS threadID,
                   bm25(message_text, \(weightSQL)) AS score,
                   bm25(message_text, \(weightSQL)) * \(recencyFactorSQL) AS final\(snippetColumn)
            FROM message_text
            JOIN message m ON m.id = message_text.rowid
            WHERE message_text MATCH ?
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
                snippet: snippet
            )
        }
    }

    // MARK: Predicate path

    /// Builds the WHERE clause for a compiled tree. Text leaves contribute
    /// rowid-set subqueries over the FTS table; filters contribute their
    /// SQL verbatim. Boolean structure groups with parentheses.
    static func predicate(for node: CompiledNode) -> (sql: String, arguments: [String]) {
        switch node {
        case .fts(let expression):
            return (
                "m.id IN (SELECT rowid FROM message_text WHERE message_text MATCH ?)",
                [expression]
            )
        case .filter(let filter):
            return (filter.sql, filter.arguments)
        case .and(let children):
            let parts = children.map { wrap($0) }
            return (
                parts.map(\.sql).joined(separator: " AND "),
                parts.flatMap(\.arguments)
            )
        case .or(let children):
            let parts = children.map { wrap($0) }
            return (
                parts.map(\.sql).joined(separator: " OR "),
                parts.flatMap(\.arguments)
            )
        case .not(let inner):
            let (sql, arguments) = wrap(inner)
            return ("NOT (\(sql))", arguments)
        }
    }

    /// Parenthesized form, for nesting under OR and NOT.
    static func wrap(_ node: CompiledNode) -> (sql: String, arguments: [String]) {
        let (sql, arguments) = predicate(for: node)
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
