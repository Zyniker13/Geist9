@testable import ArchiveSearch
import XCTest

/// The as-you-type compile mode (decision 0025): while typing, the last
/// text or phrase clause in reading order compiles its final token as an
/// FTS5 prefix match, so the ranked path covers the word being typed; every
/// earlier token stays exact. A committed compile (the default) never marks
/// a prefix.
///
/// Decision 0026 layering: each token's folded form searches the original
/// columns; its stem forms search the separate stem columns, so phrase
/// adjacency survives on the original stream.
final class AsYouTypeCompilerTests: XCTestCase {
    private func collect(_ node: CompiledNode, into out: inout [String]) {
        switch node {
        case .fts(let leaf): out.append(leaf.expression)
        case .filter: break
        case .and(let children), .or(let children):
            for child in children { collect(child, into: &out) }
        case .not(let child): collect(child, into: &out)
        }
    }

    private func expressions(_ query: String, asYouType: Bool = false) throws -> [String] {
        let node = try XCTUnwrap(QueryParser.parse(query), "parse(\(query))")
        let compiled = try QueryCompiler.compile(node, asYouType: asYouType)
        var out: [String] = []
        collect(compiled.root, into: &out)
        return out
    }

    func testPrefixModeMarksTheLastToken() throws {
        // "kickoff" stems to itself, so its group repeats the folded form on
        // the stem columns; "budget" is the prefix being typed: the folded
        // prefix on the original columns plus the stems of its own prefixes
        // ("bud" -> "bud", "budg" -> "budg") on the stem columns, so
        // "budget" also finds messages indexed under a shorter stem.
        XCTAssertEqual(
            try expressions("kickoff budget", asYouType: true),
            ["((\(QueryCompiler.bareColumns) : kickoff"
                + " OR {subject_stem body_stem} : kickoff)"
                + " AND (\(QueryCompiler.bareColumns) : budget*"
                + " OR {subject_stem body_stem} : (budget* OR bud* OR budg*)))"])
    }

    func testCommittedCompileNeverMarksAPrefix() throws {
        XCTAssertEqual(
            try expressions("kickoff budget"),
            ["((\(QueryCompiler.bareColumns) : kickoff"
                + " OR {subject_stem body_stem} : kickoff)"
                + " AND (\(QueryCompiler.bareColumns) : budget"
                + " OR {subject_stem body_stem} : budget))"])
        XCTAssertEqual(
            try expressions("kickoff budget", asYouType: false),
            ["((\(QueryCompiler.bareColumns) : kickoff"
                + " OR {subject_stem body_stem} : kickoff)"
                + " AND (\(QueryCompiler.bareColumns) : budget"
                + " OR {subject_stem body_stem} : budget))"])
        // Decision 0026: the folded phrase stays adjacent on the original
        // columns; the per-language stem phrase searches the stem columns
        // ("looks" stems to "look", so messages indexed as "budget look fi"
        // also match).
        XCTAssertEqual(
            try expressions("\"budget looks fi\""),
            ["(\(QueryCompiler.phraseColumns) : \"budget looks fi\""
                + " OR {subject_stem body_stem quoted_stem} : \"budget look fi\")"])
    }

    func testSingleTokenPrefix() throws {
        // The folded prefix on the original columns; the stem-column
        // candidates are the prefix itself plus the stem of its own
        // 3-letter prefix ("kic" -> "kic"; "kick" stems to itself).
        XCTAssertEqual(
            try expressions("kick", asYouType: true),
            ["(\(QueryCompiler.bareColumns) : kick*"
                + " OR {subject_stem body_stem} : (kick* OR kic*))"])
    }

    func testPrefixMarksOnlyTheLastClause() throws {
        XCTAssertEqual(
            try expressions("subject:kick budget", asYouType: true),
            ["({subject} : kick OR {subject_stem} : kick)",
             "(\(QueryCompiler.bareColumns) : budget*"
                + " OR {subject_stem body_stem} : (budget* OR bud* OR budg*))"])
    }

    func testNegatedEarlierTermStaysExactWhileTheLastGetsThePrefix() throws {
        XCTAssertEqual(
            try expressions("-kick budget", asYouType: true),
            [
                "(\(QueryCompiler.bareColumns) : kick"
                    + " OR {subject_stem body_stem} : kick)",
                "(\(QueryCompiler.bareColumns) : budget*"
                    + " OR {subject_stem body_stem} : (budget* OR bud* OR budg*))",
            ])
    }

    func testPhrasePrefixMarkerSitsOutsideTheQuotes() throws {
        // FTS5 prefixes a phrase by ending the quoted string first: "b* fi"*.
        // The folded phrase and its per-language stem phrase both carry the
        // marker.
        XCTAssertEqual(
            try expressions("\"budget looks fi\"", asYouType: true),
            ["(\(QueryCompiler.phraseColumns) : \"budget looks fi\"*"
                + " OR {subject_stem body_stem quoted_stem} : \"budget look fi\"*)"])
    }

    func testPhraseBeforeTheFinalTextGetsNoMarker() throws {
        // Decision 0026: the earlier phrase keeps the folded adjacency on
        // the original columns and adds its stem phrase on the stem columns
        // ("meeting" -> "meet"); only the final text clause carries the
        // prefix marker.
        XCTAssertEqual(
            try expressions("\"kickoff meeting\" budget", asYouType: true),
            [
                "(\(QueryCompiler.phraseColumns) : \"kickoff meeting\""
                    + " OR {subject_stem body_stem quoted_stem} : \"kickoff meet\")",
                "(\(QueryCompiler.bareColumns) : budget*"
                    + " OR {subject_stem body_stem} : (budget* OR bud* OR budg*))",
            ])
    }

    func testQueriesWithoutTextClausesCompileUnchanged() throws {
        XCTAssertEqual(
            try expressions("from:alice", asYouType: true),
            try expressions("from:alice"))
    }
}
