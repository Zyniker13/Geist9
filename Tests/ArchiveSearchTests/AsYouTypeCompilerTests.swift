@testable import ArchiveSearch
import XCTest

/// The as-you-type compile mode (decision 0025): while typing, the last
/// text or phrase clause in reading order compiles its final token as an
/// FTS5 prefix match, so the ranked path covers the word being typed; every
/// earlier token stays exact. A committed compile (the default) never marks
/// a prefix.
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
        XCTAssertEqual(
            try expressions("kickoff budget", asYouType: true),
            ["\(QueryCompiler.bareColumns) : kickoff AND budget*"])
    }

    func testCommittedCompileNeverMarksAPrefix() throws {
        XCTAssertEqual(
            try expressions("kickoff budget"),
            ["\(QueryCompiler.bareColumns) : kickoff AND budget"])
        XCTAssertEqual(
            try expressions("kickoff budget", asYouType: false),
            ["\(QueryCompiler.bareColumns) : kickoff AND budget"])
        XCTAssertEqual(
            try expressions("\"budget looks fi\""),
            ["\(QueryCompiler.phraseColumns) : \"budget looks fi\""])
    }

    func testSingleTokenPrefix() throws {
        XCTAssertEqual(
            try expressions("kick", asYouType: true),
            ["\(QueryCompiler.bareColumns) : kick*"])
    }

    func testPrefixMarksOnlyTheLastClause() throws {
        XCTAssertEqual(
            try expressions("subject:kick budget", asYouType: true),
            ["{subject} : kick", "\(QueryCompiler.bareColumns) : budget*"])
    }

    func testNegatedEarlierTermStaysExactWhileTheLastGetsThePrefix() throws {
        XCTAssertEqual(
            try expressions("-kick budget", asYouType: true),
            ["\(QueryCompiler.bareColumns) : kick", "\(QueryCompiler.bareColumns) : budget*"])
    }

    func testPhrasePrefixMarkerSitsOutsideTheQuotes() throws {
        // FTS5 prefixes a phrase by ending the quoted string first: "b* fi"*.
        XCTAssertEqual(
            try expressions("\"budget looks fi\"", asYouType: true),
            ["\(QueryCompiler.phraseColumns) : \"budget looks fi\"*"])
    }

    func testPhraseBeforeTheFinalTextGetsNoMarker() throws {
        XCTAssertEqual(
            try expressions("\"kickoff meeting\" budget", asYouType: true),
            [
                "\(QueryCompiler.phraseColumns) : \"kickoff meeting\"",
                "\(QueryCompiler.bareColumns) : budget*",
            ])
    }

    func testQueriesWithoutTextClausesCompileUnchanged() throws {
        XCTAssertEqual(
            try expressions("from:alice", asYouType: true),
            try expressions("from:alice"))
    }
}
