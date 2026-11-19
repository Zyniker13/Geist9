import Foundation

/// Entities recognized in a message's text at ingest (DESIGN 6A, M2).
/// Extraction is pure CPU over the same text the search index gets, so it
/// runs wherever tokenization runs and costs no extra pass over the bytes.
/// Kinds: amounts and currencies; dates; phone numbers; tracking numbers;
/// booking codes; domains. Postal addresses stay out until an operator
/// needs them.
/// The entity kinds recognized at ingest (DESIGN 6A). Rows live in the
/// message_entity table; operators and facets query them by kind.
public enum EntityKind: String, Sendable, Hashable {
    /// Money with its currency, normalized to a decimal number.
    case amount
    /// A calendar date, normalized to a UTC epoch. Date-only forms sit at
    /// midnight UTC; the written form stays the display value.
    case date
    /// A telephone number in written form; no numeric meaning is claimed.
    case phone
    /// A parcel or shipment tracking number.
    case tracking
    /// A reservation or booking code, recognized only beside its keyword.
    case booking
    /// A domain name, from a URL or a bare host with a common top-level
    /// domain. Header addresses are covered by the From field, not here.
    case domain
}

/// One recognized entity: the matched text, a normalized value for numeric
/// comparisons (`amount:>100`) and date facets, and the currency when one
/// is evident. Currency is kept as found — ambiguous symbols (¥ means yen
/// and yuan) stay the symbol rather than a guessed code. Kinds without a
/// numeric meaning (phone, tracking, booking, domain) keep `normalized` at
/// zero and are compared by their written `value`.
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

    /// Extracts entities from one text block.
    ///
    /// The shared patterns run first on every platform and own the
    /// normalized value for any text they match. On macOS, NSDataDetector
    /// then adds dates and phones in forms the shared patterns do not carry
    /// (multilingual month names, national phone formats), skipping any
    /// match that overlaps a shared hit. Duplicates — same kind and value,
    /// and for amounts the same currency and normalized value — collapse to
    /// the first occurrence.
    static func entities(in text: String) -> [EntityHit] {
        var hits: [EntityHit] = []
        var seen = Set<String>()
        var occupied: [NSRange] = []
        func add(_ hit: EntityHit, _ range: NSRange) {
            guard hits.count < maxEntitiesPerMessage else { return }
            var keys = ["\(hit.kind.rawValue)|\(hit.value)"]
            if hit.kind == .amount { keys.append("\(hit.currency ?? "")|\(hit.normalized)") }
            guard keys.allSatisfy({ !seen.contains($0) }) else { return }
            seen.formUnion(keys)
            hits.append(hit)
            occupied.append(range)
        }
        for (hit, range) in amountMatches(in: text) { add(hit, range) }
        for (hit, range) in dateMatches(in: text) {
            if let hit {
                add(hit, range)
            } else {
                occupied.append(range)
            }
        }
        for (hit, range) in phoneMatches(in: text) { add(hit, range) }
        for (hit, range) in trackingMatches(in: text) { add(hit, range) }
        for (hit, range) in bookingMatches(in: text) { add(hit, range) }
        for (hit, range) in domainMatches(in: text) { add(hit, range) }
        #if canImport(Darwin)
        for (hit, range) in detectorMatches(in: text, occupied: occupied) { add(hit, range) }
        #endif
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

    private static func amountMatches(in text: String) -> [(EntityHit, NSRange)] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var hits: [(EntityHit, NSRange)] = []
        for (regex, style) in patterns {
            for match in regex.matches(in: text, range: range) {
                guard let hit = amount(from: match, in: text, style: style) else {
                    continue
                }
                hits.append((hit, match.range))
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

    // MARK: Dates (shared)

    /// ISO 8601: "2024-03-03", optionally with a time ("2024-03-03T14:23").
    /// The year comes first, so the form is unambiguous in every locale.
    private static let isoDateRegex = try! NSRegularExpression(
        pattern: #"\b(\d{4})-(\d{1,2})-(\d{1,2})(?:T(\d{1,2}):(\d{2}))?\b"#)

    /// Month names, full and abbreviated, to number.
    private static let months: [String: Int] = {
        let names = [
            "january": 1, "february": 2, "march": 3, "april": 4, "may": 5, "june": 6,
            "july": 7, "august": 8, "september": 9, "october": 10, "november": 11,
            "december": 12,
        ]
        var all = names
        for (name, number) in names { all[String(name.prefix(3))] = number }
        all["sept"] = 9
        return all
    }()

    /// Longest names first so the alternation prefers "september" over "sept".
    private static let monthAlternation = months.keys.sorted { $0.count > $1.count }
        .joined(separator: "|")

    /// "March 3, 2024" and "Mar. 3rd, 2024": month first (US convention).
    private static let monthDayYearRegex = try! NSRegularExpression(
        pattern: "\\b(" + monthAlternation + ")\\.?\\s+(\\d{1,2})(?:st|nd|rd|th)?,?\\s+(\\d{4})\\b",
        options: .caseInsensitive)

    /// "3 April 2024" and "3rd April, 2024": day first (European convention).
    private static let dayMonthYearRegex = try! NSRegularExpression(
        pattern: "\\b(\\d{1,2})(?:st|nd|rd|th)?\\s+(" + monthAlternation + ")\\.?,?\\s+(\\d{4})\\b",
        options: .caseInsensitive)

    /// "3/3/2024" runs month-first (US); "03.03.2024" runs day-first
    /// (European). The written form is stored either way.
    private static let slashDateRegex = try! NSRegularExpression(
        pattern: #"\b(\d{1,2})/(\d{1,2})/(\d{4})\b"#)
    private static let dotDateRegex = try! NSRegularExpression(
        pattern: #"\b(\d{1,2})\.(\d{1,2})\.(\d{4})\b"#)

    private static func dateMatches(in text: String) -> [(EntityHit?, NSRange)] {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        var hits: [(EntityHit?, NSRange)] = []
        func hit(_ value: String, _ epoch: Double?, _ match: NSTextCheckingResult) {
            guard let epoch else {
                // Claimed but rejected (an impossible date): the range is
                // still occupied so the platform detector cannot rescue a
                // clamped reading of text the patterns judged invalid.
                hits.append((nil, match.range))
                return
            }
            hits.append((EntityHit(kind: .date, value: value, normalized: epoch, currency: nil), match.range))
        }
        for match in isoDateRegex.matches(in: text, range: range) {
            let year = Int(ns.substring(with: match.range(at: 1))) ?? 0
            let month = Int(ns.substring(with: match.range(at: 2))) ?? 0
            let day = Int(ns.substring(with: match.range(at: 3))) ?? 0
            var hour = 0
            var minute = 0
            if match.range(at: 4).location != NSNotFound {
                hour = Int(ns.substring(with: match.range(at: 4))) ?? 0
                minute = Int(ns.substring(with: match.range(at: 5))) ?? 0
            }
            let value = ns.substring(with: match.range)
            let moment = epoch(year: year, month: month, day: day, hour: hour, minute: minute)
            hit(value, moment, match)
        }
        for match in monthDayYearRegex.matches(in: text, range: range) {
            guard let month = months[ns.substring(with: match.range(at: 1)).lowercased()] else { continue }
            let day = Int(ns.substring(with: match.range(at: 2))) ?? 0
            let year = Int(ns.substring(with: match.range(at: 3))) ?? 0
            hit(ns.substring(with: match.range), epoch(year: year, month: month, day: day), match)
        }
        for match in dayMonthYearRegex.matches(in: text, range: range) {
            guard let month = months[ns.substring(with: match.range(at: 2)).lowercased()] else { continue }
            let day = Int(ns.substring(with: match.range(at: 1))) ?? 0
            let year = Int(ns.substring(with: match.range(at: 3))) ?? 0
            hit(ns.substring(with: match.range), epoch(year: year, month: month, day: day), match)
        }
        for match in slashDateRegex.matches(in: text, range: range) {
            let month = Int(ns.substring(with: match.range(at: 1))) ?? 0
            let day = Int(ns.substring(with: match.range(at: 2))) ?? 0
            let year = Int(ns.substring(with: match.range(at: 3))) ?? 0
            hit(ns.substring(with: match.range), epoch(year: year, month: month, day: day), match)
        }
        for match in dotDateRegex.matches(in: text, range: range) {
            let day = Int(ns.substring(with: match.range(at: 1))) ?? 0
            let month = Int(ns.substring(with: match.range(at: 2))) ?? 0
            let year = Int(ns.substring(with: match.range(at: 3))) ?? 0
            hit(ns.substring(with: match.range), epoch(year: year, month: month, day: day), match)
        }
        return hits
    }

    /// Converts a calendar date to a UTC epoch, or nil when the date does
    /// not exist ("31.02.2024", month 13).
    private static func epoch(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0) -> Double? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard (1...12).contains(month),
              let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let days = calendar.range(of: .day, in: .month, for: first),
              days.contains(day) else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))?
            .timeIntervalSince1970
    }

    // MARK: Phone numbers (shared)

    /// E.164-style numbers: a leading plus, then digits with single spaces,
    /// dashes, or parentheses between them, 8 to 15 digits in total. Dots
    /// are not accepted as separators, so version strings ("+1.2.3") stay
    /// out.
    private static let phoneRegex = try! NSRegularExpression(
        pattern: #"\+\d{1,3}(?:[ \-()]?\d){7,14}\b"#)

    private static func phoneMatches(in text: String) -> [(EntityHit, NSRange)] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return phoneRegex.matches(in: text, range: range).map { match in
            let value = String(text[Range(match.range, in: text)!])
            return (EntityHit(kind: .phone, value: value, normalized: 0, currency: nil), match.range)
        }
    }

    // MARK: Tracking numbers (shared)

    /// UPS: "1Z" followed by sixteen digits and uppercase letters.
    private static let upsTrackingRegex = try! NSRegularExpression(
        pattern: #"\b1Z[0-9A-Z]{16}\b"#)

    /// The long all-digit service numbers (USPS and similar): twenty to
    /// twenty-two digits, optionally grouped by single spaces or dashes.
    /// Shorter runs (order numbers, card numbers) are too ambiguous to
    /// claim.
    private static let longDigitTrackingRegex = try! NSRegularExpression(
        pattern: #"\b\d(?:[ \-]?\d){19,21}\b"#)

    private static func trackingMatches(in text: String) -> [(EntityHit, NSRange)] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var hits: [(EntityHit, NSRange)] = []
        for regex in [upsTrackingRegex, longDigitTrackingRegex] {
            for match in regex.matches(in: text, range: range) {
                let value = String(text[Range(match.range, in: text)!])
                hits.append((EntityHit(kind: .tracking, value: value, normalized: 0, currency: nil), match.range))
            }
        }
        return hits
    }

    // MARK: Booking codes (shared)

    /// Six-character alphanumeric codes only beside their keyword: "PNR",
    /// "booking code", "confirmation code", "reservation code", "booking
    /// reference", "confirmation number". Bare six-character tokens are
    /// noise. The code must mix letters and digits — a pure number after
    /// the keyword is an order id, not a code.
    private static let bookingRegex = try! NSRegularExpression(
        pattern: #"\b(?:PNR|booking\s+code|confirmation\s+code|reservation\s+code|booking\s+reference|confirmation\s+number)\b\s*[:=\-]?\s*([A-Z0-9]{6})\b"#,
        options: .caseInsensitive)

    private static func bookingMatches(in text: String) -> [(EntityHit, NSRange)] {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        var hits: [(EntityHit, NSRange)] = []
        for match in bookingRegex.matches(in: text, range: range) {
            let code = ns.substring(with: match.range(at: 1))
            guard code.contains(where: \.isLetter), code.contains(where: \.isNumber) else { continue }
            hits.append((EntityHit(kind: .booking, value: code, normalized: 0, currency: nil), match.range))
        }
        return hits
    }

    // MARK: Domains (shared)

    /// Host of an http(s) URL, and bare hosts ending in a small allowlist
    /// of common top-level domains. Values fold to lowercase (domain names
    /// are case-insensitive). File names ("invoice.pdf"), version strings
    /// ("v1.2.3"), and unknown top-level domains ("foo.bar") stay out.
    private static let urlHostRegex = try! NSRegularExpression(
        pattern: #"https?://([A-Za-z0-9.-]+)"#)
    private static let bareHostRegex = try! NSRegularExpression(
        pattern: "\\b(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\\.)+(?:"
            + ["com", "org", "net", "edu", "gov", "io", "dev", "app", "info", "me", "xyz",
               "de", "uk", "fr", "jp", "cn", "nl", "se", "ch", "it", "es", "eu", "ca",
               "au", "co"].joined(separator: "|")
            + ")\\b")

    private static func domainMatches(in text: String) -> [(EntityHit, NSRange)] {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        var hits: [(EntityHit, NSRange)] = []
        for match in urlHostRegex.matches(in: text, range: range) {
            var host = ns.substring(with: match.range(at: 1)).lowercased()
            while host.hasSuffix(".") { host.removeLast() }
            guard !host.isEmpty else { continue }
            hits.append((EntityHit(kind: .domain, value: host, normalized: 0, currency: nil), match.range))
        }
        for match in bareHostRegex.matches(in: text, range: range) {
            let host = ns.substring(with: match.range).lowercased()
            hits.append((EntityHit(kind: .domain, value: host, normalized: 0, currency: nil), match.range))
        }
        return hits
    }

    #if canImport(Darwin)
    /// On macOS, the platform detector adds dates and phones the shared
    /// patterns do not carry (multilingual month names, national phone
    /// formats), skipping any match that overlaps a shared hit. A detector
    /// date counts only when the written form carries a full date — a
    /// four-digit year and a day number; weekday and relative references
    /// stay out. A date-only form normalizes to midnight UTC of its day,
    /// like the shared patterns; the detector otherwise fills in a default
    /// hour.
    private static let detector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.date.rawValue
            | NSTextCheckingResult.CheckingType.phoneNumber.rawValue)

    private static func detectorMatches(in text: String, occupied: [NSRange]) -> [(EntityHit, NSRange)] {
        guard let detector else { return [] }
        let ns = text as NSString
        var hits: [(EntityHit, NSRange)] = []
        for match in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if match.resultType.contains(.date), let date = match.date {
                let value = ns.substring(with: match.range)
                // Only full dates pass: a four-digit year and a standalone
                // one- or two-digit day. Weekday and relative references
                // ("Friday", "next Tuesday", "today") and month-year or
                // time-only fragments are not entities.
                let full = value.range(of: "\\b\\d{4}\\b", options: .regularExpression) != nil
                    && value.range(of: "\\b\\d{1,2}(?:st|nd|rd|th)?\\b", options: .regularExpression) != nil
                guard full else { continue }
                let zone = match.timeZone ?? TimeZone(identifier: "UTC")!
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = zone
                let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
                guard let year = parts.year, let month = parts.month, let day = parts.day else { continue }
                var hour = parts.hour ?? 0
                var minute = parts.minute ?? 0
                // A written form without a time of day normalizes to
                // midnight, like the shared patterns; the detector
                // otherwise fills in a default hour.
                if value.range(of: "\\b\\d{1,2}:\\d{2}\\b", options: .regularExpression) == nil {
                    hour = 0
                    minute = 0
                }
                let epoch = epoch(year: year, month: month, day: day, hour: hour, minute: minute)
                guard let epoch else { continue }
                hits.append((EntityHit(kind: .date, value: value, normalized: epoch, currency: nil), match.range))
            } else if match.resultType.contains(.phoneNumber), let phone = match.phoneNumber {
                hits.append((EntityHit(kind: .phone, value: phone, normalized: 0, currency: nil), match.range))
            }
        }
        return hits.filter { _, range in
            !occupied.contains { NSIntersectionRange($0, range).length > 0 }
        }
    }
    #endif
}
