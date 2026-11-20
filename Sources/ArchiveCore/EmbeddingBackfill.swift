import GRDB

/// Fills in vectors for messages that lack one for a given embedding
/// model (decision 0045, slice 2). The text basis is the subject plus the
/// first 1,000 characters of the body: enough for topic similarity,
/// bounded so one pass stays predictable. A pass is resumable — it walks
/// messages oldest-first and never rewrites a vector that already exists,
/// so interrupting it loses no work and the next pass continues where it
/// stopped. Rows the model cannot embed are skipped and simply remain
/// unindexed for that model.
public enum EmbeddingBackfill {
    /// The text whose embedding is stored for a message: the subject, then
    /// a space, then the opening of the body text. Public so callers and
    /// tests can recompute exactly what was embedded.
    public static func documentText(subject: String, body: String) -> String {
        let opening = String(body.prefix(1_000))
        if subject.isEmpty { return opening }
        if opening.isEmpty { return subject }
        return subject + " " + opening
    }

    /// Embeds at most `maxMessages` messages that have no vector for this
    /// model, oldest first, and returns the count written.
    @discardableResult
    public static func run(
        _ store: ArchiveStore, model: any EmbeddingModel, maxMessages: Int = .max
    ) throws -> Int {
        guard maxMessages > 0 else { return 0 }
        let candidates: [(id: Int64, subject: String, body: String)] = try store.db.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT m.id, m.subject, t.body FROM message m
                LEFT JOIN message_embedding e
                  ON e.id = m.id AND e.model = ?
                LEFT JOIN message_text t ON t.rowid = m.id
                WHERE e.id IS NULL
                ORDER BY m.id
                LIMIT ?
                """,
                arguments: [model.identifier, maxMessages]
            ).map { row in
                let subject: String? = row["subject"]
                let body: String? = row["body"]
                return (id: row["id"] as Int64, subject: subject ?? "", body: body ?? "")
            }
        }
        var written = 0
        for candidate in candidates {
            guard let vector = model.embed(
                documentText(subject: candidate.subject, body: candidate.body)
            ) else { continue }
            guard vector.count == model.dimension else {
                throw VectorIndexError.dimensionMismatch(
                    expected: model.dimension, got: vector.count
                )
            }
            try store.db.write { db in
                try VectorIndex.upsert(
                    db, messageID: candidate.id, model: model.identifier, vector: vector
                )
            }
            written += 1
        }
        return written
    }
}
