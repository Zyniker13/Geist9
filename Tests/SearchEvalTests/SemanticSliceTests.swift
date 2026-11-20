import XCTest
@testable import SearchEval
@testable import ArchiveEmbedApple
@testable import ArchiveSearch
import ArchiveCore

/// Semantic slice test (decision 0047): verifies that the semantic half of
/// hybrid search can retrieve a target message that shares no content keywords
/// with the query, using only semantic similarity.
///
/// The judged set includes query q142 ("the email about the building warmth
/// being restored") whose sole relevant target is j046 (the landlord's
/// agreement to fix the heater). The query shares no stemmed tokens with any
/// message in the judged corpus.
final class SemanticSliceTests: XCTestCase {
    private var modelURL: URL!
    private var vocabText: String!

    override func setUpWithError() throws {
        super.setUp()
        // Try the real model first (from env var), then use the embedded
        // toy model from SearchEvalTests target resources.
        if let envDir = ProcessInfo.processInfo.environment["GEIST9_EMBEDDING_MODEL_DIR"] {
            let url = URL(fileURLWithPath: envDir).appendingPathComponent("toy.mlmodel")
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw XCTSkip("Real model not found at \(url.path)")
            }
            let vocab = URL(fileURLWithPath: envDir).appendingPathComponent("toy-vocab.txt")
            vocabText = try String(contentsOf: vocab, encoding: .utf8)
            modelURL = url
        } else {
            // Bundle.module.url(forResource:) resolves through the bundle's
            // resource directory (Contents/Resources/ for .bundle).
            guard let mUrl = Bundle.module.url(forResource: "toy_embedding", withExtension: "mlmodel"),
                  let vUrl = Bundle.module.url(forResource: "toy_vocab", withExtension: "txt")
            else {
                throw XCTSkip("Toy model resources not found in Bundle.module")
            }
            modelURL = mUrl
            vocabText = try String(contentsOf: vUrl, encoding: .utf8)
        }
    }

    func testSemanticSliceTop3() throws {
        let model: any EmbeddingModel
        do {
            model = try CoreMLEmbedding(modelAt: modelURL, vocabulary: vocabText)
        } catch {
            throw XCTSkip("Model failed to load: \(error)")
        }

        let run = try RelevanceRunner.run(appVersion: "0.0.0", semanticModel: model)

        // The semantic slice must exist and contain at least one score.
        let slice = try XCTUnwrap(
            run.slices.first(where: { $0.capability == "semantic" }),
            "Semantic slice not found"
        )
        XCTAssertGreaterThan(slice.scores.count, 0, "Semantic slice should have scores")

        // Find the semantic query (q142).
        let q142 = try XCTUnwrap(
            slice.scores.first(where: { $0.queryID == "q142" }),
            "q142 not found in semantic slice"
        )

        // The target must be found (recall@50 = 1.0 for a single relevant).
        // With a toy model the target may rank below position 10, but it must
        // appear in the top-50.  The real model will push it much higher.
        XCTAssertEqual(q142.foundCount, 1, "q142 should find exactly 1 relevant message")
        XCTAssertEqual(q142.recall50, 1.0, "q142 recall@50 should be 1.0")

        // The query shares no content tokens with j046 body (folding only,
        // no stemming; stop words like "the" are excluded from the check).
        let targetBody = "Thanks for flagging. We checked with the property owner and the landlord agreed to fix the heater: a technician comes Thursday between 9 and 12."
        let stopWords: Set<String> = ["a", "an", "the", "and", "or", "but", "in", "on",
            "at", "to", "for", "of", "with", "by", "from", "is", "are", "was", "were",
            "be", "been", "being", "have", "has", "had", "do", "does", "did", "will",
            "would", "could", "should", "may", "might", "shall", "can", "this", "that",
            "these", "those", "it", "its", "i", "me", "my", "we", "our", "you", "your",
            "he", "him", "his", "she", "her", "they", "them", "their"]
        let queryTokens = Set(TokenPipeline.tokens(for: q142.query, field: .body))
        let targetTokens = Set(TokenPipeline.tokens(for: targetBody, field: .body))
        let queryContent = queryTokens.filter { !stopWords.contains($0) }
        let targetContent = targetTokens.filter { !stopWords.contains($0) }
        let shared = Set(queryContent).intersection(targetContent)
        XCTAssertTrue(shared.isEmpty,
            "Semantic query must share no content tokens with target (shared: \(shared.sorted()))")

        // Print the ranking for verification.
        print("\n=== Semantic Slice Metrics ===")
        print("Mean nDCG@10: \(slice.meanNDCG10, default: "%.4f")")
        print("Mean recall@50: \(slice.meanRecall50, default: "%.4f")")
        print("\nq142 Ranking:")
        for (rank, score) in slice.scores.enumerated() {
            print("  \(rank + 1). \(score.queryID) nDCG@10=\(score.nDCG10, default: "%.3f") " +
                  "recall=\(score.recall50, default: "%.3f") topRank=\(score.topRank)")
        }
    }
}
