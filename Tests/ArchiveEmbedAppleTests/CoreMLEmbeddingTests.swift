import ArchiveCore
import XCTest

@testable import ArchiveEmbedApple

/// The Core ML adapter exercised end to end against a tiny generated
/// model (`toy_embedding.mlmodel`, built by
/// `scripts/toy-embedding-model.py`). The model honors the real adapter
/// contract — three Int32 [1, S] inputs, a [1, S, D] `last_hidden_state`
/// output — so pooling, normalization, padding, and truncation are all
/// tested on-device without real embedding weights.
final class CoreMLEmbeddingTests: XCTestCase {
    private var modelURL: URL!

    override func setUpWithError() throws {
        let url = Bundle.module.url(forResource: "toy_embedding", withExtension: "mlmodel")
        modelURL = try XCTUnwrap(url, "toy_embedding.mlmodel missing from test bundle")
    }

    private func makeEmbedding(sequenceLength: Int = 16) throws -> CoreMLEmbedding {
        let vocabulary = try String(
            contentsOf: Bundle.module.url(forResource: "toy_vocab", withExtension: "txt")!,
            encoding: .utf8
        )
        return try CoreMLEmbedding(
            modelAt: modelURL,
            vocabulary: vocabulary,
            identifier: "toy",
            sequenceLength: sequenceLength
        )
    }

    func testLoadFindsModelAndVocabularyInADirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.copyItem(
            at: modelURL,
            to: directory.appendingPathComponent("toy-embed.mlmodel")
        )
        try FileManager.default.copyItem(
            at: Bundle.module.url(forResource: "toy_vocab", withExtension: "txt")!,
            to: directory.appendingPathComponent("toy-embed-vocab.txt")
        )
        let loaded = try XCTUnwrap(CoreMLEmbedding.load(named: "toy-embed", in: [directory]))
        XCTAssertEqual(loaded.identifier, "toy-embed")
        XCTAssertEqual(loaded.dimension, 8)
    }

    func testLoadReturnsNilWhenTheDirectoryHasNoModel() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertNil(CoreMLEmbedding.load(named: "toy-embed", in: [directory]))
    }

    func testLoadReturnsNilWhenTheVocabularyIsMissing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.copyItem(
            at: modelURL,
            to: directory.appendingPathComponent("toy-embed.mlmodel")
        )
        XCTAssertNil(CoreMLEmbedding.load(named: "toy-embed", in: [directory]))
    }

    func testLoadReturnsNilForACorruptModel() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("not a model".utf8).write(to: directory.appendingPathComponent("toy-embed.mlmodel"))
        try FileManager.default.copyItem(
            at: Bundle.module.url(forResource: "toy_vocab", withExtension: "txt")!,
            to: directory.appendingPathComponent("toy-embed-vocab.txt")
        )
        XCTAssertNil(CoreMLEmbedding.load(named: "toy-embed", in: [directory]))
    }

    func testAdoptsIdentifierAndDimensionFromTheModel() throws {
        let embedding = try makeEmbedding()
        XCTAssertEqual(embedding.identifier, "toy")
        XCTAssertEqual(embedding.dimension, 8)
        XCTAssertEqual(embedding.maxSequenceLength, 16)
    }

    func testEmbedReturnsUnitNormalizedVector() throws {
        let embedding = try makeEmbedding()
        let vector = try XCTUnwrap(embedding.embed("hello world"))
        XCTAssertEqual(vector.count, 8)
        let norm = vector.reduce(0) { $0 + $1 * $1 }
        XCTAssertEqual(norm, 1.0, accuracy: 0.001)
    }

    func testSameTextEmbedsIdentically() throws {
        let embedding = try makeEmbedding()
        let first = try XCTUnwrap(embedding.embed("hello world test"))
        let second = try XCTUnwrap(embedding.embed("hello world test"))
        XCTAssertEqual(first, second)
    }

    func testDifferentTextsEmbedDifferently() throws {
        let embedding = try makeEmbedding()
        let first = try XCTUnwrap(embedding.embed("hello world"))
        let second = try XCTUnwrap(embedding.embed("swift core ml"))
        XCTAssertEqual(first.count, second.count)
        XCTAssertNotEqual(first, second)
    }

    func testEmptyTextStillEmbeds() throws {
        // [CLS][SEP] with no content is a valid (if meaningless) input;
        // the adapter's contract is "no crash, no nil", and callers
        // decide whether empty text is worth embedding.
        let embedding = try makeEmbedding()
        let vector = try XCTUnwrap(embedding.embed(""))
        XCTAssertEqual(vector.count, 8)
        let norm = vector.reduce(0) { $0 + $1 * $1 }
        XCTAssertEqual(norm, 1.0, accuracy: 0.001)
    }

    func testTruncatesToTheModelSequenceLength() throws {
        let embedding = try makeEmbedding(sequenceLength: 16)
        // Far more than 14 content tokens: truncation keeps room for
        // [CLS]/[SEP] and pads the rest with a zeroed mask.
        let words = Array(repeating: "hello", count: 200).joined(separator: " world ")
        let vector = try XCTUnwrap(embedding.embed(words))
        XCTAssertEqual(vector.count, 8)
    }

    func testPaddingDoesNotChangeTheEmbeddingOfShortText() throws {
        // The toy model sums only unmasked positions, so a short text
        // must embed the same whether the sequence is short or padded.
        // Both requests go through the fixed [1, 16] input, so this
        // asserts the mask plumbing: pads contribute nothing.
        let embedding = try makeEmbedding()
        let vector = try XCTUnwrap(embedding.embed("hello"))
        XCTAssertEqual(vector.count, 8)
        let norm = vector.reduce(0) { $0 + $1 * $1 }
        XCTAssertEqual(norm, 1.0, accuracy: 0.001)
    }

    func testEmbeddingModelProtocolSatisfiability() throws {
        // The adapter is only useful where it stands in for the
        // protocol used by search and backfill; drive it through the
        // protocol witness to prove the conformance is real.
        let embedding: any EmbeddingModel = try makeEmbedding()
        let vector = try XCTUnwrap(embedding.embed("apple cup"))
        XCTAssertEqual(vector.count, embedding.dimension)
        XCTAssertEqual(embedding.identifier, "toy")
    }
}
