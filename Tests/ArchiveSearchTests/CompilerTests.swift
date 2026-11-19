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
        XCTAssertEqual(leaf.expression, "(({subject from_name from_addr recipients body attachments} : hutopuza"
            + " OR {subject_stem body_stem from_name_stem} : hutopuza)"
            + " AND ({subject from_name from_addr recipients body attachments} : capu"
            + " OR {subject_stem body_stem from_name_stem} : capu))")
        XCTAssertNotNil(leaf.trigramFallback)
    }

    func testThreeTermsMergeIntoOneLeaf() throws {
        let leaf = try leaf("hutopuza capu zizo")
        XCTAssertEqual(leaf.expression, "(({subject from_name from_addr recipients body attachments} : hutopuza"
            + " OR {subject_stem body_stem from_name_stem} : hutopuza)"
            + " AND ({subject from_name from_addr recipients body attachments} : capu"
            + " OR {subject_stem body_stem from_name_stem} : capu)"
            + " AND ({subject from_name from_addr recipients body attachments} : zizo"
            + " OR {subject_stem body_stem from_name_stem} : zizo))")
    }

    func testSingleTermStaysOneLeaf() throws {
        let leaf = try leaf("hutopuza")
        XCTAssertEqual(leaf.expression, "({subject from_name from_addr recipients body attachments} : hutopuza"
            + " OR {subject_stem body_stem from_name_stem} : hutopuza)")
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
        // Decision 0026: "notes" expands to its forms — the folded form on
        // the original columns and its English stem "note" on the stem
        // columns (separate columns keep phrases adjacent).
        XCTAssertEqual(termLeaf.expression, "({subject from_name from_addr recipients body attachments} : notes"
            + " OR {subject_stem body_stem from_name_stem} : note)")
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
        XCTAssertEqual(textLeaf.expression, "(({subject from_name from_addr recipients body attachments} : hello"
            + " OR {subject_stem body_stem from_name_stem} : hello)"
            + " AND ({subject from_name from_addr recipients body attachments} : there"
            + " OR {subject_stem body_stem from_name_stem} : there))")
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
        XCTAssertEqual(hello.expression, "({subject from_name from_addr recipients body attachments} : hello"
            + " OR {subject_stem body_stem from_name_stem} : hello)")
        guard case .not(let inner) = children[1] else {
            XCTFail("expected NOT second, got \(children[1])")
            return
        }
        guard case .fts(let excluded) = inner else {
            XCTFail("expected NOT of a text leaf, got \(inner)")
            return
        }
        XCTAssertEqual(excluded.expression, "({subject from_name from_addr recipients body attachments} : world"
            + " OR {subject_stem body_stem from_name_stem} : world)")
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
        XCTAssertEqual(a.expression, "({subject from_name from_addr recipients body attachments} : a"
            + " OR {subject_stem body_stem from_name_stem} : a)")
        guard case .fts(let bc) = alternatives[1] else {
            XCTFail("expected merged text leaf second, got \(alternatives[1])")
            return
        }
        XCTAssertEqual(bc.expression, "(({subject from_name from_addr recipients body attachments} : b"
            + " OR {subject_stem body_stem from_name_stem} : b)"
            + " AND ({subject from_name from_addr recipients body attachments} : c"
            + " OR {subject_stem body_stem from_name_stem} : c))")
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
        XCTAssertEqual(inner.expression, "(({subject from_name from_addr recipients body attachments} : x"
            + " OR {subject_stem body_stem from_name_stem} : x)"
            + " AND ({subject from_name from_addr recipients body attachments} : y"
            + " OR {subject_stem body_stem from_name_stem} : y))")
        guard case .fts(let z) = children[1] else {
            XCTFail("expected separate z leaf, got \(children[1])")
            return
        }
        XCTAssertEqual(z.expression, "({subject from_name from_addr recipients body attachments} : z"
            + " OR {subject_stem body_stem from_name_stem} : z)")
    }

    func testMergedLeafKeepsTrigramFallback() throws {
        let leaf = try leaf("hutopuza capu")
        let fallback = try XCTUnwrap(leaf.trigramFallback)
        // The fallback must rescue both terms as substrings.
        XCTAssertTrue(fallback.contains("hutopuza"))
        XCTAssertTrue(fallback.contains("capu"))
    }

    // Regression (M2 judged set, 2026-11-19): the leaf wrapped the per-token
    // group in the bare-column filter again, so the nested stem-column
    // filter intersected with it down to the empty set and every stem-only
    // match was invisible ("seats" could not find "Seat expansion"). The
    // group's own column filters are the whole story; no outer wrap.
    func testBareTermStemFormIsNotMaskedByAnOuterColumnFilter() throws {
        let leaf = try leaf("seats")
        XCTAssertEqual(leaf.expression,
            "({subject from_name from_addr recipients body attachments} : seats"
                + " OR {subject_stem body_stem from_name_stem} : seat)")
    }

    func testFieldQualifiedStemFormIsNotMaskedEither() throws {
        let leaf = try leaf("subject:seats")
        XCTAssertEqual(leaf.expression, "({subject} : seats OR {subject_stem} : seat)")
    }

    // Decision 0030: sender display names gain a stem column, so a
    // field-qualified sender term reaches the stem form too.
    func testSenderStemFormReachesTheSenderStemColumn() throws {
        let leaf = try leaf("from:meetings")
        XCTAssertEqual(leaf.expression, "({from_name from_addr} : meetings OR {from_name_stem} : meet)")
    }

    // Decision 0031: `amount:` compiles to an EXISTS subquery over the
    // entity table so it runs as one indexed lookup, not a table scan.
    func testAmountCompilesToIndexedEntitySubquery() throws {
        let node = try QueryParser.parse("amount:>1,234.5")
        let compiled = try QueryCompiler.compile(node!)
        guard case .filter(let filter) = compiled.root else {
            XCTFail("expected a filter for amount:, got \(compiled.root)")
            return
        }
        XCTAssertEqual(
            filter.sql,
            "EXISTS (SELECT 1 FROM message_entity e WHERE e.messageID = m.id"
                + " AND e.kind = 'amount' AND e.normalized > ?)")
        XCTAssertEqual(filter.arguments, ["1234.500000"])
    }

    // A value that parses to no comparison warns and matches nothing,
    // rather than being treated as text.
    func testUnparseableAmountMatchesNothingWithAWarning() throws {
        let node = try QueryParser.parse("amount:abc")
        let compiled = try QueryCompiler.compile(node!)
        guard case .filter(let filter) = compiled.root else {
            XCTFail("expected a filter for amount:, got \(compiled.root)")
            return
        }
        XCTAssertEqual(filter.sql, "1 = 0")
        XCTAssertTrue(filter.arguments.isEmpty)
        XCTAssertFalse(compiled.warnings.isEmpty)
    }

    // MARK: Natural-language dates

    // Natural dates resolve in UTC against a caller-supplied `now`, so the
    // same query compiles the same way no matter when it runs (DESIGN 6A).
    private func utc(_ iso: String) -> Date {
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        format.timeZone = TimeZone(identifier: "UTC")
        format.locale = Locale(identifier: "en_US_POSIX")
        return format.date(from: iso)!
    }

    // A bare month names the most recent occurrence of that month whose
    // first day is on or before today: from November 2026, "march" is
    // March 2026.
    func testBareMonthPicksTheMostRecentOccurrence() throws {
        let node = try QueryParser.parse("during:march", now: utc("2026-11-19T15:00:00Z"))
        XCTAssertEqual(node, .clause(.during(DateRange(
            start: "2026-03-01T00:00:00Z", end: "2026-04-01T00:00:00Z"))))
    }

    // Early in the year the most recent occurrence is the year before.
    func testBareMonthWrapsToThePreviousYear() throws {
        let node = try QueryParser.parse("during:march", now: utc("2026-02-05T09:00:00Z"))
        XCTAssertEqual(node, .clause(.during(DateRange(
            start: "2025-03-01T00:00:00Z", end: "2025-04-01T00:00:00Z"))))
    }

    // "last March" from November 2026 is March 2026, as people use it.
    func testLastMonthNameAgreesWithTheBareMonth() throws {
        let node = try QueryParser.parse("during:\"last march\"", now: utc("2026-11-19T15:00:00Z"))
        XCTAssertEqual(node, .clause(.during(DateRange(
            start: "2026-03-01T00:00:00Z", end: "2026-04-01T00:00:00Z"))))
    }

    // Month with an explicit year pins the year exactly.
    func testMonthWithYearPinsTheYear() throws {
        let node = try QueryParser.parse("during:\"March 2019\"", now: utc("2026-11-19T15:00:00Z"))
        XCTAssertEqual(node, .clause(.during(DateRange(
            start: "2019-03-01T00:00:00Z", end: "2019-04-01T00:00:00Z"))))
    }

    // Three-letter abbreviations and "sept" work; the month is the most
    // recent occurrence, so September from September 2021 is this year's.
    func testMonthAbbreviationsResolveLikeFullNames() throws {
        let node = try QueryParser.parse("during:sept", now: utc("2021-09-10T09:00:00Z"))
        XCTAssertEqual(node, .clause(.during(DateRange(
            start: "2021-09-01T00:00:00Z", end: "2021-10-01T00:00:00Z"))))
    }

    func testTodayAndYesterdayResolveToCalendarDays() throws {
        let now = utc("2026-11-19T15:27:09Z")
        XCTAssertEqual(
            try QueryParser.parse("during:today", now: now),
            .clause(.during(DateRange(
                start: "2026-11-19T00:00:00Z", end: "2026-11-20T00:00:00Z"))))
        XCTAssertEqual(
            try QueryParser.parse("during:yesterday", now: now),
            .clause(.during(DateRange(
                start: "2026-11-18T00:00:00Z", end: "2026-11-19T00:00:00Z"))))
    }

    // Weeks start Monday (ISO), even though the pinned day is a Thursday.
    func testWeeksStartMonday() throws {
        let now = utc("2026-11-19T15:27:09Z")
        XCTAssertEqual(
            try QueryParser.parse("during:\"this week\"", now: now),
            .clause(.during(DateRange(
                start: "2026-11-16T00:00:00Z", end: "2026-11-23T00:00:00Z"))))
        XCTAssertEqual(
            try QueryParser.parse("during:\"last week\"", now: now),
            .clause(.during(DateRange(
                start: "2026-11-09T00:00:00Z", end: "2026-11-16T00:00:00Z"))))
    }

    func testThisAndLastMonthAndYearAreCalendarSpans() throws {
        let now = utc("2026-11-19T15:27:09Z")
        XCTAssertEqual(
            try QueryParser.parse("during:\"this month\"", now: now),
            .clause(.during(DateRange(
                start: "2026-11-01T00:00:00Z", end: "2026-12-01T00:00:00Z"))))
        XCTAssertEqual(
            try QueryParser.parse("during:\"last month\"", now: now),
            .clause(.during(DateRange(
                start: "2026-10-01T00:00:00Z", end: "2026-11-01T00:00:00Z"))))
        XCTAssertEqual(
            try QueryParser.parse("during:\"this year\"", now: now),
            .clause(.during(DateRange(
                start: "2026-01-01T00:00:00Z", end: "2027-01-01T00:00:00Z"))))
        XCTAssertEqual(
            try QueryParser.parse("during:\"last year\"", now: now),
            .clause(.during(DateRange(
                start: "2025-01-01T00:00:00Z", end: "2026-01-01T00:00:00Z"))))
    }

    // before:/after: with a natural value take the span's start instant.
    func testBeforeAndAfterUseTheSpanStart() throws {
        let now = utc("2026-11-19T15:27:09Z")
        XCTAssertEqual(
            try QueryParser.parse("before:\"last march\"", now: now),
            .clause(.before("2026-03-01T00:00:00Z")))
        XCTAssertEqual(
            try QueryParser.parse("after:\"last march\"", now: now),
            .clause(.after("2026-03-01T00:00:00Z")))
    }

    // The numeric grammar keeps ownership of its forms unchanged.
    func testNumericDatesStillParseAsBefore() throws {
        let now = utc("2026-11-19T15:27:09Z")
        XCTAssertEqual(
            try QueryParser.parse("during:2019-06", now: now),
            .clause(.during(DateRange(
                start: "2019-06-01T00:00:00Z", end: "2019-07-01T00:00:00Z"))))
        XCTAssertEqual(
            try QueryParser.parse("before:2019-06-15T12:30", now: now),
            .clause(.before("2019-06-15T12:30:00Z")))
    }

    func testInvalidNaturalDatesExplainThemselves() {
        let now = utc("2026-11-19T15:27:09Z")
        XCTAssertThrowsError(try QueryParser.parse("during:\"last march 2019\"", now: now))
        XCTAssertThrowsError(try QueryParser.parse("during:\"march 19\"", now: now))
        XCTAssertThrowsError(try QueryParser.parse("during:smarch", now: now))
    }
}
