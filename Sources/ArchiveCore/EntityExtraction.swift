import Foundation

/// Entities recognized in a message's text at ingest (DESIGN 6A, M2).
/// Extraction is pure CPU over the same text the search index gets, so it
/// runs wherever tokenization runs and costs no extra pass over the bytes.
/// The first kind is amounts and currencies; dates, phone numbers, tracking
/// and booking codes, and domains follow the same table.
enum EntityKind: String, Sendable, Equatable {
    case amount
}

/// One recognized entity: the matched text, a normalized numeric value for
/// comparisons (`amount:>100`), and the currency when one is evident.
/// Currency is kept as found — ambiguous symbols (¥ means yen and yuan)
/// stay the symbol rather than a guessed code.
struct EntityHit: Sendable, Equatable {
    var kind: EntityKind
    var value: String
    var normalized: Double
    var currency: String?
}

enum EntityExtraction {
    /// Bound on entities kept per message: real mail has a few; a crafted
    /// document could hold thousands of duplicates, and the table must not
    /// grow without bound on one message.
    static let maxEntitiesPerMessage = 200

    /// Extracts entities from a message's subject and search text, in that
    /// order, deduplicated across the whole message.
    static func entities(forSubject subject: String?, searchText: SearchText?) -> [EntityHit] {
        var parts: [String] = []
        if let subject, !subject.isEmpty { parts.append(subject) }
        if let text = searchText {
            for part in [text.body, text.quoted, text.attachments] {
                if let part, !part.isEmpty { parts.append(part) }
            }
        }
        guard !parts.isEmpty else { return [] }
        return entities(in: parts.joined(separator: "\n"))
    }

    /// Extracts entities from one text block. Duplicate matches (the same
    /// raw form, value, and currency) collapse to the first occurrence.
    static func entities(in text: String) -> [EntityHit] {
        var hits: [EntityHit] = []
        var seen = Set<String>()
        for match in matches(in: text) {
            let key = "\(match.currency ?? "")|\(match.normalized)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            hits.append(match)
            if hits.count == maxEntitiesPerMessage { break }
        }
        return hits
    }

    // MARK: Amount patterns

    /// Digits with optional thousands separators and an optional fraction.
    /// The run always ends on a digit, so trailing punctuation (a comma or
    /// period after the amount) is not part of the match, and the trailing
    /// lookahead keeps it from slicing a longer number in half.
    private static let number = #"(\d[\d,.]*\d|\d)(?!\d)"#
    private static let symbolPrefix = "[\\$€£¥]\\s?" + number
    private static let symbolSuffix = number + "\\s?[\\$€£¥]"
    private static let codePrefix =
        #"\b(USD|EUR|GBP|CHF|JPY|CAD|AUD|CNY)\s?"# + number
    private static let codeSuffix = number + #"\s?(USD|EUR|GBP|CHF|JPY|CAD|AUD|CNY)\b"#

    /// Where a pattern keeps its number and currency groups. The code
    /// patterns have two capture groups (currency, number or the reverse);
    /// the symbol patterns have one (the number), with the currency as the
    /// first or last character of the match.
    private enum AmountStyle: Sendable {
        case symbolPrefix
        case symbolSuffix
        case codePrefix
        case codeSuffix

        var numberGroup: Int {
            switch self {
            case .codePrefix: return 2
            case .symbolPrefix, .symbolSuffix, .codeSuffix: return 1
            }
        }
    }

    private static let patterns: [(NSRegularExpression, AmountStyle)] = {
        let specs: [(String, AmountStyle)] = [
            (symbolPrefix, .symbolPrefix),
            (symbolSuffix, .symbolSuffix),
            (codePrefix, .codePrefix),
            (codeSuffix, .codeSuffix),
        ]
        return specs.compactMap { pattern, style in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (regex, style)
        }
    }()

