import Foundation
import ArchiveCore

// One scored query from the judged set (decision 0028).
public struct RelevanceQueryScore: Sendable {
    public var queryID: String
    public var query: String
    public var category: String
    public var nDCG10: Double
    public var recall50: Double
    public var relevantCount: Int
    public var foundCount: Int
    public var missed: [String]
    /// Rank (1-based) of the best relevant message in the results, or 0 when
    /// none of the judged messages were found. Useful for top-N assertions.
    public var topRank: Int
}

// A capability-gated slice (decision 0028, decision 0047).
public struct RelevanceSlice: Sendable {
    public var capability: String
    public var scores: [RelevanceQueryScore]
    public var meanNDCG10: Double
    public var meanRecall50: Double
}

// The full run: per-query scores plus the two headline means the M2 gate
// compares against (DESIGN 6A: nDCG@10 >= 0.45, recall@50 >= 0.75).
public struct RelevanceRun: Sendable {
    public var scores: [RelevanceQueryScore]
    public var meanNDCG10: Double
    public var meanRecall50: Double
    public var corpusSize: Int
    /// Capability-gated slices (decision 0028, decision 0047). When the
    /// mechanism is available the slice is evaluated; otherwise it is
    /// logged but does not gate the build.
    public var slices: [RelevanceSlice]
}

