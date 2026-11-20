import Foundation

/// BERT WordPiece tokenizer for the bge-small-en-v1.5 Core ML embedding
/// (decisions 0009 and 0045). The Core ML export of that model takes
/// integer token IDs, not text, so the adapter tokenizes in Swift with
/// the same pipeline the model was trained behind: clean, lowercase,
/// strip accents, split punctuation, greedy longest-match WordPiece, then
/// a `[CLS] ... [SEP]` wrap truncated to the model's 512-position input.
public struct WordPieceTokenizer: Sendable {
    public let unknownID: Int
    public let clsID: Int
    public let sepID: Int
    /// Positions the model accepts; content tokens get the rest after
    /// the two specials.
    public let maxSequenceLength: Int

    private let ids: [String: Int]

    public enum TokenizerError: Error {
        case missingSpecialToken(String)
        case emptyVocabulary
    }

    /// - Parameter vocabulary: one token per line, position = ID (BERT
    ///   `vocab.txt` layout). Lowercased with `##` continuations present.
    public init(vocabulary: String, maxSequenceLength: Int = 512) throws {
        var ids: [String: Int] = [:]
        var position = 0
        for line in vocabulary.split(separator: "\n", omittingEmptySubsequences: false) {
            let token = line.trimmingCharacters(in: .whitespaces)
            guard !token.isEmpty else { continue }
            ids[token] = position
            position += 1
        }
        guard position > 0 else { throw TokenizerError.emptyVocabulary }
        for required in ["[UNK]", "[CLS]", "[SEP]"] {
            guard ids[required] != nil else { throw TokenizerError.missingSpecialToken(required) }
        }
        self.ids = ids
        self.unknownID = ids["[UNK]"]!
        self.clsID = ids["[CLS]"]!
        self.sepID = ids["[SEP]"]!
        self.maxSequenceLength = maxSequenceLength
    }

    /// Token IDs for one text, already wrapped and truncated:
    /// `[CLS] w1 w2 ... [SEP]`.
    public func encode(_ text: String) -> [Int] {
        let contentBudget = maxSequenceLength - 2
        var result = [clsID]
        result.reserveCapacity(maxSequenceLength)
        var count = 0
        for word in basicTokens(text) {
            if count >= contentBudget { break }
            for id in wordPiece(word) {
                if count >= contentBudget { break }
                result.append(id)
                count += 1
            }
        }
        result.append(sepID)
        return result
    }

    /// The pieces of one word as vocab strings (`##` prefixes included),
    /// or nil when the word is not representable.
    private func pieces(for word: String) -> [String]? {
        if word.count > maxSequenceLength { return nil }
        var pieces: [String] = []
        var start = word.startIndex
        while start < word.endIndex {
            var end = word.endIndex
            var match: String?
            while start < end {
                let candidate = String(word[start..<end])
                let lookup = start == word.startIndex ? candidate : "##" + candidate
                if ids[lookup] != nil {
                    match = lookup
                    break
                }
                end = word.index(before: end)
            }
            guard let found = match else { return nil }
            pieces.append(found)
            start = end
        }
        return pieces
    }

    /// Greedy longest-match WordPiece; a word with no full cover yields
    /// the single unknown token, matching the reference implementation.
    private func wordPiece(_ word: String) -> [Int] {
        guard let found = pieces(for: word) else { return [unknownID] }
        return found.map { ids[$0] ?? unknownID }
    }

    /// BERT basic tokenization: lowercase with diacritics folded away,
    /// whitespace split, then punctuation and CJK characters split off as
    /// single-character tokens.
    private func basicTokens(_ text: String) -> [String] {
        let cleaned = text.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        var words: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        for scalar in cleaned.unicodeScalars {
            if scalar.properties.isWhitespace {
                flush()
            } else if Self.isPunctuation(scalar) || Self.isCJK(scalar) {
                flush()
                words.append(String(scalar))
            } else {
                current.unicodeScalars.append(scalar)
            }
        }
        flush()
        return words
    }

    /// BERT's `_is_punctuation`: the ASCII punctuation ranges plus every
    /// Unicode scalar whose general category is punctuation or symbol.
    static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 33...47, 58...64, 91...96, 123...126:
            return true
        default:
            switch scalar.properties.generalCategory {
            case .otherPunctuation, .openPunctuation, .closePunctuation,
                 .initialPunctuation, .finalPunctuation, .otherSymbol,
                 .mathSymbol, .currencySymbol, .modifierSymbol:
                return true
            default:
                return false
            }
        }
    }

    /// CJK ideographs and kana have no whitespace between words; BERT
    /// splits each character into its own token.
    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x3040...0x30FF,
             0xAC00...0xD7AF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }
}
