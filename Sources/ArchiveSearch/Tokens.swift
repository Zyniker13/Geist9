// Tokenizer pipeline (DESIGN 6A, decision 0007): text is tokenized in Swift
// before it reaches SQLite FTS5. Word segmentation first (dictionary-based for
// Chinese, Japanese, and Thai, which have no spaces), then case folding,
// Unicode NFKC, and diacritic folding, with the language detected per part.
//
// macOS uses NaturalLanguage (`NLLanguageRecognizer`, `NLTokenizer`). Core
// packages must build and test on Linux too (AGENTS.md), where those are
// unavailable: the fallback there splits on whitespace and punctuation and
// emits one token per Han/Hiragana/Katakana/Hangul character, which the
// trigram index (raw folded text) covers for substring queries. Tests pin the
// macOS segmentation quality and the Linux fallback separately.
//
// Address-aware tokens: `jane.doe@example.com` matches `jane`, `doe`,
// `jane.doe`, `example`, and `example.com`.

import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

/// The indexed text fields, in DESIGN 6A order. Field weights live in the
/// FTS5 layer; the pipeline only needs the name for error reporting.
public enum TextField: String, Sendable, CaseIterable {
    case subject, sender, recipient, body, quoted, attachment
}

public enum TokenPipeline {
    /// Maximum token length accepted; longer runs are noise (URLs, base64).
    static let maxTokenLength = 64

    /// Unicode NFKC, then case and diacritic folding. Locale-independent so
    /// the index is identical on every machine (Turkish i-variants must not
    /// depend on the system locale).
    public static func folded(_ text: String) -> String {
        let nfkc = text.precomposedStringWithCompatibilityMapping
        return nfkc.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// The detected language as a BCP-47-ish tag, or nil when detection has
    /// no opinion (too little text) or is unavailable (Linux).
    public static func detectedLanguage(of text: String) -> String? {
        #if canImport(NaturalLanguage)
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage else { return nil }
        return language.rawValue
        #else
        return nil
        #endif
    }

    /// Word tokens for one field's text: fold, segment, fold, drop noise.
    /// Empty input yields no tokens; hostile input never throws. The spike
    /// measured this order (fold the text, then segment) — folding first
    /// normalizes width variants so segmentation sees consistent characters.
    public static func tokens(for text: String, field: TextField) -> [String] {
        let pre = folded(text)
        let segments = segment(pre, field: field)
        var out: [String] = []
        out.reserveCapacity(segments.count)
        for token in segments {
            let foldedToken = folded(token)
            guard !foldedToken.isEmpty, foldedToken.count <= maxTokenLength else { continue }
            // Keep only tokens with at least one letter or digit: pure
            // punctuation and whitespace runs never help a query. Repeats
            // are kept: the token stream's order carries FTS5 phrases.
            let hasAlnum = foldedToken.unicodeScalars.contains { scalars.alnum.contains($0) }
            guard hasAlnum else { continue }
            out.append(foldedToken)
        }
        return out
    }


    /// Address-aware tokens for one mailbox (header form is already parsed
    /// by the caller): `jane.doe@example.com` produces `jane`, `doe`,
    /// `jane.doe`, `example`, `example.com` — pieces, then the local whole,
    /// then domain labels, then the domain whole.
    public static func addressTokens(_ address: String) -> [String] {
        let foldedAddress = folded(address)
        guard let at = foldedAddress.lastIndex(of: "@") else { return [] }
        let local = String(foldedAddress[..<at])
        let domain = String(foldedAddress[foldedAddress.index(after: at)...])
        guard !local.isEmpty, !domain.isEmpty else { return [] }

        var out: [String] = []
        var seen = Set<String>()
        func push(_ token: String) {
            guard !token.isEmpty, token.count <= maxTokenLength, seen.insert(token).inserted
            else { return }
            out.append(token)
        }
        let localPieces = local.split(whereSeparator: { character in
            character.unicodeScalars.contains { scalars.separators.contains($0) }
        }).map(String.init)
        for piece in localPieces { push(piece) }
        if localPieces.count > 1 { push(local) }
        // Domain: labels except the bare TLD, then the whole domain —
        // `com` alone would match every .com sender (DESIGN 6A example).
        let labels = domain.split(separator: ".").map(String.init)
        for label in labels.dropLast(1) { push(label) }
        push(domain)
        return out
    }

    // MARK: - Segmentation

    #if canImport(NaturalLanguage)
    private static func segment(_ text: String, field: TextField) -> [String] {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let tokenizer = NLTokenizer(unit: .word)
        if let language = recognizer.dominantLanguage { tokenizer.setLanguage(language) }
        tokenizer.string = text
        var out: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            out.append(String(text[range]))
            return true
        }
        if out.isEmpty {
            out = fallbackSegments(text)
        }
        return out
    }
    #else
    private static func segment(_ text: String, field: TextField) -> [String] {
        fallbackSegments(text)
    }
    #endif

