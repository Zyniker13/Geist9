import ArchiveCore
import CoreML
import Foundation

/// Core ML implementation of `EmbeddingModel` for bge-small-en-v1.5
/// (decisions 0009 and 0045). The model contract is fixed by the
/// conversion in `scripts/build-embedding-model.sh`: three Int32 inputs
/// `input_ids`, `attention_mask`, `token_type_ids` shaped [1, S], and
/// either a `last_hidden_state` output shaped [1, S, D] (CLS pooling
/// happens here) or an already-pooled output shaped [1, D]. Vectors are
/// L2-normalized before storage, matching the similarity search's
/// assumption.
///
/// `MLModel` documents `prediction` as safe to call from multiple
/// threads, so the shared model is confined by that guarantee; the class
/// is `@unchecked Sendable` for that reason only — nothing else is
/// mutable after init.
public final class CoreMLEmbedding: EmbeddingModel, @unchecked Sendable {
    public let identifier: String
    public let dimension: Int
    public let maxSequenceLength: Int

    private let model: MLModel
    private let tokenizer: WordPieceTokenizer
    private let hiddenStateOutputName: String

    public init(
        modelAt modelURL: URL,
        vocabulary: String,
        identifier: String = "bge-small-en-v1.5",
        sequenceLength: Int = 512
    ) throws {
        // The runtime requires a compiled bundle; ship and test the
        // human-readable source format and compile once on load.
        let loadURL = try Self.compiledIfSource(modelURL)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        let model = try MLModel(contentsOf: loadURL, configuration: configuration)
        let tokenizer = try WordPieceTokenizer(vocabulary: vocabulary, maxSequenceLength: sequenceLength)

        guard let description = model.modelDescription.inputDescriptionsByName["input_ids"] else {
            throw EmbeddingError.missingInput("input_ids")
        }
        let modelLength = Self.sequenceInputLength(description)
        let length = min(modelLength ?? sequenceLength, sequenceLength)

        // Dimension comes from the output description: [1, S, D] or [1, D].
        let outputName = Self.pooledOutputName(in: model.modelDescription.outputDescriptionsByName)
        guard let outputDescription = model.modelDescription.outputDescriptionsByName[outputName],
              let constraint = outputDescription.multiArrayConstraint
        else {
            throw EmbeddingError.missingOutput(outputName)
        }
        let shape = constraint.shape
        let outputDimension: Int
        switch shape.count {
        case 2: outputDimension = shape[1].intValue
        case 3: outputDimension = shape[2].intValue
        default:
            // Some conversions leave the declared output shape empty;
            // run one probe prediction and read the real shape.
            outputDimension = try Self.probedOutputDimension(
                model: model,
                tokenizer: tokenizer,
                length: length,
                outputName: outputName
            )
        }
        guard outputDimension > 0 else { throw EmbeddingError.unexpectedOutputShape(shape.map { $0.intValue }) }

        self.model = model
        self.tokenizer = tokenizer
        self.identifier = identifier
        self.dimension = outputDimension
        self.maxSequenceLength = length
        self.hiddenStateOutputName = outputName
    }

    public func embed(_ text: String) -> [Float]? {
        let ids = tokenizer.encode(text)
        let length = maxSequenceLength
        var inputIDs = ids
        if inputIDs.count > length {
            inputIDs = Array(inputIDs.prefix(length - 1)) + [tokenizer.sepID]
        }
        var mask = [Int32](repeating: 0, count: length)
        for index in 0..<min(inputIDs.count, length) { mask[index] = 1 }
        while inputIDs.count < length { inputIDs.append(tokenizer.clsID) } // pad with a valid ID, not [UNK]

        guard
            let features = try? Self.features(
                inputIDs: inputIDs.map(Int32.init),
                mask: mask,
                length: length
            ),
            let output = try? model.prediction(from: features),
            let multiArray = output.featureValue(for: hiddenStateOutputName)?.multiArrayValue
        else { return nil }

        let pooled = Self.pooledVector(multiArray: multiArray, dimension: dimension)
        var norm = 0.0
        for value in pooled { norm += Double(value) * Double(value) }
        norm = norm.squareRoot()
        guard norm > 0 else { return nil }
        return pooled.map { Float(Double($0) / norm) }
    }

    public enum EmbeddingError: Error {
        case missingInput(String)
        case missingOutput(String)
        case unexpectedOutputShape([Int])
    }

