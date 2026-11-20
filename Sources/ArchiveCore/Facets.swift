import ArchiveSearch
import Foundation
import GRDB

/// One value inside an entity facet drill-in: which written form of an
/// entity kind dominates the match set, and how many messages carry it.
public struct EntityValueCount: Sendable, Equatable {
    /// The entity as it was written in the message ("$1,234.56").
    public var value: String
    /// How many messages in the match set carry this value.
    public var count: Int

    public init(value: String, count: Int) {
        self.value = value
        self.count = count
    }
}

/// One bar of the timeline histogram: how many matched messages carry the
/// effective date (dateSent, else dateReceived) inside this year-month.
public struct YearMonthCount: Sendable, Equatable {
    public var year: Int
    public var month: Int
    public var count: Int

    public init(year: Int, month: Int, count: Int) {
        self.year = year
        self.month = month
        self.count = count
    }
}

/// Entity facets (DESIGN 6A, M2): live counts that stand beside the
/// results. A facet answers "what is in this result set" — how many
/// messages carry each entity kind, and which values dominate one kind —
/// so the interface can offer drill-ins without another search round
/// trip. Counts cover the query's full match set, not one result page,
/// and they follow the same zero-hit trigram retry the hits follow, so
/// the facets always describe the set the person is looking at.
extension ArchiveStore {

    /// For each entity kind, how many messages in the query's full match
    /// set carry at least one entity of that kind. Kinds with no matching
    /// messages are absent from the dictionary, not zero. An empty or
    /// malformed query yields an empty dictionary. Natural-language dates
    /// resolve against `now` (defaults to the current time).
    public func entityFacets(matching query: String, now: Date? = nil) throws -> [EntityKind: Int] {
        try db.read { db in
            let predicate = try facetPredicate(matching: query, in: db, now: now)
            let sql = """
                SELECT e.kind AS k, COUNT(DISTINCT e.messageID) AS n
                FROM message_entity e
                WHERE e.messageID IN (SELECT m.id FROM message m WHERE \(predicate.sql))
                GROUP BY e.kind
                """
            var counts: [EntityKind: Int] = [:]
            for row in try Row.fetchAll(
                db, sql: sql, arguments: StatementArguments(predicate.arguments)
            ) {
                guard let raw: String = row["k"], let kind = EntityKind(rawValue: raw) else {
                    continue
                }
                counts[kind] = row["n"] ?? 0
            }
            return counts
        }
    }

    /// For one entity kind, the values carried by the query's full match
    /// set, ranked by how many messages carry each value and then by
    /// value, so the ranking is deterministic. At most `limit` values
    /// come back; the written form is the display value.
    /// Natural-language dates resolve against `now` (defaults to the
    /// current time).
    public func entityValues(
        _ kind: EntityKind, matching query: String, limit: Int = 20, now: Date? = nil
    ) throws -> [EntityValueCount] {
        try db.read { db in
            let predicate = try facetPredicate(matching: query, in: db, now: now)
            let sql = """
                SELECT e.value AS v, COUNT(DISTINCT e.messageID) AS n
                FROM message_entity e
                WHERE e.kind = ? AND e.messageID IN (SELECT m.id FROM message m WHERE \(predicate.sql))
                GROUP BY e.value
                ORDER BY n DESC, v ASC
                LIMIT \(max(0, limit))
                """
            return try Row.fetchAll(
                db,
                sql: sql,
                arguments: StatementArguments([kind.rawValue] + predicate.arguments)
            )
            .map { row in
                EntityValueCount(value: row["v"] ?? "", count: row["n"] ?? 0)
            }
        }
    }

    /// The timeline histogram (DESIGN 6A): for the query's full match set,
    /// how many messages carry each year-and-month of their effective date
    /// (dateSent, else dateReceived), ascending chronologically. Messages
    /// with no usable date are counted in `undated` and appear in no bucket.
    /// The buckets cover the whole match set, not one result page, and
    /// follow the same zero-hit fallback ladder the hits follow (trigram
    /// retry, then the one-edit typo rescue), so the histogram always
    /// describes the set the person is looking at. One indexed scan, under
    /// the 300 ms faceted-counts budget. Natural-language dates resolve
    /// against `now` (defaults to the current time).
    public func timelineHistogram(
        matching query: String, now: Date? = nil
    ) throws -> (buckets: [YearMonthCount], undated: Int) {
        try db.read { db in
            let predicate = try facetPredicate(matching: query, in: db, now: now)
            // Dates are stored as fixed UTC ISO strings (Timestamp.string),
            // so the first seven characters are the year and month.
            let bucketSQL = """
                SELECT substr(d, 1, 7) AS ym, COUNT(*) AS n
                FROM (
                    SELECT COALESCE(m.dateSent, m.dateReceived) AS d
                    FROM message m WHERE \(predicate.sql)
                )
                WHERE d IS NOT NULL AND length(d) >= 7
                GROUP BY ym ORDER BY ym ASC
                """
            let args = StatementArguments(predicate.arguments)
            var buckets: [YearMonthCount] = []
            for row in try Row.fetchAll(db, sql: bucketSQL, arguments: args) {
                let ym: String = row["ym"] ?? ""
                let parts = ym.split(separator: "-")
                guard parts.count == 2, let year = Int(parts[0]), let month = Int(parts[1]) else {
                    continue
                }
                buckets.append(YearMonthCount(year: year, month: month, count: row["n"] ?? 0))
            }
            let undated = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM (
                        SELECT COALESCE(m.dateSent, m.dateReceived) AS d
                        FROM message m WHERE \(predicate.sql)
                    )
                    WHERE d IS NULL OR length(d) < 7
                    """,
                arguments: args
            ) ?? 0
            return (buckets, undated)
        }
    }

    /// The WHERE clause selecting the query's match set over `message m`,
    /// mirroring the hits: the exact tree first, and when it matched
    /// nothing and the tree can fall back, the trigram-fallback tree — so
    /// facet counts describe the same set the hits come from.
    private func facetPredicate(
        matching query: String, in db: Database, now: Date? = nil
    ) throws -> (sql: String, arguments: [String]) {
        guard let node = try QueryParser.parse(query, now: now) else {
            return ("1 = 0", [])
        }
        let language = Stemming.detectLanguage(query)
        let compiled = try QueryCompiler.compile(node, language: language)
        var predicate = SearchExecutor.predicate(for: compiled.root)
        var any = try Int.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM message m WHERE \(predicate.sql))",
            arguments: StatementArguments(predicate.arguments)
        ) ?? 0
        if any == 0, SearchExecutor.hasFallbackableLeaf(compiled.root) {
            predicate = SearchExecutor.predicate(for: compiled.root, useFallbacks: true)
            any = try Int.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM message m WHERE \(predicate.sql))",
                arguments: StatementArguments(predicate.arguments)
            ) ?? 0
        }
        // Third rung, mirroring the ranked path (decision 0035): when even
        // the trigram fallback found nothing and the query is a single-term
        // text leaf, facets describe the typo-rescued set, so the counts on
        // screen always belong to the hits on screen.
        if any == 0, case .fts(let leaf) = compiled.root,
           let rescue = try SearchExecutor.typoRescueExpression(for: leaf, in: db) {
            predicate = (
                "m.id IN (SELECT rowid FROM message_text WHERE message_text MATCH ?)",
                [rescue]
            )
        }
        return predicate
    }
}
