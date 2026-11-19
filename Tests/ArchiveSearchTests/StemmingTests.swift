@testable import ArchiveSearch
import XCTest

/// The Snowball stemmer wrapper and the query-side form expansion
/// (decision 0026). Stem values are pinned to what the vendored Snowball
/// v3.2.0 actually produces, so a vendoring or regenerating mistake fails
/// loudly instead of silently changing what a query can find.
final class StemmingTests: XCTestCase {
    // MARK: The C stemmer through the wrapper

    func testEnglishStemsArePinned() throws {
        let session = try XCTUnwrap(StemmingSession(language: "en"))
        XCTAssertEqual(session.transform("running"), "run")
        XCTAssertEqual(session.transform("studies"), "studi")
        XCTAssertEqual(session.transform("notes"), "note")
        XCTAssertEqual(session.transform("budgets"), "budget")
        XCTAssertEqual(session.transform("kickoff"), "kickoff")
    }

    func testGermanStemsArePinned() throws {
        let session = try XCTUnwrap(StemmingSession(language: "de"))
        // Pins verified against upstream Snowball 3.2.0 stemwords. The
        // pipeline always folds first, so transform gets folded tokens.
        XCTAssertEqual(session.transform("rechnungen"), "rechnung")
        XCTAssertEqual(session.transform("rechnung"), "rechnung")
        XCTAssertEqual(session.transform("studien"), "studi")
        XCTAssertEqual(session.transform("laufenden"), "laufend")
    }

    func testDanishStemsArePinned() throws {
        let session = try XCTUnwrap(StemmingSession(language: "da"))
        XCTAssertEqual(session.transform("budget"), "budg")
    }

    func testNonCandidatesPassThroughUnstemmed() throws {
        let session = try XCTUnwrap(StemmingSession(language: "en"))
        // Shorter than the 4-letter minimum, or not pure letters: stored
        // and queried exactly as folded (decision 0026, point 1).
        XCTAssertEqual(session.transform("Runn"), "Runn")
        XCTAssertEqual(session.transform("a1b"), "a1b")
        XCTAssertEqual(session.transform("héllo"), "héllo")
    }

    func testASessionForAnUnsupportedLanguageIsNil() {
        // Languages without a vendored stemmer (Chinese, Japanese, Korean…):
        // no session, tokens stay folded.
        XCTAssertNil(StemmingSession(language: "zh"))
        XCTAssertNil(StemmingSession(language: "ja"))
        XCTAssertNil(StemmingSession(language: nil))
    }

    // MARK: Language detection

    func testAlgorithmForISO639Codes() {
        XCTAssertEqual(Stemming.algorithm(for: "en"), "en")
        XCTAssertEqual(Stemming.algorithm(for: "en-US"), "en")
        XCTAssertEqual(Stemming.algorithm(for: "de-DE"), "de")
        XCTAssertNil(Stemming.algorithm(for: "zh-Hans"))
        XCTAssertNil(Stemming.algorithm(for: "ja"))
        XCTAssertNil(Stemming.algorithm(for: nil))
    }

    func testDetectLanguageOnConfidentlyDetectableText() {
        #if canImport(NaturalLanguage)
        XCTAssertEqual(Stemming.detectLanguage("the running studies were relational"), "en")
        XCTAssertEqual(Stemming.detectLanguage("Rechnung ist faellig und muss bezahlt werden"), "de")
        #else
        // NaturalLanguage is macOS-only; Linux keeps unstemmed tokens
        // (decision 0026), so detection reports nothing there.
        XCTAssertNil(Stemming.detectLanguage("the running studies were relational"))
        XCTAssertNil(Stemming.detectLanguage("Rechnung ist faellig und muss bezahlt werden"))
        #endif
    }

    func testDetectLanguageGateOnShortOrAmbiguousText() {
        // Single words are unreliable ("budget" → da 0.23 measured): the
        // confidence gate keeps them unstemmed (decision 0026, point 3).
        XCTAssertNil(Stemming.detectLanguage("budget"))
        XCTAssertNil(Stemming.detectLanguage("a"))
        XCTAssertNil(Stemming.detectLanguage(""))
        // Chinese is confidently detected but has no vendored stemmer.
        XCTAssertNil(Stemming.detectLanguage("你好世界这是一个测试消息"))
        // Digits and punctuation only: no letters to stem.
        XCTAssertNil(Stemming.detectLanguage("123 456"))
    }

