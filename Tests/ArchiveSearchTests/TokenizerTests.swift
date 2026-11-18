// Tokenizer pipeline golden tests (DESIGN 6A "Tokenizing in Every Language").
// macOS asserts the NaturalLanguage segmentation quality pinned by the M0
// spike (hand-checked CJK word boundaries); Linux asserts the documented
// fallback. Folding, address tokens, and noise filtering are asserted on
// every platform.

import XCTest

@testable import ArchiveSearch

final class TokenizerTests: XCTestCase {
    // MARK: - Folding

    func testFoldingIsCaseAndDiacriticInsensitive() {
        XCTAssertEqual(TokenPipeline.folded("Rechnung"), "rechnung")
        XCTAssertEqual(TokenPipeline.folded("Crème brûlée"), "creme brulee")
        XCTAssertEqual(TokenPipeline.folded("Счёт"), "счет")
        XCTAssertEqual(TokenPipeline.folded("Ｉｎｖｏｉｃｅ"), "invoice") // NFKC width
    }

    func testFoldingIsLocaleIndependent() {
        // Turkish dotless i must fold the same everywhere; the fold never
        // consults the system locale.
        XCTAssertEqual(
            TokenPipeline.folded("DİNAMİK"), TokenPipeline.folded("dinamik")
        )
    }

    // MARK: - Word tokens

    func testEnglishTokens() {
        XCTAssertEqual(
            TokenPipeline.tokens(for: "Invoices due on the 12th, paid via WIRE!", field: .body),
            ["invoices", "due", "on", "the", "12th", "paid", "via", "wire"]
        )
    }

    func testDiacriticsFoldInTokens() {
        XCTAssertEqual(
            TokenPipeline.tokens(for: "Crème brûlée à la maison", field: .body),
            ["creme", "brulee", "a", "la", "maison"]
        )
    }

    func testCyrillicTokens() {
        let tokens = TokenPipeline.tokens(for: "Счёт на оплату за услуги", field: .body)
        XCTAssertEqual(tokens, ["счет", "на", "оплату", "за", "услуги"])
    }

    func testGermanCompoundStaysWholeAtThisStage() {
        // Compounds are one word until stemming (a later step) handles
        // suffixes; the pipeline must not split inside words.
        XCTAssertEqual(
            TokenPipeline.tokens(for: "Rechnungen und Rechnung", field: .subject),
            ["rechnungen", "und", "rechnung"]
        )
    }

    func testPunctuationOnlyTokensAreDropped() {
        XCTAssertEqual(
            TokenPipeline.tokens(for: "Wait --- what?! ... -- (ok)", field: .body),
            ["wait", "what", "ok"]
        )
    }

    func testNumbersSurvive() {
        XCTAssertEqual(
            TokenPipeline.tokens(for: "acct 4417 order #88-221", field: .body),
            ["acct", "4417", "order", "88", "221"]
        )
    }

    func testRepeatedTokensAreKept() {
        // The token stream preserves repeats: FTS5 phrase queries rely on
        // adjacency, so the index must see the raw sequence.
        XCTAssertEqual(
            TokenPipeline.tokens(for: "due due Due DUE", field: .subject),
            ["due", "due", "due", "due"]
        )
    }

    func testEmptyAndHostileInputYieldNoTokens() {
        XCTAssertTrue(TokenPipeline.tokens(for: "", field: .body).isEmpty)
        XCTAssertTrue(TokenPipeline.tokens(for: "   \r\n\t  ", field: .body).isEmpty)
        XCTAssertTrue(TokenPipeline.tokens(for: "👍👍", field: .body).isEmpty)
        // Long junk: tokens over the length cap are dropped, nothing throws.
        XCTAssertTrue(TokenPipeline.tokens(for: String(repeating: "x", count: 5000), field: .body).isEmpty)
        _ = TokenPipeline.tokens(for: String(repeating: "\u{0301}", count: 200), field: .subject)
        _ = TokenPipeline.tokens(for: "\u{FFFD}\u{FFFE}", field: .subject)
    }

    func testLongTokensAreDroppedButShortOnesKept() {
        let text = "\(String(repeating: "y", count: 65)) keep"
        XCTAssertEqual(TokenPipeline.tokens(for: text, field: .body), ["keep"])
    }

    // MARK: - CJK segmentation (macOS quality, Linux fallback)

    func testChineseSegmentsIntoWords() throws {
        #if canImport(NaturalLanguage)
        let tokens = TokenPipeline.tokens(for: "我明天要去北京开会，请把发票发给我。", field: .body)
        XCTAssertEqual(
            tokens,
            ["我", "明天", "要", "去", "北京", "开会", "请", "把", "发票", "发给", "我"]
        )
        #else
        throw XCTSkip("NaturalLanguage segmentation is macOS-only; Linux pins the fallback below")
        #endif
    }

