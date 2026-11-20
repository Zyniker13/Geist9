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
    /// True when the hit came from the one-edit typo rescue (decision 0035):
    /// the exact index and the trigram fallback both found nothing, so the
    /// query's terms were corrected against the vocabulary and re-matched.
    public var viaTypo: Bool
    /// True when the hit was found only by the semantic side (decision
    /// 0045): it has no keyword rank and no snippet, because no term of
    /// the query matched it. A hit found by both sides keeps its keyword
    /// data and is not flagged.
    public var viaSemantic: Bool

    public init(
        messageID: Int64, rank: Double? = nil, threadID: Int64? = nil,
        snippet: String? = nil, viaTrigram: Bool = false, viaTypo: Bool = false,
        viaSemantic: Bool = false
    ) {
        self.messageID = messageID
        self.rank = rank
        self.threadID = threadID
        self.snippet = snippet
        self.viaTrigram = viaTrigram
        self.viaTypo = viaTypo
        self.viaSemantic = viaSemantic
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
            if !hits.isEmpty { return hits }
            // Zero exact hits and a trigram fallback exists: retry as a
            // plain substring match over the trigram table (DESIGN 6A,
            // M2.1). Hits keep the same shape and carry viaTrigram so
            // callers can say honestly where they came from.
            if let fallback = leaf.trigramFallback {
                let trigramHits = try ranked(
                    fallback, in: db, limit: limit, offset: offset,
                    withSnippets: withSnippets, groupByThread: groupByThread,
                    table: "message_trigram", weightSQL: trigramWeights,
                    viaTrigram: true
                )
                if !trigramHits.isEmpty { return trigramHits }
            }
            // Zero hits from the exact index and the trigram fallback: the
            // last resort is the one-edit typo rescue (decision 0035). It
            // corrects the query's single term against the vocabulary and
            // re-matches; hits carry viaTypo.
            if let typoHits = try typoRescue(
                for: leaf, in: db, limit: limit, offset: offset,
                withSnippets: withSnippets, groupByThread: groupByThread
            ) {
                return typoHits
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
    ///
    /// Executor v2: the "now" half is a bound parameter and the day half is
    /// the precomputed REAL `day` from `message_rank` (migration core-v6),
    /// so the per-row `julianday()` pair is gone. `dayRef` is `r.day` in
    /// the flat shape and `day` when the side table's column has been
    /// projected into a subquery.
    private static func recencyFactor(_ dayRef: String) -> String {
        "(1.0 + 0.10 * COALESCE(" +
            "1.0 / (1.0 + MAX(0.0, :now - \(dayRef)) / 30.0), 0.0))"
    }

    /// Julian day for the recency bound parameter, matching SQLite's
    /// `julianday('now')` (2440587.5 = the 1970-01-01 epoch anchor).
    private static func nowJD() -> Double {
        2440587.5 + Date().timeIntervalSince1970 / 86400.0
    }

    /// Field weights for the trigram fallback: all columns equal, because a
    /// substring hit carries no per-field strength the exact path's weights
    /// would agree with.
    private static let trigramWeights = Array(repeating: "1.0", count: 7).joined(separator: ", ")

    /// A single text leaf: one ranked FTS5 query over `table`. The bm25
    /// field weights times the recency factor order the rows; a lower value
    /// is a better match. `rank` on the hit is the raw bm25 score. The
    /// exact path runs over message_text with the tuned weights; the
    /// trigram fallback runs over message_trigram with equal weights.
    ///
    /// Executor v2 shape (profiled on the 1M corpus): bm25() is called once
    /// per matched row (the old shape called it twice), the join goes to
    /// the narrow `message_rank` side table (id, threadID, day) instead of
    /// the wide `message` row, `now` is a bound parameter instead of a
    /// per-row `julianday('now')` call, and snippets are computed only for
    /// the surviving rows in a second pass. The FTS table is referenced
    /// unaliased: FTS5's aux functions (`bm25`, `snippet`) and MATCH
    /// resolve the hidden column by the table's real name, never a SQL
    /// alias.
    static func ranked(
        _ expression: String, in db: Database, limit: Int, offset: Int,
        withSnippets: Bool, groupByThread: Bool,
        table: String = "message_text", weightSQL: String? = nil, viaTrigram: Bool = false,
        viaTypo: Bool = false
    ) throws -> [SearchHit] {
        let weights = weightSQL
            ?? QueryCompiler.bm25Weights
                .split(separator: ",")
                .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                .map { String(format: "%.1f", $0) }
                .joined(separator: ", ")
        let args = StatementArguments(["q": expression, "now": nowJD()])
        // bm25() with the field weights both scores and orders the rows;
        // the implicit `rank` column would rank with default weights (all
        // fields equal), which the search contract does not want.
        let baseCols = """
            SELECT \(table).rowid AS id, r.threadID AS threadID,
                   bm25(\(table), \(weights)) AS score
            """
        let baseFrom = """
            FROM \(table)
            JOIN message_rank r ON r.id = \(table).rowid
            WHERE \(table) MATCH :q
            """
        let sql: String
        if groupByThread {
            // Same window-function dedup as the predicate path, keyed on
            // rank order: each thread's best-scoring hit survives, and
            // paging stays correct no matter how much collapses. The inner
            // subquery also projects `day`, which the middle level needs
            // as a plain column to multiply into the recency factor
            // (SQLite only resolves select-list aliases in ORDER BY and
            // friends, so the middle level cannot reference `score`
            // through an alias chain — it can reference it as a column).
            sql = """
                SELECT id, threadID, score FROM (
                    SELECT id, threadID, score,
                           score * \(recencyFactor("day")) AS final,
                           ROW_NUMBER() OVER (
                               PARTITION BY COALESCE(threadID, -id)
                               ORDER BY score * \(recencyFactor("day"))
                           ) AS rn
                    FROM (\(baseCols), r.day AS day \(baseFrom))
                )
                WHERE rn = 1
                ORDER BY final
                LIMIT \(max(0, limit)) OFFSET \(max(0, offset))
                """
        } else {
            sql = """
                \(baseCols) \(baseFrom)
                ORDER BY score * \(recencyFactor("r.day"))
                LIMIT \(max(0, limit)) OFFSET \(max(0, offset))
                """
        }
        let rows = try Row.fetchAll(db, sql: sql, arguments: args)
        var hits: [SearchHit] = rows.map { row -> SearchHit in
            let id: Int64 = row["id"] ?? 0
            return SearchHit(
                messageID: id, rank: row["score"], threadID: row["threadID"],
                viaTrigram: viaTrigram, viaTypo: viaTypo
            )
        }
        guard withSnippets, !hits.isEmpty else { return hits }
        // Deferred snippets: re-run the same MATCH restricted to the
        // surviving rowids so snippet() sees the query's term offsets (a
        // rowid-only lookup would produce fallback snippets), then attach.
        // The FTS scan touches only the survivors.
        let idsJSON = "[" + hits.map { String($0.messageID) }.joined(separator: ",") + "]"
        let snipSQL = """
            SELECT rowid AS rid, snippet(\(table), -1, '[[', ']]', ' … ', 16) AS snip
            FROM \(table)
            WHERE \(table) MATCH :q
              AND rowid IN (SELECT value FROM json_each(:ids))
            """
        let snipArgs = StatementArguments(["q": expression, "ids": idsJSON])
        var snippets: [Int64: String] = [:]
        for row in try Row.fetchAll(db, sql: snipSQL, arguments: snipArgs) {
            let id: Int64 = row["rid"] ?? 0
            snippets[id] = row["snip"]
        }
        for index in hits.indices {
            hits[index].snippet = snippets[hits[index].messageID]
        }
        return hits
    }

    // MARK: Typo rescue (decision 0035)

    /// The one-edit typo rescue: the exact index and the trigram fallback
    /// both found nothing, so the query's single term is corrected against
    /// the vocabulary and re-matched. It runs only for plain single-term
    /// text leaves (a phrase's tokens are meaningful only together, and a
    /// multi-word query is better served by the trigram substring fallback).
    /// The corrections are matched against exactly the columns the leaf
    /// searched, so a rescued query keeps its field filter (DESIGN 6A).
    /// Returns nil when the leaf is not a single-term text leaf or no
    /// correction is a real term.
    static func typoRescue(
        for leaf: FTSLeaf, in db: Database, limit: Int, offset: Int,
        withSnippets: Bool, groupByThread: Bool
    ) throws -> [SearchHit]? {
        guard let expression = try typoRescueExpression(for: leaf, in: db) else {
            return nil
        }
        return try ranked(
            expression, in: db, limit: limit, offset: offset,
            withSnippets: withSnippets, groupByThread: groupByThread,
            viaTypo: true
        )
    }

    /// The rescued FTS expression for a leaf, or nil when the rescue does
    /// not apply: the leaf must be a single-term text leaf and at least one
    /// one-edit variant must be a real indexed term. Shared by the ranked
    /// path (`typoRescue`) and the facet-count path, so facets describe the
    /// same rescued set the hits show.
    static func typoRescueExpression(
        for leaf: FTSLeaf, in db: Database
    ) throws -> String? {
        guard leaf.terms.count == 1, let term = leaf.terms.first,
              let columns = leaf.rescueColumns else { return nil }
        let candidates = Typo.oneEditVariants(of: term)
        guard !candidates.isEmpty else { return nil }
        let found = try vocabularyTerms(among: candidates, in: db)
        guard !found.isEmpty else { return nil }
        // Match the corrections against exactly the columns the leaf
        // searched, so a rescued query keeps its field filter and never
        // reaches quoted text (DESIGN 6A). Quoted so a correction is
        // always a single term.
        let quoted = found.map { ftsQuote($0) }.joined(separator: " OR ")
        return "\(columns) : (\(quoted))"
    }

    /// The subset of `candidates` that are real indexed terms (present in
    /// the vocabulary with a positive document frequency). The vocabulary is
    /// the filter that keeps the rescue small and honest: only corrections
    /// that actually occur in the archive survive. Chunked so a long term's
    /// ~400 one-edit variants never exceed SQLite's bind-parameter limit.
    static func vocabularyTerms(among candidates: [String], in db: Database) throws -> [String] {
        var found: Set<String> = []
        let chunkSize = 400
        var i = 0
        while i < candidates.count {
            let chunk = Array(candidates[i ..< min(i + chunkSize, candidates.count)])
            let placeholders = String(repeating: "?,", count: chunk.count).dropLast()
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT term FROM vocabulary WHERE term IN (\(placeholders)) AND doc > 0",
                arguments: StatementArguments(chunk)
            )
            for row in rows { found.insert(row["term"]) }
            i += chunkSize
        }
        return Array(found)
    }

    /// Quotes a term as an FTS5 string literal (a single term), escaping
    /// embedded double quotes so a correction is always one token.
    private static func ftsQuote(_ term: String) -> String {
        return "\"" + term.replacingOccurrences(of: "\"", with: "\"\"") + "\""
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
    /// Natural-language dates resolve against `now` (defaults to the
    /// current time; tests pin it).
    /// - Parameters:
    ///   - semanticModel: the embedding model for the semantic half of the
    ///     hybrid merge (decision 0045). nil keeps search keyword-only.
    ///   - semanticEnabled: the off switch for the semantic half; false
    ///     forces keyword-only even with a model registered.
    public func search(
        _ query: String,
        limit: Int = 200,
        offset: Int = 0,
        withSnippets: Bool = false,
        groupByThread: Bool = false,
        now: Date? = nil,
        semanticModel: (any EmbeddingModel)? = nil,
        semanticEnabled: Bool = true
    ) throws -> SearchResults {
        guard let node = try QueryParser.parse(query, now: now) else {
            return SearchResults(hits: [], warnings: [])
        }
        // Stemming (DESIGN 6A, decision 0026): detect the query's language
        // once and expand every text token to its forms.
        let language = Stemming.detectLanguage(query)
        let compiled = try QueryCompiler.compile(node, language: language)
        // Hybrid search (decision 0045): with a model active, the keyword
        // side is fetched from position 0 through `limit + offset` so both
        // sides can be fused and the offset applied to the fused list.
        let model = semanticEnabled ? semanticModel : nil
        let hybrid = model != nil
        let perSide = hybrid ? limit + offset : limit
        let hits = try db.read { db in
            try SearchExecutor.run(
                compiled.root, in: db, limit: perSide,
                offset: hybrid ? 0 : offset,
                withSnippets: withSnippets, groupByThread: groupByThread
            )
        }
        guard let model, let queryVector = model.embed(query) else {
            // Keyword-only (decision 0045): the semantic side can only add
            // hits; with no model, no query embedding, or the off switch
            // set, the answer is exactly the keyword list.
            let final = hybrid ? Array(hits.dropFirst(offset)) : hits
            return SearchResults(hits: final, warnings: compiled.warnings)
        }
        let vectorHits = try db.read { db in
            try VectorIndex.search(
                db, model: model.identifier, query: queryVector, limit: perSide
            )
        }
        let fused = RankFusion.rrf(
            [hits.map(\.messageID), vectorHits.map(\.messageID)], limit: perSide
        )
        var keywordByID = Dictionary(
            hits.map { ($0.messageID, $0) }, uniquingKeysWith: { first, _ in first }
        )
        let semanticOnly = fused.map(\.id).filter { keywordByID[$0] == nil }
        var threadByID: [Int64: Int64] = [:]
        if !semanticOnly.isEmpty {
            // The house idiom for variable IN lists (see the snippet pass
            // above): hand the ids over as JSON and let json_each expand.
            let idsJSON = "[" + semanticOnly.map(String.init).joined(separator: ",") + "]"
            let rows = try db.read { db in
                try Row.fetchAll(
                    db,
                    sql: "SELECT id, threadID FROM message WHERE id IN (SELECT value FROM json_each(?))",
                    arguments: [idsJSON]
                )
            }
            for row in rows {
                let id: Int64 = row["id"]
                let threadID: Int64? = row["threadID"]
                threadByID[id] = threadID
            }
        }
        var finalHits = [SearchHit]()
        finalHits.reserveCapacity(fused.count)
        for entry in fused {
            if let hit = keywordByID.removeValue(forKey: entry.id) {
                finalHits.append(hit)
            } else {
                finalHits.append(
                    SearchHit(
                        messageID: entry.id, threadID: threadByID[entry.id], viaSemantic: true
                    )
                )
            }
        }
        if groupByThread {
            // The executor collapsed the keyword side by thread; the fused
            // list can still hold several hits of one thread, so collapse
            // again with the same key the executor uses.
            var seen = Set<Int64>()
            finalHits = finalHits.filter { hit in
                let key = hit.threadID ?? -hit.messageID
                if seen.contains(key) { return false }
                seen.insert(key)
                return true
            }
        }
        return SearchResults(hits: Array(finalHits.dropFirst(offset)), warnings: compiled.warnings)
    }

    /// The as-you-type search answer (decision 0025): term completions for
    /// the active prefix, the match-set size (the gate), and ranked hits when
    /// the gate passes. The first keystroke returns completions under 50 ms;
    /// full ranked results come once the prefix narrows the match set.
    public struct AsYouTypeResults: Sendable, Equatable {
        public var completions: [TermCompletion]
        public var matchSet: Int
        public var ranked: [SearchHit]

        public init(completions: [TermCompletion], matchSet: Int, ranked: [SearchHit]) {
            self.completions = completions
            self.matchSet = matchSet
            self.ranked = ranked
        }
    }

    /// Parses and runs one as-you-type query (decision 0025). The active
    /// prefix is the last token of the last text clause; completions are
    /// served from the vocabulary. If the match-set size is at or below the
    /// gate threshold, the full ranked search runs and its hits are returned
    /// alongside the completions. A committed query (ending in whitespace, a
    /// quote, or another terminator) runs the ranked search without
    /// completions, as if entered; a malformed in-flight query returns empty
    /// rather than raising, so typing never surfaces an error. Natural
    /// language dates resolve against `now` (defaults to the current time).
    public func searchAsYouType(_ query: String, limit: Int = 200, now: Date? = nil) throws -> AsYouTypeResults {
        guard let node = try? QueryParser.parse(query, now: now) else {
            return AsYouTypeResults(completions: [], matchSet: 0, ranked: [])
        }
        // Stemming (DESIGN 6A, decision 0026): detect the query's language
        // once; both compile paths below expand text tokens to their forms.
        let language = Stemming.detectLanguage(query)
        guard let prefix = Self.activePrefix(of: node), !Self.isCommitted(query) else {
            // No active prefix: the query is committed (it ends in a
            // terminator, so its last term is final) or it has no text
            // clause. Either way the ranked search runs as if the query had
            // been entered; matchSet 0 means "not computed" — callers use
            // `ranked`, not the gate.
            let compiled = try QueryCompiler.compile(node, language: language)
            let hits = try db.read { db in
                try SearchExecutor.run(compiled.root, in: db, limit: limit)
            }
            return AsYouTypeResults(completions: [], matchSet: 0, ranked: hits)
        }
        let completion = try db.read { db in
            try Vocabulary.complete(prefix: prefix, in: db)
        }
        var ranked: [SearchHit] = []
        if completion.matchSet <= Vocabulary.gateThreshold {
            let compiled = try QueryCompiler.compile(node, asYouType: true, language: language)
            ranked = try db.read { db in
                try SearchExecutor.run(compiled.root, in: db, limit: limit)
            }
        }
        return AsYouTypeResults(
            completions: completion.completions,
            matchSet: completion.matchSet,
            ranked: ranked
        )
    }

    /// True when the query ends in a terminator rather than mid-word: the
    /// last term is final, so no completions are offered for it.
    static func isCommitted(_ query: String) -> Bool {
        guard let scalar = query.unicodeScalars.last else { return true }
        return !CharacterSet.alphanumerics.contains(scalar)
    }

    /// The active prefix: the last token of the last text clause in the query
    /// tree, in reading order. nil when the query has no text clause.
    private static func activePrefix(of node: SearchNode) -> String? {
        switch node {
        case .and(let children), .or(let children):
            var last: String? = nil
            for child in children {
                if let prefix = activePrefix(of: child) {
                    last = prefix
                }
            }
            return last
        case .not(let child):
            return activePrefix(of: child)
        case .clause(let clause):
            switch clause {
            case .text(_, let raw), .phrase(_, let raw):
                let tokens = TokenPipeline.tokens(for: raw, field: .body)
                return tokens.last
            default:
                return nil
            }
        }
    }
}