    /// Segmentation where NaturalLanguage is unavailable: whitespace and
    /// punctuation split, one token per CJK character.
    static func fallbackSegments(_ text: String) -> [String] {
        var out: [String] = []
        var word = String.UnicodeScalarView()
        func flush() {
            if !word.isEmpty { out.append(String(word)); word = String.UnicodeScalarView() }
        }
        for scalar in text.unicodeScalars {
            if scalars.cjk.contains(scalar) {
                flush()
                out.append(String(scalar))
            } else if scalar.properties.isWhitespace || scalars.separators.contains(scalar) {
                flush()
            } else {
                word.append(scalar)
            }
        }
        flush()
        return out
    }

    /// True when any scalar is CJK (Han, Kana, Hangul, and companions):
    /// such queries also match through the trigram index, because the
    /// query's segmentation can differ from the indexed text's (DESIGN 6A,
    /// M2.1). Shared by the compiler's eager fallback and the tests.
    public static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalars.cjk.contains($0) }
    }

    // MARK: - Character classes (shared)

    public enum scalars {
        static let alnum: CharacterSet = {
            var set = CharacterSet.letters
            set.formUnion(.decimalDigits)
            return set
        }()

        /// The terms unicode61 would index for `text`: runs of letters and
        /// digits, split on every other character, in order, without
        /// deduplication. Used to compute vocabulary document-frequency
        /// deltas for columns stored raw rather than as a prepared token
        /// stream: the folded address column ("a@b.c" indexes as "a", "b",
        /// "c"; decision 0027).
        public static func unicode61Terms(_ text: String) -> [String] {
            var out: [String] = []
            var current = ""
            for scalar in text.unicodeScalars {
                if alnum.contains(scalar) {
                    current.unicodeScalars.append(scalar)
                } else if !current.isEmpty {
                    out.append(current)
                    current = ""
                }
            }
            if !current.isEmpty { out.append(current) }
            return out
        }

        /// Han, Hiragana, Katakana, and Hangul: scripts written without
        /// spaces between words.
        static let cjk: CharacterSet = {
            var set = CharacterSet()
            let ranges: [(UInt32, UInt32)] = [
                (0x2E80, 0x2EFF),   // CJK Radicals Supplement
                (0x3000, 0x303F),   // CJK Symbols and Punctuation
                (0x3040, 0x309F),   // Hiragana
                (0x30A0, 0x30FF),   // Katakana
                (0x3130, 0x318F),   // Hangul Compatibility Jamo
                (0x3400, 0x4DBF),   // CJK Extension A
                (0x4E00, 0x9FFF),   // CJK Unified Ideographs
                (0xAC00, 0xD7AF),   // Hangul Syllables
                (0xF900, 0xFAFF),   // CJK Compatibility Ideographs
                (0x20000, 0x2A6DF), // CJK Extension B
            ]
            for (lo, hi) in ranges {
                guard let lower = Unicode.Scalar(lo), let upper = Unicode.Scalar(hi) else { continue }
                set.insert(charactersIn: lower...upper)
            }
            return set
        }()

        static let separators: CharacterSet = {
            var set = CharacterSet.punctuationCharacters
            set.formUnion(.symbols)
            set.formUnion(.whitespacesAndNewlines)
            return set
        }()
    }
}
