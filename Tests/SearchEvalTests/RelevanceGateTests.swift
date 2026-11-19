import XCTest
import ArchiveCore
import SearchEval

// The M2 judged relevance gate (DESIGN 6A, decision 0028): the runner
// builds a fresh archive from the judged corpus, runs every qrels query,
// and the gate holds nDCG@10 and recall@50 to their targets and to the
// recorded baseline (a drop beyond 0.02 fails the build).
final class RelevanceGateTests: XCTestCase {
    // Baselines recorded from the first passing run. macOS runs with
    // language detection (decision 0026), Linux without, so the
    // multilingual queries score lower there; each platform holds its own
    // baseline. Update only together with a documented ranking change,
    // never to make a failing build pass.
    private var baselineNDCG10: Double {
        #if canImport(NaturalLanguage)
        0.9910
        #else
        0.9788
        #endif
    }

    private var baselineRecall50: Double {
        #if canImport(NaturalLanguage)
        0.9982
        #else
        0.9778
        #endif
    }

    func testQrelsAreConsistentWithCorpus() throws {
        let qrels = try QrelsFile.load()
        XCTAssertGreaterThanOrEqual(qrels.queries.count, 100)
        var queryIDs = Set<String>()
        for query in qrels.queries {
            XCTAssertTrue(queryIDs.insert(query.id).inserted, "duplicate query \(query.id)")
            XCTAssertFalse(query.text.isEmpty, "\(query.id) has no query text")
            XCTAssertFalse(query.judgments.isEmpty, "\(query.id) has no judgments")
            for judgment in query.judgments {
                XCTAssertTrue(
                    (1...2).contains(judgment.grade),
                    "\(query.id) grades \(judgment.id) at \(judgment.grade)"
                )
            }
        }
        var corpusIDs = Set<String>()
        for message in JudgedCorpus.makeMessages() {
            XCTAssertTrue(
                corpusIDs.insert(message.id).inserted,
                "duplicate corpus id \(message.id)"
            )
        }
        for query in qrels.queries {
            for judgment in query.judgments {
                XCTAssertTrue(
                    corpusIDs.contains(judgment.id),
                    "\(query.id) judges unknown id \(judgment.id)"
                )
            }
        }
    }

    func testMetricsMath() {
        let ideal = 3.0 + 1.0 / log2(3.0)  // grades [2, 1], gain 2^g - 1
        XCTAssertEqual(
            EvalMetrics.nDCG(at: 2, gradedResults: [2, 1], judgedGrades: [2, 1]),
            1.0, accuracy: 1e-12
        )
        XCTAssertEqual(
            EvalMetrics.nDCG(at: 2, gradedResults: [1, 2], judgedGrades: [2, 1]),
            (1.0 + 3.0 / log2(3.0)) / ideal,
            accuracy: 1e-12
        )
        XCTAssertEqual(
            EvalMetrics.nDCG(at: 3, gradedResults: [0, 2, 1], judgedGrades: [2, 1]),
            (3.0 / log2(3.0) + 1.0 / 2.0) / ideal,
            accuracy: 1e-12
        )
        XCTAssertEqual(EvalMetrics.recall(relevantCount: 4, foundCount: 3), 0.75, accuracy: 1e-12)
        XCTAssertEqual(EvalMetrics.recall(relevantCount: 0, foundCount: 0), 1.0, accuracy: 1e-12)
    }

    func testJudgedSetMeetsGate() throws {
        let run = try RelevanceRunner.run(appVersion: "search-eval-tests")
        print("judged set: corpus \(run.corpusSize), mean nDCG@10 \(run.meanNDCG10), mean recall@50 \(run.meanRecall50)")
        print(report(run))
        XCTAssertEqual(run.corpusSize, 410, "expected 150 topical + 260 distractor messages")
        XCTAssertGreaterThanOrEqual(run.meanNDCG10, 0.45, report(run))
        XCTAssertGreaterThanOrEqual(run.meanRecall50, 0.75, report(run))
        XCTAssertGreaterThanOrEqual(
            run.meanNDCG10, baselineNDCG10 - 0.02,
            "nDCG@10 dropped from the recorded baseline\n" + report(run)
        )
        XCTAssertGreaterThanOrEqual(
            run.meanRecall50, baselineRecall50 - 0.02,
            "recall@50 dropped from the recorded baseline\n" + report(run)
        )
    }

    private func report(_ run: RelevanceRun) -> String {
        let worst = run.scores
            .sorted { $0.nDCG10 < $1.nDCG10 }
            .prefix(8)
            .map { score in
                "\(score.queryID) ndcg10=\(String(format: "%.2f", score.nDCG10))"
                    + " recall50=\(String(format: "%.2f", score.recall50))"
                    + " found \(score.foundCount)/\(score.relevantCount)"
                    + " missed=\(score.missed.joined(separator: ","))"
                    + " :: \(score.query)"
            }
            .joined(separator: "\n")
        return "mean nDCG@10 \(run.meanNDCG10), mean recall@50 \(run.meanRecall50)"
            + ", corpus \(run.corpusSize)\n" + worst
    }
}