    private static func matches(in text: String) -> [EntityHit] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var hits: [EntityHit] = []
        for (regex, style) in patterns {
            for match in regex.matches(in: text, range: range) {
                guard let hit = amount(from: match, in: text, style: style) else {
                    continue
                }
                hits.append(hit)
            }
        }
        return hits
    }

    /// Builds one amount hit from a pattern match: the number sits in the
    /// style's number group, the currency in a capture group (code
    /// patterns) or as the first/last character (symbol patterns).
    private static func amount(
        from match: NSTextCheckingResult, in text: String, style: AmountStyle
    ) -> EntityHit? {
        func group(_ index: Int) -> String? {
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return String(text[range])
        }
        guard let digits = group(style.numberGroup), let normalized = parseAmount(digits) else {
            return nil
        }
        let value = String(text[Range(match.range, in: text)!])

        // A minus directly before the match is a subtraction ("balance
        // -$50", "refund -50 USD"), not a currency amount; recognizing
        // signed amounts waits until a query needs them. A digit before
        // the minus ("1-50 USD", a range) is not a sign and stays.
        if match.range.location != NSNotFound, match.range.location > 0 {
            let start = String.Index(utf16Offset: match.range.location, in: text)
            let before = text.index(before: start)
            if text[before] == "-", before != text.startIndex,
               !text[text.index(before: before)].isNumber {
                return nil
            }
        }

        var currency: String?
        switch style {
        case .symbolPrefix:
            if let first = value.first { currency = currencySymbol(String(first)) }
        case .symbolSuffix:
            if let last = value.last { currency = currencySymbol(String(last)) }
        case .codePrefix: currency = group(1)
        case .codeSuffix: currency = group(2)
        }
        return EntityHit(kind: .amount, value: value, normalized: normalized, currency: currency)
    }

    private static func currencySymbol(_ symbol: String) -> String? {
        switch symbol {
        case "$": return "USD"
        case "€": return "EUR"
        case "£": return "GBP"
        case "¥": return "¥" // yen and yuan share the sign; keep the symbol
        default: return nil
        }
    }

    /// Parses a matched number into a decimal value. Separators are
    /// ambiguous ("1,234" is US thousands and "1.234,56" is German), so the
    /// rule is positional: when both separators appear, the rightmost is
    /// the decimal point; a comma followed by one or two digits at the end
    /// is a decimal (European cents); a lone separator followed by three
    /// digits is a thousands separator. A lone "1.234" without a decimal
    /// comma stays US-style (1.234), the common format in mail; German
    /// thousand-grouping without decimals is not recognized this way.
    static func parseAmount(_ raw: String) -> Double? {
        guard raw.first?.isNumber == true else { return nil }
        let comma = raw.firstIndex(of: ",")
        let dot = raw.firstIndex(of: ".")
        var normalized = raw
        switch (comma, dot) {
        case let (comma?, dot?):
            if comma > dot {
                normalized = raw.replacingOccurrences(of: ".", with: "")
                    .replacingOccurrences(of: ",", with: ".")
            } else {
                normalized = raw.replacingOccurrences(of: ",", with: "")
            }
        case let (comma?, nil):
            if trailingFraction(raw, separator: comma, maxDigits: 2) {
                normalized = raw.replacingOccurrences(of: ",", with: ".")
            } else {
                normalized = raw.replacingOccurrences(of: ",", with: "")
            }
        case let (nil, dot?):
            if trailingFraction(raw, separator: dot, maxDigits: 2) {
                break // already a plain decimal
            }
            // A lone dot after three digits with no fraction digits left
            // could be German thousands ("1.234"); without corroborating a
            // decimal comma it stays US-style.
            break
        default:
            break
        }
        return Double(normalized)
    }

    /// True when the digits after `separator` in `raw` are at most two and
    /// the run continues no further — the decimal-amount shape ("99,90",
    /// "75.50"), not a thousands group ("12,800").
    private static func trailingFraction(_ raw: String, separator: String.Index, maxDigits: Int) -> Bool {
        let tail = raw[raw.index(after: separator)...]
        let digits = tail.prefix { $0.isNumber }
        guard !digits.isEmpty else { return false }
        return digits.count <= maxDigits
    }
}
