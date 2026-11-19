import ArchiveSearch
import XCTest

/// The compiler's shapes (DESIGN 6A): a plain multi-word text query is ONE
/// text leaf so it runs as one ranked FTS5 MATCH — not an AND of per-word
/// leaves, which would drop ranking and take the slow predicate path.
final class CompilerTests: XCTestCase {
    private func leaf(_ query: String) throws -> FTSLeaf {
        let node = try QueryParser.parse(query)
        let compiled = try QueryCompiler.compile(node!)
        guard case .fts(let leaf) = compiled.root else {
            XCTFail("expected a single fts leaf for \(query), got \(compiled.root)")
            throw QueryError.emptyGroup
        }
        return leaf
    }

    func testAdjacentBareTermsMergeIntoOneLeaf() throws {
        let leaf = try leaf("hutopuza capu")
        XCTAssertEqual(leaf.expression, "{subject from_name from_addr recipients body attachments} : hutopuza AND capu")
        XCTAssertNotNil(leaf.trigramFallback)
    }

    func testThreeTermsMergeIntoOneLeaf() throws {
        let leaf = try leaf("hutopuza capu zizo")
        XCTAssertEqual(leaf.expression, "{subject from_name from_addr recipients body attachments} : hutopuza AND capu AND zizo")
    }

    func testSingleTermStaysOneLeaf() throws {
        let leaf = try leaf("hutopuza")
        XCTAssertEqual(leaf.expression, "{subject from_name from_addr recipients body attachments} : hutopuza")
    }

    func testPhraseBreaksTheRun() throws {
        // "big budget" notes: the phrase keeps its own leaf (it reaches the
        // quoted column); the trailing bare term runs alone.
        let node = try QueryParser.parse("\"big budget\" notes")
        let compiled = try QueryCompiler.compile(node!)
        guard case .and(let children) = compiled.root, children.count == 2 else {
            XCTFail("expected AND of phrase and term, got \(compiled.root)")
            return
        }
        guard case .fts(let phraseLeaf) = children[0] else {
            XCTFail("expected phrase leaf first, got \(children[0])")
            return
        }
        XCTAssertTrue(phraseLeaf.expression.contains("big budget"))
        guard case .fts(let termLeaf) = children[1] else {
            XCTFail("expected text leaf second, got \(children[1])")
            return
        }
        XCTAssertEqual(termLeaf.expression, "{subject from_name from_addr recipients body attachments} : notes")
    }

    func testFieldFilterBreaksTheRun() throws {
        // from:amy hello there: the from filter stays its own node; the two
        // bare terms after it merge into one ranked leaf.
        let node = try QueryParser.parse("from:amy hello there")
        let compiled = try QueryCompiler.compile(node!)
        guard case .and(let children) = compiled.root, children.count == 2 else {
            XCTFail("expected AND of from-filter and one text leaf, got \(compiled.root)")
            return
        }
        guard case .fts(let fromLeaf) = children[0] else {
            XCTFail("expected from leaf first, got \(children[0])")
            return
        }
        XCTAssertTrue(fromLeaf.expression.contains("{from_name from_addr}"))
        guard case .fts(let textLeaf) = children[1] else {
            XCTFail("expected one merged text leaf, got \(children[1])")
            return
        }
        XCTAssertEqual(textLeaf.expression, "{subject from_name from_addr recipients body attachments} : hello AND there")
    }

    func testNegationBreaksTheRun() throws {
        let node = try QueryParser.parse("hello -world")
        let compiled = try QueryCompiler.compile(node!)
        guard case .and(let children) = compiled.root, children.count == 2 else {
            XCTFail("expected AND of text and NOT, got \(compiled.root)")
            return
        }
        guard case .fts(let hello) = children[0] else {
            XCTFail("expected text leaf first, got \(children[0])")
            return
        }
        XCTAssertEqual(hello.expression, "{subject from_name from_addr recipients body attachments} : hello")
        guard case .not(let inner) = children[1] else {
            XCTFail("expected NOT second, got \(children[1])")
            return
        }
        guard case .fts(let excluded) = inner else {
            XCTFail("expected NOT of a text leaf, got \(inner)")
            return
        }
        XCTAssertEqual(excluded.expression, "{subject from_name from_addr recipients body attachments} : world")
    }

    func testOrAlternativesKeepTheirOwnRuns() throws {
        // a OR b c: each OR alternative is independent; b and c merge inside
        // their alternative.
        let node = try QueryParser.parse("a OR b c")
        let compiled = try QueryCompiler.compile(node!)
        guard case .or(let alternatives) = compiled.root, alternatives.count == 2 else {
            XCTFail("expected OR of two alternatives, got \(compiled.root)")
            return
        }
        guard case .fts(let a) = alternatives[0] else {
            XCTFail("expected text leaf first, got \(alternatives[0])")
            return
        }
        XCTAssertEqual(a.expression, "{subject from_name from_addr recipients body attachments} : a")
        guard case .fts(let bc) = alternatives[1] else {
            XCTFail("expected merged text leaf second, got \(alternatives[1])")
            return
        }
        XCTAssertEqual(bc.expression, "{subject from_name from_addr recipients body attachments} : b AND c")
    }

    func testParenthesizedGroupMergesInside() throws {
        // (x y) z: the group is one node, so z stays separate; x and y merge
        // inside the group.
        let node = try QueryParser.parse("(x y) z")
        let compiled = try QueryCompiler.compile(node!)
        guard case .and(let children) = compiled.root, children.count == 2 else {
            XCTFail("expected AND of group and term, got \(compiled.root)")
            return
        }
        guard case .fts(let inner) = children[0] else {
            XCTFail("expected merged leaf inside the group, got \(children[0])")
            return
        }
        XCTAssertEqual(inner.expression, "{subject from_name from_addr recipients body attachments} : x AND y")
        guard case .fts(let z) = children[1] else {
            XCTFail("expected separate z leaf, got \(children[1])")
            return
        }
        XCTAssertEqual(z.expression, "{subject from_name from_addr recipients body attachments} : z")
    }

    func testMergedLeafKeepsTrigramFallback() throws {
        let leaf = try leaf("hutopuza capu")
        let fallback = try XCTUnwrap(leaf.trigramFallback)
        // The fallback must rescue both terms as substrings.
        XCTAssertTrue(fallback.contains("hutopuza"))
        XCTAssertTrue(fallback.contains("capu"))
    }
}