    // MARK: Query-side form expansion

    func testStemFormsCarryDetectedThenEnglishStems() throws {
        let english = try XCTUnwrap(StemmingSession(language: "en"))
        // A token whose stem equals its folded form has one form.
        XCTAssertEqual(Stemming.stemForms("budget", detected: nil, english: english), ["budget"])
        // Without a detected language, only the English stem is offered.
        XCTAssertEqual(Stemming.stemForms("running", detected: nil, english: english), ["run"])
        let german = try XCTUnwrap(StemmingSession(language: "de"))
        // The detected stem first, then the English stem, deduplicated.
        XCTAssertEqual(
            Stemming.stemForms("rechnungen", detected: german, english: english),
            ["rechnung", "rechnungen"])
        // Short and non-letter tokens never expand.
        XCTAssertEqual(Stemming.stemForms("abc", detected: german, english: english), ["abc"])
    }

    func testPrefixCandidatesIncludeTheStemsOfTheirOwnPrefixes() throws {
        let english = try XCTUnwrap(StemmingSession(language: "en"))
        // "running" stems to "run", so the prefix "runn" must also reach
        // messages indexed as "run" (decision 0026, point 6).
        XCTAssertEqual(
            Stemming.prefixCandidates("runn", detected: nil, english: english),
            ["runn", "run"])
        // A prefix that is its own stem has only itself.
        XCTAssertEqual(
            Stemming.prefixCandidates("kick", detected: nil, english: english),
            ["kick", "kic"])
        // Shorter than three letters: the prefix itself is the only
        // candidate — there is nothing to stem — and it still matches
        // every token that starts with it in the as-you-type path.
        XCTAssertEqual(Stemming.prefixCandidates("ab", detected: nil, english: english), ["ab"])
    }

    func testExpressionParenthesizesOnlyMultipleForms() {
        XCTAssertEqual(Stemming.expression(for: ["budget"]), "budget")
        XCTAssertEqual(Stemming.expression(for: ["budget", "bud"]), "(budget OR bud)")
    }

    // MARK: Phrase form expansion (decision 0026, points 4-5)

    private func ftsExpressions(of query: String, language: String? = "en") throws -> [String] {
        let node = try XCTUnwrap(QueryParser.parse(query), "parse(\(query))")
        let compiled = try QueryCompiler.compile(node, asYouType: false, language: language)
        var out: [String] = []
        var stack: [CompiledNode] = [compiled.root]
        while let node = stack.popLast() {
            switch node {
            case .fts(let leaf): out.append(leaf.expression)
            case .filter: break
            case .and(let children), .or(let children): stack.append(contentsOf: children)
            case .not(let child): stack.append(child)
            }
        }
        return out
    }

    func testPhraseIsTheFoldedPhrasePlusPerLanguageStemPhrases() throws {
        // The folded phrase stays adjacent on the original columns; the stem
        // phrase is one per language (a message's stems are all in its one
        // detected language). Here detected and English agree, so one stem
        // phrase — never a per-token mixture, which interleaved columns
        // produced and which could not match anything ("running budgets"
        // indexed as "running run budgets budget" made the phrase match
        // nothing).
        XCTAssertEqual(
            try ftsExpressions(of: "\"running budgets notes studies\""),
            ["({subject from_name from_addr recipients body quoted attachments}"
                + " : \"running budgets notes studies\""
                + " OR {subject_stem body_stem quoted_stem} : \"run budget note studi\")"])
    }

    func testPhraseStemPhrasesUseEachLanguageNotPerTokenMixtures() throws {
        // The detected stems and the English stems differ for "rechnungen"
        // (de: rechnung, en: rechnungen), so two stem phrases are offered —
        // one per language, detected first, never a per-token mixture.
        XCTAssertEqual(
            try ftsExpressions(of: "\"rechnungen studien\"", language: "de"),
            ["({subject from_name from_addr recipients body quoted attachments}"
                + " : \"rechnungen studien\""
                + " OR {subject_stem body_stem quoted_stem} : \"rechnung studi\""
                + " OR {subject_stem body_stem quoted_stem} : \"rechnungen studien\")"])
    }
}
