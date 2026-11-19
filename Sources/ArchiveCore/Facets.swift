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
        let any = try Int.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM message m WHERE \(predicate.sql))",
            arguments: StatementArguments(predicate.arguments)
        ) ?? 0
        if any == 0, SearchExecutor.hasFallbackableLeaf(compiled.root) {
            predicate = SearchExecutor.predicate(for: compiled.root, useFallbacks: true)
        }
        return predicate
    }
}
