// Snowball stemming (DESIGN 6A, decision 0026): a small Swift wrapper around
// the vendored Snowball C stemmers (Sources/CStemmer, BSD-3). Both the index
// and the query pipeline stem through this file so they always agree.
//
// Rules, pinned by tests:
// - only pure-letter tokens of at least 4 letters are stemmed (addresses,
//   domains, and numbers keep their exact form);
// - only languages with a vendored stemmer stem, and only on platforms that
//   detect language (NaturalLanguage, macOS); Linux keeps unstemmed tokens
//   like it keeps its segmentation fallback;
// - stemming runs after folding, so the stemmer sees the same folded form
//   the index stores.

import CStemmer
import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

public enum Stemming {
    /// ISO-639-1 codes of the vendored stemmers. Snowball's `sb_stemmer_new`
    /// accepts these codes as aliases of the algorithm names.
    public static let supportedLanguages: Set<String> = [
        "en", "de", "ru", "fr", "es", "it", "nl", "pt", "da", "no", "sv", "fi",
    ]

    /// Minimum confidence of the top language hypothesis before it is
    /// trusted (decision 0026). Measured on this platform: "budget report"
    /// -> en 0.78 (trusted), while single words "budget" -> da 0.23 and
    /// "a" -> hu 0.19 are rejected.
    static let minDetectionConfidence = 0.5

    /// Tokens shorter than this are left as-is: stems of 1-3 letter words
    /// add noise, not recall.
    static let minStemLength = 4

    /// True when `token` is a stemming candidate: every scalar a letter and
    /// long enough. Digits, dots, and other separators inside a token
    /// (addresses, domains, versions like 1.2.3) keep the token unstemmed.
    static func isCandidate(_ token: String) -> Bool {
        guard token.count >= minStemLength else { return false }
        return token.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) }
    }

    /// The Snowball algorithm name for a detected language tag ("en",
    /// "en-US", "de"), or nil when there is no vendored stemmer.
    public static func algorithm(for language: String?) -> String? {
        guard let language else { return nil }
        let code = language.lowercased().split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""
        return supportedLanguages.contains(code) ? code : nil
    }

    /// The message's stemming language (decision 0026): detect once per
    /// message, on the longest of the given parts, and return the Snowball
    /// algorithm name only when the top hypothesis is trusted (confidence
    /// >= minDetectionConfidence) and a vendored stemmer exists. Otherwise
    /// nil: the index stores the folded tokens as-is, and the query side
    /// still expands with the English stemmer, so recall is preserved.
    public static func detectLanguage(body: String?, quoted: String?, subject: String?) -> String? {
        let parts = [body, quoted, subject].compactMap { $0 }
        guard let text = parts.max(by: { $0.count < $1.count }) else { return nil }
        return detectLanguage(text)
    }

    /// The stemming language for one text (the query side uses this on the
    /// raw query string). Same gate as `detectLanguage(body:quoted:subject:)`.
    public static func detectLanguage(_ text: String) -> String? {
        let folded = TokenPipeline.folded(text)
        guard !folded.isEmpty else { return nil }
        #if canImport(NaturalLanguage)
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(folded)
        guard let top = recognizer.languageHypotheses(withMaximum: 1).max(by: { $0.value < $1.value }),
              top.value >= minDetectionConfidence,
              let algorithm = algorithm(for: top.key.rawValue)
        else { return nil }
        return algorithm
        #else
        return nil
        #endif
    }

    /// The stem forms for one folded token (decision 0026): the stem in the
    /// detected language, then the stem in English, deduplicated. These go
    /// under the stem columns, which hold the stems of the indexed tokens;
    /// the folded form itself stays in the original columns so phrases keep
    /// their adjacency.
    static func stemForms(_ token: String, detected: StemmingSession?, english: StemmingSession?) -> [String] {
        var forms: [String] = []
        for session in [detected, english] {
            guard let session else { continue }
            let stem = session.transform(token)
            if !forms.contains(stem) { forms.append(stem) }
        }
        return forms
    }

    /// The prefix candidates for an as-you-type prefix (decision 0026): the
    /// prefix itself plus the stem of every prefix of at least 3 letters, in
    /// the detected and in the English stemmer. The user is typing a word W
    /// and has typed P; the index holds stem(W), and some prefix P' of P has
    /// stem(P') == stem(W) (P = "runn", P' = "run" -> "run"), so the prefix
    /// query must offer those stems as its own prefixes.
    static func prefixCandidates(_ prefix: String, detected: StemmingSession?, english: StemmingSession?) -> [String] {
        guard prefix.count >= 3 else { return [prefix] }
        var candidates: [String] = [prefix]
        for session in [detected, english] {
            guard let session else { continue }
            for length in 3...prefix.count {
                let stem = session.transform(String(prefix.prefix(length)))
                if !candidates.contains(stem) { candidates.append(stem) }
            }
        }
        return candidates
    }

    /// The FTS5 expression for one token's forms: the bare token when there
    /// is a single form, otherwise the parenthesized OR group. Parentheses
    /// are required: FTS5 binds AND tighter than OR, so an unparenthesized
    /// "a OR b AND c" would read as "a OR (b AND c)".
    static func expression(for forms: [String]) -> String {
        forms.count == 1 ? forms[0] : "(" + forms.joined(separator: " OR ") + ")"
    }
}

/// One stemming session over a single language: creates the C stemmer once
/// and reuses it for every token of the call (a field's tokens, or a query's
/// terms). A class, because it owns a C resource that must be released and
/// only classes can have `deinit`. Sessions are created inside one
/// synchronous call and never shared across threads; `sb_stemmer_stem` is
/// not safe on one stemmer from concurrent threads.
public final class StemmingSession {
    private let stemmer: OpaquePointer

    /// A session for `language`, or nil when the language has no vendored
    /// stemmer (or the C layer refuses the character encoding).
    public init?(language: String?) {
        guard let algorithm = Stemming.algorithm(for: language),
              let stemmer = sb_stemmer_new(algorithm, "UTF_8")
        else { return nil }
        self.stemmer = stemmer
    }

    deinit {
        sb_stemmer_delete(stemmer)
    }

    /// The stem of a folded, pure-letter token. The input token unchanged
    /// when the C layer has no result for it — never throws, never empty.
    public func stem(_ token: String) -> String {
        let bytes = Array(token.utf8)
        return bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress,
                  let result = sb_stemmer_stem(stemmer, base, Int32(buffer.count))
            else { return token }
            let count = Int(sb_stemmer_length(stemmer))
            guard count > 0 else { return token }
            return String(decoding: UnsafeBufferPointer(start: result, count: count), as: UTF8.self)
        }
    }

    /// The pipeline's transform: candidates stem, everything else passes
    /// through. Index and query pipelines both use this so they agree.
    public func transform(_ token: String) -> String {
        guard Stemming.isCandidate(token) else { return token }
        return stem(token)
    }
}