public enum RelevanceRunner {
    /// Ingests the judged corpus into a fresh archive and runs every qrels
    /// query, scoring nDCG@10 and recall@50 (decision 0028). With no
    /// directory the run creates and removes its own temporary archive;
    /// otherwise the caller owns the directory.
    /// - Parameters:
    ///   - appVersion: the app version string (used for archive identification).
    ///   - semanticModel: an embedding model for the semantic half of hybrid
    ///     search. When present, queries with `requires: ["semantic"]` run
    ///     with the hybrid path and their scores are recorded in the
    ///     `semanticSlice`; when absent they are excluded from the gate
    ///     aggregate and logged (decision 0028, decision 0047).
    ///   - directory: optional directory for the archive.
    public static func run(
        appVersion: String,
        semanticModel: (any EmbeddingModel)? = nil,
        directory: URL? = nil
    ) throws -> RelevanceRun {
        let archiveURL = directory ?? URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("geist9-eval-" + UUID().uuidString)
        let ownsDirectory = directory == nil
        defer {
            if ownsDirectory {
                try? FileManager.default.removeItem(at: archiveURL)
            }
        }

        let store = try ArchiveStore.create(at: archiveURL, appVersion: appVersion)
        let account = AccountIdentity(
            email: "alice@example.com",
            displayName: "Alice",
            providerKind: "import"
        )

        let messages = JudgedCorpus.makeMessages()
        let rawMessages = JudgedCorpus.makeRFC822()
        var idsByRowID: [Int64: String] = [:]
        idsByRowID.reserveCapacity(messages.count)
        for (message, raw) in zip(messages, rawMessages) {
            let data = Data(raw.utf8)
            let parsed = MailBridge.parse(for: data)
            let ingested = IngestedMessage(
                record: parsed.record,
                data: data,
                memberships: [Membership(mailbox: message.mailbox)],
                labels: parsed.gmailLabels.map { LabelName(name: $0) },
                attachments: parsed.attachments,
                providerThreadID: parsed.gmailThreadID,
                searchText: parsed.searchText
            )
            switch try store.ingest(ingested, into: account) {
            case .created(let rowID): idsByRowID[rowID] = message.id
            case .duplicate(let rowID): idsByRowID[rowID] = message.id
            }
        }

        // Embed the judged corpus so the vector index can serve semantic search.
        if let semanticModel = semanticModel {
            try EmbeddingBackfill.run(store, model: semanticModel)
        }

        let qrels = try QrelsFile.load()

        // Capability gating (decision 0028, decision 0047): the semantic
        // slice requires an embedding model. Queries with requires=[]
        // always join the gate aggregate; queries with requires=["semantic"]
        // join the semantic slice when a model is present, otherwise they
        // are excluded from the gate and logged.
        let hasSemantic = semanticModel != nil
        let gateQueries = qrels.queries.filter { q in
            q.requires.allSatisfy { cap in
                cap == "semantic" ? hasSemantic : true
            }
        }
        let semanticQueries = qrels.queries.filter { $0.requires.contains("semantic") }

        var scores: [RelevanceQueryScore] = []
        scores.reserveCapacity(gateQueries.count)
        for judged in gateQueries {
            // Gate queries run keyword-only (decision 0047): the baseline
            // must not change when a model is present.
            let results = try store.search(judged.text, limit: 50)
            let gradesByID = Dictionary(
                judged.judgments.map { ($0.id, $0.grade) },
                uniquingKeysWith: { current, _ in current }
            )
            let relevantIDs = Set(
                judged.judgments.filter { $0.grade > 0 }.map { $0.id }
            )
            var gradedResults: [Int] = []
            var foundCount = 0
            var topRank = 0
            for (rank, hit) in results.hits.enumerated() {
                let id = idsByRowID[hit.messageID]
                let grade = id.flatMap { gradesByID[$0] } ?? 0
                gradedResults.append(grade)
                if grade > 0 {
                    foundCount += 1
                    if topRank == 0 { topRank = rank + 1 }
                }
            }
            let missed = relevantIDs.subtracting(
                results.hits.compactMap { idsByRowID[$0.messageID] }
            ).sorted()
            let ndcg = EvalMetrics.nDCG(
                at: 10,
                gradedResults: gradedResults,
                judgedGrades: judged.judgments.map { $0.grade }
            )
            let recall = EvalMetrics.recall(
                relevantCount: relevantIDs.count,
                foundCount: foundCount
            )
            scores.append(RelevanceQueryScore(
                queryID: judged.id,
                query: judged.text,
                category: judged.category,
                nDCG10: ndcg,
                recall50: recall,
                relevantCount: relevantIDs.count,
                foundCount: foundCount,
                missed: missed,
                topRank: topRank
            ))
        }

        // Semantic slice (decision 0047): run with the hybrid path.
        var slices: [RelevanceSlice] = []
        if hasSemantic && !semanticQueries.isEmpty {
            var sliceScores: [RelevanceQueryScore] = []
            for judged in semanticQueries {
                let results = try store.search(
                    judged.text,
                    limit: 50,
                    semanticModel: semanticModel
                )
                let gradesByID = Dictionary(
                    judged.judgments.map { ($0.id, $0.grade) },
                    uniquingKeysWith: { current, _ in current }
                )
                let relevantIDs = Set(
                    judged.judgments.filter { $0.grade > 0 }.map { $0.id }
                )
                var gradedResults: [Int] = []
                var foundCount = 0
                var topRank = 0
                for (rank, hit) in results.hits.enumerated() {
                    let id = idsByRowID[hit.messageID]
                    let grade = id.flatMap { gradesByID[$0] } ?? 0
                    gradedResults.append(grade)
                    if grade > 0 {
                        foundCount += 1
                        if topRank == 0 { topRank = rank + 1 }
                    }
                }
                let missed = relevantIDs.subtracting(
                    results.hits.compactMap { idsByRowID[$0.messageID] }
                ).sorted()
                let ndcg = EvalMetrics.nDCG(
                    at: 10,
                    gradedResults: gradedResults,
                    judgedGrades: judged.judgments.map { $0.grade }
                )
                let recall = EvalMetrics.recall(
                    relevantCount: relevantIDs.count,
                    foundCount: foundCount
                )
                sliceScores.append(RelevanceQueryScore(
                    queryID: judged.id,
                    query: judged.text,
                    category: judged.category,
                    nDCG10: ndcg,
                    recall50: recall,
                    relevantCount: relevantIDs.count,
                    foundCount: foundCount,
                    missed: missed,
                    topRank: topRank
                ))
            }
            let meanNDCG = sliceScores.map(\.nDCG10).reduce(0, +) / Double(sliceScores.count)
            let meanRecall = sliceScores.map(\.recall50).reduce(0, +) / Double(sliceScores.count)
            slices.append(RelevanceSlice(
                capability: "semantic",
                scores: sliceScores,
                meanNDCG10: meanNDCG,
                meanRecall50: meanRecall
            ))
        }

        guard !scores.isEmpty else {
            return RelevanceRun(
                scores: [], meanNDCG10: 0, meanRecall50: 0,
                corpusSize: messages.count, slices: slices
            )
        }
        let meanNDCG10 = scores.map { $0.nDCG10 }.reduce(0, +) / Double(scores.count)
        let meanRecall50 = scores.map { $0.recall50 }.reduce(0, +) / Double(scores.count)
        return RelevanceRun(
            scores: scores,
            meanNDCG10: meanNDCG10,
            meanRecall50: meanRecall50,
            corpusSize: messages.count,
            slices: slices
        )
    }
}
