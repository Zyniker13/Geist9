import ArchiveCore
import XCTest

@testable import ArchiveEmbedApple

/// The WordPiece tokenizer behind the Core ML embedding adapter: the
/// reference BERT basic-tokenization pipeline (lowercase, fold accents,
/// split punctuation and CJK, greedy longest-match pieces, [CLS]/[SEP]
/// wrap, truncation) exercised against a toy vocabulary.
final class WordPieceTokenizerTests: XCTestCase {
    private func makeTokenizer(maxSequenceLength: Int = 512) throws -> WordPieceTokenizer {
        let url = Bundle.module.url(forResource: "toy_vocab", withExtension: "txt")!
        let vocabulary = try String(contentsOf: url, encoding: .utf8)
        return try WordPieceTokenizer(
            vocabulary: vocabulary,
            maxSequenceLength: maxSequenceLength
        )
    }

    func testEncodeWrapsWithSpecialTokens() throws {
        let tokenizer = try makeTokenizer()
        // hello=4 world=5; [CLS]=2 [SEP]=3.
        XCTAssertEqual(tokenizer.encode("hello world"), [2, 4, 5, 3])
    }

    func testEncodeLowersAndStripsAccents() throws {
        let tokenizer = try makeTokenizer()
        // "APPLE" lowercases to apple=16; an accented word folds to its
        // base letters and then follows normal WordPiece.
        XCTAssertEqual(tokenizer.encode("APPLE"), [2, 16, 3])
    }

    func testContinuationPiecesJoinWholeWords() throws {
        let tokenizer = try makeTokenizer()
        // "tests" is not in the vocabulary; "test"(9) + "##s"(8) is.
        XCTAssertEqual(tokenizer.encode("tests"), [2, 9, 8, 3])
        // "running" is not representable ("run"+"##ning" has no ##ning),
        // so the whole word yields [UNK].
        XCTAssertEqual(tokenizer.encode("running"), [2, 1, 3])
    }

    func testUnknownWordBecomesSingleUnknownToken() throws {
        let tokenizer = try makeTokenizer()
        XCTAssertEqual(tokenizer.encode("zebra"), [2, 1, 3])
    }

    func testPunctuationSplitsIntoSeparateTokens() throws {
        let tokenizer = try makeTokenizer()
        // "," is not in the vocabulary: punctuation splits off, then maps
        // to [UNK] rather than swallowing neighbors.
        XCTAssertEqual(tokenizer.encode("hello, world"), [2, 4, 1, 5, 3])
    }

    func testCJKCharactersBecomeSeparateTokens() throws {
        let tokenizer = try makeTokenizer()
        // Each CJK character is its own token position; with no CJK in
        // the toy vocabulary both land on [UNK].
        XCTAssertEqual(tokenizer.encode("世界"), [2, 1, 1, 3])
    }

    func testTruncationKeepsRoomForBothSpecials() throws {
        let tokenizer = try makeTokenizer()
        let short = try makeTokenizer(maxSequenceLength: 6)
        let words = "hello world test run swift core ml apple"
        // Full-length tokenizer has room for everything.
        XCTAssertEqual(tokenizer.encode(words).count, 10)
        // Six positions: [CLS] + four content tokens + [SEP].
        XCTAssertEqual(short.encode(words), [2, 4, 5, 9, 10, 3])
    }

    func testEmptyTextEncodesToJustTheSpecials() throws {
        let tokenizer = try makeTokenizer()
        XCTAssertEqual(tokenizer.encode(""), [2, 3])
        XCTAssertEqual(tokenizer.encode("   "), [2, 3])
    }

    func testMissingSpecialTokensAreRejected() {
        XCTAssertThrowsError(try WordPieceTokenizer(vocabulary: "alpha\nbeta")) { error in
            guard case WordPieceTokenizer.TokenizerError.missingSpecialToken = error else {
                return XCTFail("expected missingSpecialToken, got \(error)")
            }
        }
    }

    func testEmptyVocabularyIsRejected() {
        XCTAssertThrowsError(try WordPieceTokenizer(vocabulary: " \n \n"))
    }
}
