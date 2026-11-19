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
}

// The full run: per-query scores plus the two headline means the M2 gate
// compares against (DESIGN 6A: nDCG@10 >= 0.45, recall@50 >= 0.75).
public struct RelevanceRun: Sendable {
    public var scores: [RelevanceQueryScore]
    public var meanNDCG10: Double
    public var meanRecall50: Double
    public var corpusSize: Int
}

public enum RelevanceRunner {
    /// Ingests the judged corpus into a fresh archive and runs every qrels
    /// query, scoring nDCG@10 and recall@50 (decision 0028). With no
    /// directory the run creates and removes its own temporary archive;
    /// otherwise the caller owns the directory.
    public static func run(appVersion: String, directory: URL? = nil) throws -> RelevanceRun {
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

        let qrels = try QrelsFile.load()
        var scores: [RelevanceQueryScore] = []
        scores.reserveCapacity(qrels.queries.count)
        for judged in qrels.queries {
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
            for hit in results.hits {
                let id = idsByRowID[hit.messageID]
                let grade = id.flatMap { gradesByID[$0] } ?? 0
                gradedResults.append(grade)
                if grade > 0 { foundCount += 1 }
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
                missed: missed
            ))
        }

        guard !scores.isEmpty else {
            return RelevanceRun(
                scores: [], meanNDCG10: 0, meanRecall50: 0, corpusSize: messages.count
            )
        }
        let meanNDCG10 = scores.map { $0.nDCG10 }.reduce(0, +) / Double(scores.count)
        let meanRecall50 = scores.map { $0.recall50 }.reduce(0, +) / Double(scores.count)
        return RelevanceRun(
            scores: scores,
            meanNDCG10: meanNDCG10,
            meanRecall50: meanRecall50,
            corpusSize: messages.count
        )
    }
}
