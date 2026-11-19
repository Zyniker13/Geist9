// Text index versioning (DESIGN 6A, M2.1): the text pipeline evolves — the
// trigram index in M2.1, stemming in M2.2, attachment extraction in M2.3.
// Every message records which version indexed it, and rows older than the
// current version are re-indexed here from their stored bytes. The stored
// bytes are never rewritten; only the text tables change.

import ArchiveSearch
import Foundation
import GRDB

/// Which text-pipeline version indexed a message. Bump `current` whenever
/// indexing changes what a query can find; every store then converges by
/// backfill, not by rewriting anything.
enum TextIndexVersion {
    /// M1: tokenized FTS5 columns only (no stemming, no trigram).
    static let v1 = 1
    /// M2.1: adds the trigram index over raw folded text.
    static let v2 = 2
    static var current: Int { v2 }
}

extension ArchiveStore {
    /// Re-indexes every message whose text index is older than the current
    /// pipeline version, from the stored bytes. Each message commits on its
    /// own, so an interrupted run leaves the rest for the next pass, and a
    /// large archive never holds one huge write transaction. Returns the
    /// number of messages processed.
    @discardableResult
    public func reindexOutdated(limit: Int = 100_000) throws -> Int {
        var processed = 0
        while processed < limit {
            let batch: [(id: Int64, hash: Data)] = try db.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                    SELECT id, hash FROM message
                    WHERE textVersion IS NULL OR textVersion < ?
                    LIMIT 256
                    """,
                    arguments: [TextIndexVersion.current]
                )
                .map { row in
                    (id: (row["id"] as Int64?) ?? 0, hash: (row["hash"] as Data?) ?? Data())
                }
            }
            if batch.isEmpty { break }
            for item in batch {
                try reindexMessage(id: item.id, hash: item.hash)
                processed += 1
            }
        }
        return processed
    }

    /// Re-indexes one message: read the stored bytes, parse, rebuild both
    /// text tables, stamp the version. The message row itself (hash, size,
    /// headers) is never rewritten; a message whose bytes cannot be read or
    /// parsed today is skipped and left for a future pipeline version.
    func reindexMessage(id: Int64, hash: Data) throws {
        guard hash.count == 32, id > 0 else { return }
        let url = fileURL(for: MessageHash(bytes: hash))
        guard let data = try? Data(contentsOf: url) else { return }
        let parsed = MailBridge.parse(for: data)
        let tokens = SearchTokens(IngestedMessage(
            record: parsed.record,
            data: data,
            memberships: [],
            attachments: parsed.attachments,
            searchText: parsed.searchText
        ))
        try db.write { db in
            try db.execute(sql: "DELETE FROM message_text WHERE rowid = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM message_trigram WHERE rowid = ?", arguments: [id])
            try Self.indexSearchText(tokens, messageRowID: id, db: db)
            try db.execute(
                sql: "UPDATE message SET textVersion = ? WHERE id = ?",
                arguments: [TextIndexVersion.current, id]
            )
        }
    }
}
