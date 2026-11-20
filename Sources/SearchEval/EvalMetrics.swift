import Foundation

// The judged relevance set's qrels file (DESIGN 6A, decision 0028). Grades:
// 2 = directly about the query topic, 1 = supportive or brief mention,
// absent = not relevant. Every judgment id refers to a JudgedMessage in
// JudgedTopics.swift / JudgedTopics2.swift.
public struct QrelsFile: Sendable, Decodable {
    public struct Query: Sendable, Decodable {
        public struct Judgment: Sendable, Decodable {
            public var id: String
            public var grade: Int
        }

        public var id: String
        public var text: String
        public var category: String
        public var judgments: [Judgment]
        /// Mechanisms this query needs (e.g. "semantic"). Empty when the
        /// query works with keyword search alone. Queries with a non-empty
        /// list are excluded from the gate aggregate when the mechanism is
        /// not present (decision 0028, decision 0047).
        public var requires: [String]

        public init(id: String, text: String, category: String, judgments: [Judgment], requires: [String] = []) {
            self.id = id
            self.text = text
            self.category = category
            self.judgments = judgments
            self.requires = requires
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try container.decode(String.self, forKey: .id)
            self.text = try container.decode(String.self, forKey: .text)
            self.category = try container.decode(String.self, forKey: .category)
            self.judgments = try container.decodeIfPresent([Judgment].self, forKey: .judgments) ?? []
            self.requires = try container.decodeIfPresent([String].self, forKey: .requires) ?? []
        }

        private enum CodingKeys: String, CodingKey {
            case id, text, category, judgments, requires
        }
    }

    public var version: Int
    public var queries: [Query]

    public static func load() throws -> QrelsFile {
        guard let url = Bundle.module.url(forResource: "qrels", withExtension: "json") else {
            throw EvalError.missingResource("qrels.json")
        }
        return try JSONDecoder().decode(QrelsFile.self, from: Data(contentsOf: url))
    }
}

public enum EvalError: Error, Equatable {
    case missingResource(String)
}

// Ranking metrics for the M2 gate (DESIGN 6A): nDCG@10 with gain
// 2^grade - 1, and recall@50. Both take the grades of the ranked results,
// grade 0 for any returned doc that has no judgment.
public enum EvalMetrics {
    public static func nDCG(at k: Int, gradedResults: [Int], judgedGrades: [Int]) -> Double {
        let dcg = discountedCumulativeGain(gradedResults.prefix(k))
        let ideal = judgedGrades.filter { $0 > 0 }.sorted(by: >).prefix(k)
        let idcg = discountedCumulativeGain(ideal)
        guard idcg > 0 else { return 1 }
        return dcg / idcg
    }

    public static func recall(relevantCount: Int, foundCount: Int) -> Double {
        guard relevantCount > 0 else { return 1 }
        return Double(min(foundCount, relevantCount)) / Double(relevantCount)
    }

    static func discountedCumulativeGain<S: Sequence>(_ grades: S) -> Double where S.Element == Int {
        var dcg = 0.0
        for (index, grade) in grades.enumerated() where grade > 0 {
            dcg += (Double((1 << grade) - 1)) / log2(Double(index + 2))
        }
        return dcg
    }
}