    func testJapaneseSegmentsIntoWords() throws {
        #if canImport(NaturalLanguage)
        let tokens = TokenPipeline.tokens(for: "明日の会議の資料を送ってください。", field: .body)
        XCTAssertEqual(
            tokens,
            ["明日", "の", "会議", "の", "資料", "を", "送っ", "て", "ください"]
        )
        #else
        throw XCTSkip("NaturalLanguage segmentation is macOS-only; Linux pins the fallback below")
        #endif
    }

    func testKoreanSegmentsIntoWords() throws {
        #if canImport(NaturalLanguage)
        let tokens = TokenPipeline.tokens(for: "내일 회의 자료를 보내 주세요.", field: .body)
        XCTAssertEqual(tokens, ["내일", "회의", "자료를", "보내", "주세요"])
        #else
        throw XCTSkip("NaturalLanguage segmentation is macOS-only; Linux pins the fallback below")
        #endif
    }

    func testFallbackSegmentsCJKPerCharacter() {
        // The Linux fallback emits one token per Han character; combined
        // with the trigram index (raw folded text) substring queries still
        // match multi-character words.
        XCTAssertEqual(
            TokenPipeline.fallbackSegments("发票"),
            ["发", "票"]
        )
        XCTAssertEqual(
            TokenPipeline.fallbackSegments("明日の会議"),
            ["明", "日", "の", "会", "議"]
        )
    }

    func testMixedScriptTextSegmentWithoutLosingWords() {
        let tokens = TokenPipeline.tokens(for: "会议 invoice123 です", field: .body)
        // Nothing is lost across scripts. Words may come out whole (会议)
        // or split by whichever language detection picks, so assert on the
        // joined stream's content, not on token boundaries.
        let joined = tokens.joined(separator: " ")
        // The alphanumeric run may stay whole ("invoice123") or be split
        // ("in voice 123") depending on the language detection's choice for
        // the mixed text; either way its letters and digits survive, and
        // the trigram index covers substring queries.
        XCTAssertTrue(joined.contains("voice"))
        XCTAssertTrue(joined.contains("123"))
        XCTAssertTrue(joined.contains("会"))
        XCTAssertTrue(joined.contains("议"))
        XCTAssertTrue(joined.contains("です") || joined.contains("で"))
    }

    func testKoreanHangulIsSegmentedNotSplitInsideSyllables() {
        // Hangul syllables (가-힣) are whole characters; the fallback must
        // not decompose them into jamo.
        let segments = TokenPipeline.fallbackSegments("내일 회의")
        XCTAssertEqual(segments, ["내", "일", "회", "의"])
    }

    // MARK: - Language detection

    func testDetectedLanguageTags() {
        #if canImport(NaturalLanguage)
        XCTAssertEqual(TokenPipeline.detectedLanguage(of: "The invoice is overdue."), "en")
        XCTAssertEqual(TokenPipeline.detectedLanguage(of: " Die Rechnung ist überfällig. "), "de")
        XCTAssertNil(TokenPipeline.detectedLanguage(of: ""))
        XCTAssertNil(TokenPipeline.detectedLanguage(of: "12345"))
        #else
        // No language detection without NaturalLanguage.
        XCTAssertNil(TokenPipeline.detectedLanguage(of: "The invoice is overdue."))
        #endif
    }

    // MARK: - Address tokens

    func testAddressTokensMatchDesign() {
        XCTAssertEqual(
            TokenPipeline.addressTokens("jane.doe@example.com"),
            ["jane", "doe", "jane.doe", "example", "example.com"]
        )
    }

    func testAddressTokensFoldAndHandleSeparators() {
        // The bare TLD (`uk`) is not a token: it would match every sender
        // under .uk. Labels, the local whole, and the domain whole are.
        XCTAssertEqual(
            TokenPipeline.addressTokens("Jean-Michel+lists@example.co.uk"),
            ["jean", "michel", "lists", "jean-michel+lists", "example", "co", "example.co.uk"]
        )
    }

    func testAddressTokensOfSinglePieceLocalPart() {
        XCTAssertEqual(
            TokenPipeline.addressTokens("jane@example.com"),
            ["jane", "example", "example.com"]
        )
    }

    func testAddressTokensOfMalformedInputYieldNothing() {
        XCTAssertTrue(TokenPipeline.addressTokens("no-at-sign").isEmpty)
        XCTAssertTrue(TokenPipeline.addressTokens("@example.com").isEmpty)
        XCTAssertTrue(TokenPipeline.addressTokens("jane@").isEmpty)
        XCTAssertTrue(TokenPipeline.addressTokens("").isEmpty)
    }
}