    /// `.mlmodel` and `.mlpackage` are source formats; current runtimes
    /// refuse to load them directly. Compile once, into the system
    /// temporary directory, and load the compiled bundle.
    private static func compiledIfSource(_ source: URL) throws -> URL {
        switch source.pathExtension.lowercased() {
        case "mlmodel", "mlpackage":
            return try MLModel.compileModel(at: source)
        default:
            return source
        }
    }

    private static func pooledOutputName(in outputs: [String: MLFeatureDescription]) -> String {
        if outputs["last_hidden_state"] != nil { return "last_hidden_state" }
        if outputs["pooled_output"] != nil { return "pooled_output" }
        return outputs.keys.sorted().first ?? "last_hidden_state"
    }

    private static func probedOutputDimension(
        model: MLModel,
        tokenizer: WordPieceTokenizer,
        length: Int,
        outputName: String
    ) throws -> Int {
        var ids = tokenizer.encode("")
        var mask = [Int32](repeating: 0, count: length)
        for index in 0..<min(ids.count, length) { mask[index] = 1 }
        while ids.count < length { ids.append(tokenizer.clsID) }
        let features = try Self.features(
            inputIDs: ids.map(Int32.init),
            mask: mask,
            length: length
        )
        let output = try model.prediction(from: features)
        guard let multiArray = output.featureValue(for: outputName)?.multiArrayValue else {
            throw EmbeddingError.missingOutput(outputName)
        }
        switch multiArray.shape.count {
        case 2: return multiArray.shape[1].intValue
        case 3: return multiArray.shape[2].intValue
        default: throw EmbeddingError.unexpectedOutputShape(multiArray.shape.map { $0.intValue })
        }
    }

    private static func sequenceInputLength(_ description: MLFeatureDescription) -> Int? {
        guard let constraint = description.multiArrayConstraint, constraint.shape.count >= 2 else {
            return nil
        }
        let last = constraint.shape[constraint.shape.count - 1].intValue
        return last > 0 ? last : nil // fixed shapes only; treat symbolic as unknown
    }

    private static func features(
        inputIDs: [Int32],
        mask: [Int32],
        length: Int
    ) throws -> MLDictionaryFeatureProvider {
        let ids = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .int32)
        let attention = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .int32)
        let types = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .int32)
        for index in 0..<length {
            ids[index] = NSNumber(value: inputIDs[index])
            attention[index] = NSNumber(value: mask[index])
            types[index] = NSNumber(value: 0)
        }
        return try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: ids),
            "attention_mask": MLFeatureValue(multiArray: attention),
            "token_type_ids": MLFeatureValue(multiArray: types),
        ])
    }

    /// The first token position's hidden state, or the flat vector when
    /// the output is already pooled.
    private static func pooledVector(multiArray: MLMultiArray, dimension: Int) -> [Float] {
        let count = multiArray.count
        if count == dimension {
            var vector = [Float]()
            vector.reserveCapacity(dimension)
            for index in 0..<dimension {
                vector.append(multiArray[index].floatValue)
            }
            return vector
        }
        var vector = [Float]()
        vector.reserveCapacity(dimension)
        for index in 0..<dimension {
            vector.append(multiArray[index].floatValue) // position 0 = [CLS]
        }
        return vector
    }
}

// MARK: Discovery

extension CoreMLEmbedding {
    /// Loads the model named `name` from the first directory that carries
    /// both files: `<name>.mlmodel` (or `.mlpackage`) and
    /// `<name>-vocab.txt`. Returns nil when either file is missing or the
    /// model cannot load — the archive then searches keyword-only
    /// (decision 0045), the designed degradation, never an error the
    /// person must see.
    public static func load(
        named name: String,
        in directories: [URL]
    ) -> CoreMLEmbedding? {
        for directory in directories {
            let vocabularyURL = directory.appendingPathComponent("\(name)-vocab.txt")
            guard let vocabulary = try? String(contentsOf: vocabularyURL, encoding: .utf8) else {
                continue
            }
            for extensionName in ["mlmodel", "mlpackage"] {
                let modelURL = directory.appendingPathComponent("\(name).\(extensionName)")
                guard FileManager.default.fileExists(atPath: modelURL.path) else { continue }
                if let model = try? CoreMLEmbedding(
                    modelAt: modelURL,
                    vocabulary: vocabulary,
                    identifier: name
                ) {
                    return model
                }
            }
        }
        return nil
    }
}
