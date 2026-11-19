// Query language (DESIGN 6A): the Gmail-style search grammar a person types,
// parsed into a boolean tree, then compiled for execution. Compilation
// tokenizes text with the same pipeline ingest used (decision 0007), so a
// query matches what was indexed. The compiler emits leaves the executor
// runs: FTS5 MATCH expressions over the pre-tokenized columns, and SQL
// predicates over the message and its related tables.

import Foundation

/// Errors thrown while parsing or compiling a query; each carries enough
/// context for a UI to point at the offending text.
public enum QueryError: Error, Equatable, Sendable {
    case unbalancedParenthesis
    case danglingOR
    case emptyGroup
    case missingOperatorValue(op: String)
    case badOperatorValue(op: String, value: String, reason: String)
}

/// Which indexed text fields a term applies to.
public enum SearchField: String, Sendable, CaseIterable {
    case any, subject, sender, recipient, body
}

/// Recipient side for to:/cc:/bcc:.
public enum RecipientKind: String, Sendable, Equatable {
    case to, cc, bcc
}

/// The `is:` states M1 answers from the index.
public enum FlagKind: String, Sendable, CaseIterable {
    case unread, starred, sent
}

/// A half-open UTC time span as ISO-8601 instants; a nil side is open.
public struct DateRange: Sendable, Equatable {
    public var start: String?
    public var end: String?

    public init(start: String?, end: String?) {
        self.start = start
        self.end = end
    }
}

/// The parsed query: a boolean tree of clauses. OR binds looser than the
/// implicit AND between adjacent terms, as in Gmail.
public indirect enum SearchNode: Sendable, Equatable {
    case and([SearchNode])
    case or([SearchNode])
    case not(SearchNode)
    case clause(Clause)
}

public enum Clause: Sendable, Equatable {
    /// Unquoted words, or a quoted phrase. Raw text; the compiler tokenizes.
    case text(SearchField, String)
    case phrase(SearchField, String)
    case from(String)
    case recipient(RecipientKind, String)
    case hasAttachment(Bool)
    case filename(String)
    case fileType(String)
    case label(String)
    case folder(String)
    case account(String)
    case flag(FlagKind)
    /// Exclusive upper bound as an ISO-8601 UTC instant.
    case before(String)
    /// Inclusive lower bound as an ISO-8601 UTC instant.
    case after(String)
    case on(DateRange)
    case during(DateRange)
    /// Size bounds in bytes.
    case larger(Int)
    case smaller(Int)
    /// Exact domain of the From address (subdomains excluded).
    case domain(String)
    /// Money amounts and currencies: extracted at ingest into the entity
    /// store (DESIGN 6A), queried with numeric comparisons.
    case amount(String)
}

// MARK: - Parser

public enum QueryParser {
    /// Parses one query line. Returns nil for an empty (or all-whitespace)
    /// query, which callers treat as "browse everything".
    ///
    /// `now` pins the instant natural-language dates resolve against
    /// ("last March", "this week"); it defaults to the current time and
    /// threads down to every date operator, so one line parses as one
    /// moment.
    public static func parse(_ query: String, now: Date? = nil) throws -> SearchNode? {
        let now = now ?? Date()
        let tokens = scan(query)
        guard !tokens.isEmpty else { return nil }
        var index = 0
        let node = try parseOr(tokens, &index, now)
        guard index == tokens.count else { throw QueryError.unbalancedParenthesis }
        return node
    }

    // MARK: Scanner

    enum ScanToken: Equatable {
        case word(String)
        case quoted(String)
        case open
        case close
    }

    /// Splits the raw text into words, quoted strings, and parentheses.
    /// Quotes keep spaces and parentheses literal. An unterminated quote
    /// runs to the end of the input (tolerant, like a mail search field).
    static func scan(_ query: String) -> [ScanToken] {
        var tokens: [ScanToken] = []
        var word = String.UnicodeScalarView()
        let scalars = query.unicodeScalars
        var index = scalars.startIndex

        func flush() {
            guard !word.isEmpty else { return }
            tokens.append(.word(String(word)))
            word = String.UnicodeScalarView()
        }
        func next() {
            index = scalars.index(after: index)
        }

        while index < scalars.endIndex {
            let scalar = scalars[index]
            switch scalar {
            case "(":
                flush()
                tokens.append(.open)
                next()
            case ")":
                flush()
                tokens.append(.close)
                next()
            case "\"":
                flush()
                next()
                var content = String.UnicodeScalarView()
                while index < scalars.endIndex, scalars[index] != "\"" {
                    content.append(scalars[index])
                    next()
                }
                tokens.append(.quoted(String(content)))
                if index < scalars.endIndex { next() }
            default:
                if scalar.properties.isWhitespace {
                    flush()
                    next()
                } else {
                    word.append(scalar)
                    next()
                }
            }
        }
        flush()
        return tokens
    }

    // MARK: Grammar

    /// or := and (OR and)*  — OR binds loosest.
    static func parseOr(_ tokens: [ScanToken], _ index: inout Int, _ now: Date) throws -> SearchNode {
        var alternatives: [SearchNode] = []
        var current: [SearchNode] = []
        var sawOR = false

        func flush() {
            guard !current.isEmpty else { return }
            alternatives.append(current.count == 1 ? current[0] : .and(current))
            current = []
        }

        while index < tokens.count {
            if case .close = tokens[index] { break }
            if case .word(let w) = tokens[index], w == "OR" {
                flush()
                index += 1
                sawOR = true
                guard index < tokens.count, !isDelimiter(tokens[index]) else {
                    throw QueryError.danglingOR
                }
                continue
            }
            current.append(try parseAtom(tokens, &index, now))
        }
        if sawOR && alternatives.isEmpty { throw QueryError.danglingOR }
        flush()

        if alternatives.isEmpty {
            guard let first = current.first else { throw QueryError.emptyGroup }
            return current.count == 1 ? first : .and(current)
        }
        return alternatives.count == 1 ? alternatives[0] : .or(alternatives)
    }

    static func isDelimiter(_ token: ScanToken) -> Bool {
        if case .close = token { return true }
        if case .word(let w) = token, w == "OR" { return true }
        return false
    }

    static func isClose(_ token: ScanToken) -> Bool {
        if case .close = token { return true }
        return false
    }

    static func parseAtom(_ tokens: [ScanToken], _ index: inout Int, _ now: Date) throws -> SearchNode {
        switch tokens[index] {
        case .open:
            index += 1
            guard index < tokens.count, !isClose(tokens[index]) else {
                throw QueryError.emptyGroup
            }
            let inner = try parseOr(tokens, &index, now)
            guard index < tokens.count, isClose(tokens[index]) else {
                throw QueryError.unbalancedParenthesis
            }
            index += 1
            return inner
        case .quoted(let text):
            index += 1
            return textClause(text, quoted: true)
        case .word(let word):
            index += 1
            return try parseWord(word, tokens, &index, now)
        case .close:
            throw QueryError.unbalancedParenthesis
        }
    }

    /// One word: a negation, an operator with a value, or a plain term.
    static func parseWord(_ word: String, _ tokens: [ScanToken], _ index: inout Int, _ now: Date) throws -> SearchNode {
        if word == "-" {
            guard index < tokens.count else { throw QueryError.missingOperatorValue(op: "-") }
            return .not(try parseAtom(tokens, &index, now))
        }
        if word.hasPrefix("-") {
            return .not(try parseWord(String(word.dropFirst()), tokens, &index, now))
        }

        guard let colon = word.firstIndex(of: ":") else {
            return textClause(word, quoted: false)
        }
        let op = String(word[word.startIndex..<colon]).lowercased()
        var value = String(word[word.index(after: colon)...])
        if value.isEmpty {
            // The value may be a quoted string or the next word.
            guard index < tokens.count else { throw QueryError.missingOperatorValue(op: op) }
            switch tokens[index] {
            case .quoted(let quoted):
                value = quoted
                index += 1
            case .word(let next):
                if next == "OR" || next == ")" { throw QueryError.missingOperatorValue(op: op) }
                value = next
                index += 1
            default:
                throw QueryError.missingOperatorValue(op: op)
            }
        }
        return .clause(try clause(for: op, value: trimming(value), now: now))
    }

    static func trimming(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespaces)
    }

    /// A plain term: quoted text with spaces is a phrase, everything else
    /// matches as free text over the searchable fields.
    static func textClause(_ raw: String, quoted: Bool) -> SearchNode {
        let trimmed = trimming(raw)
        guard !trimmed.isEmpty else {
            return .clause(.text(.any, ""))
        }
        if quoted, trimmed.contains(where: { $0.isWhitespace }) {
            return .clause(.phrase(.any, trimmed))
        }
        return .clause(.text(.any, trimmed))
    }

    // MARK: Operators

    /// `type:` classes M1 knows, each with the extensions and MIME types it
    /// matches. `unknown` values are rejected at parse time so the UI can
    /// suggest the right word.
    public static let fileTypeClasses: [String] = [
        "pdf", "image", "doc", "spreadsheet", "presentation",
        "archive", "calendar", "contact", "text", "audio", "video",
    ]

    static func clause(for op: String, value: String, now: Date) throws -> Clause {
        func bad(_ reason: String) -> QueryError {
            .badOperatorValue(op: op, value: value, reason: reason)
        }
        switch op {
        case "from": return .from(value)
        case "to": return .recipient(.to, value)
        case "cc": return .recipient(.cc, value)
        case "bcc": return .recipient(.bcc, value)
        case "subject": return .text(.subject, value)
        case "body": return .text(.body, value)
        case "has":
            guard value.lowercased() == "attachment" else {
                throw bad("only attachment is supported")
            }
            return .hasAttachment(true)
        case "filename": return .filename(value)
        case "type":
            let kind = value.lowercased()
            guard fileTypeClasses.contains(kind) else {
                throw bad("known types: \(fileTypeClasses.joined(separator: ", "))")
            }
            return .fileType(kind)
        case "label": return .label(value)
        case "folder": return .folder(value)
        case "account": return .account(value)
        case "is":
            guard let kind = FlagKind(rawValue: value.lowercased()) else {
                throw bad("known states: \(FlagKind.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            return .flag(kind)
        case "before": return .before(try dateBound(value, op: op, now: now))
        case "after": return .after(try dateBound(value, op: op, now: now))
        case "on": return .on(try dateSpan(value, op: op, now: now))
        case "during": return .during(try dateSpan(value, op: op, now: now))
        case "larger": return .larger(try byteSize(value, op: op))
        case "smaller": return .smaller(try byteSize(value, op: op))
        case "domain": return .domain(value)
        case "amount": return .amount(value)
        default: return .text(.any, "\(op):\(value)")
        }
    }

    // MARK: Values

    /// Parses `2019`, `2019-06`, `2019-06-01`, each optionally with a
    /// `T12:30[:ss]` time, into an ISO-8601 UTC instant string that sorts
    /// the same way the stored date columns do.
    static func dateBound(_ value: String, op: String, now: Date) throws -> String {
        func bad(_ reason: String) -> QueryError {
            .badOperatorValue(op: op, value: value, reason: reason)
        }
        // Natural forms ("last March") resolve to a span; before and after
        // take its start instant (DESIGN 6A, decision 0034).
        switch NaturalDate.resolve(value, now: now) {
        case .span(let range):
            guard let start = range.start else {
                throw bad("expected a date, optionally with a time")
            }
            return start
        case .invalid(let reason):
            throw bad(reason)
        case .notNatural:
            break
        }
        let normalized = value.replacingOccurrences(of: " ", with: "T")
        let parts = normalized.split(separator: "T", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { throw bad("expected a date, optionally with a time") }

        let day = try calendarDay(String(parts[0]), bad)
        var (hour, minute, second) = (0, 0, 0)
        if parts.count == 2 {
            let time = parts[1].split(separator: ":", omittingEmptySubsequences: false)
            guard (2...3).contains(time.count) else { throw bad("time looks like T12:30") }
            hour = try number(time[0], 0, 23, bad)
            minute = try number(time[1], 0, 59, bad)
            if time.count == 3 { second = try number(time[2], 0, 59, bad) }
        }
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02dZ", day.0, day.1, day.2, hour, minute, second)
    }

    /// Parses `2019`, `2019-06`, `2019-06-01` into the half-open span those
    /// words cover. Times are not accepted here.
    static func dateSpan(_ value: String, op: String, now: Date) throws -> DateRange {
        func bad(_ reason: String) -> QueryError {
            .badOperatorValue(op: op, value: value, reason: reason)
        }
        // Natural forms ("last March", "this month") resolve first; the
        // numeric grammar keeps ownership of everything else (DESIGN 6A,
        // decision 0034).
        switch NaturalDate.resolve(value, now: now) {
        case .span(let range):
            return range
        case .invalid(let reason):
            throw bad(reason)
        case .notNatural:
            break
        }
        guard !value.contains("T"), !value.contains(" ") else {
            throw bad("on and during take a date without a time")
        }
        let (y, m, d) = try calendarDay(value, bad)
        if d != 1 || m != 1 {
            // A month or a single day.
            if d == 1 {
                let (nextY, nextM) = m == 12 ? (y + 1, 1) : (y, m + 1)
                return DateRange(
                    start: String(format: "%04d-%02d-01T00:00:00Z", y, m),
                    end: String(format: "%04d-%02d-01T00:00:00Z", nextY, nextM)
                )
            }
            let (nextY, nextM, nextD) = nextDay(y, m, d)
            return DateRange(
                start: String(format: "%04d-%02d-%02dT00:00:00Z", y, m, d),
                end: String(format: "%04d-%02d-%02dT00:00:00Z", nextY, nextM, nextD)
            )
        }
        return DateRange(
            start: String(format: "%04d-01-01T00:00:00Z", y),
            end: String(format: "%04d-01-01T00:00:00Z", y + 1)
        )
    }

    /// `2019`, `2019-06`, `2019-06-01` -> (y, m, d) with range checks.
    static func calendarDay(
        _ text: String, _ bad: (String) -> QueryError
    ) throws -> (Int, Int, Int) {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty }) else {
            throw bad("dates look like 2019, 2019-06, or 2019-06-01")
        }
        let y = try number(parts[0], 0, 9999, bad)
        var m = 1
        var d = 1
        if parts.count >= 2 { m = try number(parts[1], 1, 12, bad) }
        if parts.count >= 3 {
            d = try number(parts[2], 1, days(in: m, year: y), bad)
        }
        return (y, m, d)
    }

    static func nextDay(_ y: Int, _ m: Int, _ d: Int) -> (Int, Int, Int) {
        if d < days(in: m, year: y) { return (y, m, d + 1) }
        if m < 12 { return (y, m + 1, 1) }
        return (y + 1, 1, 1)
    }

    static func days(in month: Int, year: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        default:
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return leap ? 29 : 28
        }
    }

    static func number(_ text: some StringProtocol, _ low: Int, _ high: Int, _ bad: (String) -> QueryError) throws -> Int {
        guard let value = Int(text), text.allSatisfy(\.isNumber), value >= low, value <= high else {
            throw bad("expected a number between \(low) and \(high)")
        }
        return value
    }

    /// `5mb`, `1.5kb`, `2gb`, `300b` -> bytes.
    static func byteSize(_ value: String, op: String) throws -> Int {
        let lowered = value.lowercased()
        let unit: (multiplier: Double, text: String)
        if lowered.hasSuffix("gb") { unit = (1_073_741_824, "gb") }
        else if lowered.hasSuffix("mb") { unit = (1_048_576, "mb") }
        else if lowered.hasSuffix("kb") { unit = (1_024, "kb") }
        else if lowered.hasSuffix("b") { unit = (1, "b") }
        else { throw QueryError.badOperatorValue(op: op, value: value, reason: "sizes end in b, kb, mb, or gb") }
        let digits = String(lowered.dropLast(unit.text.count))
        guard let amount = Double(digits), amount.isFinite, amount >= 0 else {
            throw QueryError.badOperatorValue(op: op, value: value, reason: "expected a number of bytes")
        }
        return Int(amount * unit.multiplier)
    }
}

// MARK: - Compiler

/// One SQL predicate evaluated against the `message` table aliased as `m`.
public struct SQLFilter: Sendable, Equatable {
    public var sql: String
    public var arguments: [String]

    public init(sql: String, arguments: [String]) {
        self.sql = sql
        self.arguments = arguments
    }
}

/// The compiled shape of a query: leaves the executor runs directly.
public indirect enum CompiledNode: Sendable, Equatable {
    /// A text leaf: the exact-token MATCH expression over the message_text
    /// columns, with its optional trigram fallback (DESIGN 6A, M2.1).
    case fts(FTSLeaf)
    case filter(SQLFilter)
    case and([CompiledNode])
    case or([CompiledNode])
    case not(CompiledNode)
}

public struct CompiledQuery: Sendable, Equatable {
    public var root: CompiledNode
    /// Operators whose value parsed to nothing usable (e.g. an unparseable
    /// `amount:` value); each such clause matches nothing on its own.
    public var warnings: [String]

    public init(root: CompiledNode, warnings: [String]) {
        self.root = root
        self.warnings = warnings
    }
}

public enum QueryCompiler {
    /// message_text column order; the bm25 weight list must match it. The
    /// three stem columns (decision 0026) mirror subject, body, and quoted
    /// and hold the Snowball stems; they rank below the original columns so
    /// an exact match always beats a stem-only match.
    static let columns = [
        "subject", "from_name", "from_addr", "recipients", "body", "quoted", "attachments",
        "subject_stem", "body_stem", "quoted_stem", "from_name_stem",
    ]
    /// Field weights (DESIGN 6A): subject ranks highest, then sender name
    /// and address, then other recipients, then the body; quoted text and
    /// attachment names barely count. The stem columns (decisions 0026 and
    /// 0030) rank below their originals: subject_stem 1.0, body_stem 0.2,
    /// quoted_stem 0.1, from_name_stem 0.5.
    public static let bm25Weights = "12.0, 8.0, 6.0, 5.0, 1.0, 0.4, 0.3, 1.0, 0.2, 0.1, 0.5"
    /// Fields bare terms search: everything indexed at message level except
    /// quoted text (which only phrase-quoted terms reach, at low weight).
    static let bareColumns = "{subject from_name from_addr recipients body attachments}"
    /// Columns an unquoted-field phrase searches: the bare columns plus
    /// quoted text, so a phrase like `"budget looks fine"` still finds a
    /// reply's quoted text — at quoted's low rank (DESIGN 6A).
    static let phraseColumns = "{subject from_name from_addr recipients body quoted attachments}"
    /// The stem columns a field's stem forms search (decision 0026). Only
    /// subject, body, and quoted are stemmed at index time, so sender and
    /// recipient have no stem columns and their tokens are not stem-expanded.
    /// For `.any`, a bare term reaches subject and body (not quoted), while a
    /// phrase also reaches quoted — mirroring bareColumns / phraseColumns.
    static func stemColumns(field: SearchField, phrase: Bool) -> String? {
        switch field {
        case .subject: return "{subject_stem}"
        case .body: return "{body_stem}"
        case .any: return phrase ? "{subject_stem body_stem quoted_stem}" : "{subject_stem body_stem from_name_stem}"
        case .sender: return "{from_name_stem}"
        case .recipient: return nil
        }
    }
    /// Joins clause strings with an operator, wrapping the result in
    /// parentheses when more than one clause is joined. FTS5 column filters
    /// bind only to the phrase or parenthesized group that immediately
    /// follows them — `{a} : x AND y` searches y across all columns — so a
    /// compound leaf expression must carry its own parentheses to keep every
    /// operand inside the field's column set (verified against sqlite3).
    static func parenthesizedJoin(_ parts: [String], _ op: String) -> String {
        guard parts.count > 1 else { return parts.first ?? "" }
        return "(" + parts.joined(separator: " \(op) ") + ")"
    }

    /// Compiles a parsed query. With `asYouType` the last text or phrase
    /// clause in reading order carries the active prefix: its final token
    /// compiles as an FTS5 prefix match (`kickof*`), so the ranked path
    /// covers the word being typed while the gate allows it (decision 0025).
    /// With `language` (the query's detected language, decision 0026) every
    /// text token expands to its forms: the folded form, the stem in that
    /// language, and the stem in English — so a wrong language guess can
    /// never lose the exact match.
    public static func compile(
        _ node: SearchNode, asYouType: Bool = false, language: String? = nil
    ) throws -> CompiledQuery {
        var warnings: [String] = []
        let merged = Self.mergeAdjacentText(node)
        let textCount = Self.countTextClauses(merged)
        let prefixLast: Int? = asYouType && textCount > 0 ? textCount - 1 : nil
        // The English stemmer is always available (it is vendored); the
        // detected-language session only when detection produced one.
        let detected = language.flatMap { StemmingSession(language: $0) }
        let english = StemmingSession(language: "en")
        var seen = 0
        let root = try compileNode(
            merged, prefixLast: prefixLast, seen: &seen,
            detected: detected, english: english, into: &warnings
        )
        return CompiledQuery(root: root, warnings: warnings)
    }

    /// Number of text and phrase clauses in a query tree, counted in
    /// depth-first, left-to-right order.
    static func countTextClauses(_ node: SearchNode) -> Int {
        switch node {
        case .and(let children), .or(let children):
            return children.reduce(0) { $0 + countTextClauses($1) }
        case .not(let inner):
            return countTextClauses(inner)
        case .clause(.text), .clause(.phrase):
            return 1
        case .clause:
            return 0
        }
    }

    /// Merges runs of adjacent unfielded free-text clauses into one clause,
    /// so "budget review notes" compiles to ONE text leaf and runs as one
    /// ranked FTS5 MATCH (DESIGN 6A). The parser makes one clause per word;
    /// compiled per-word leaves would AND as rowid subqueries in the
    /// predicate path — correct matches, but no relevance ranking and a
    /// posting walk plus date sort per word. Phrases, field filters,
    /// negations, and CJK terms break a run: each keeps its own semantics
    /// (column sets, quoted-column reach, eager trigram fallbacks). CJK
    /// terms stay unmerged so each keeps its whole-run fallback phrase.
    static func mergeAdjacentText(_ node: SearchNode) -> SearchNode {
        switch node {
        case .clause:
            return node
        case .not(let inner):
            return .not(mergeAdjacentText(inner))
        case .or(let children):
            return .or(children.map(mergeAdjacentText))
        case .and(let children):
            var out: [SearchNode] = []
            var run: [String] = []
            func flush() {
                guard run.count > 1 else {
                    if let single = run.first { out.append(.clause(.text(.any, single))) }
                    run = []
                    return
                }
                out.append(.clause(.text(.any, run.joined(separator: " "))))
                run = []
            }
            for child in children {
                switch child {
                case .clause(.text(.any, let raw)) where !raw.isEmpty && !TokenPipeline.containsCJK(raw):
                    run.append(raw)
                default:
                    flush()
                    out.append(mergeAdjacentText(child))
                }
            }
            flush()
            if out.count == 1 { return out[0] }
            return .and(out)
        }
    }

    static func compileNode(
        _ node: SearchNode, prefixLast: Int?, seen: inout Int,
        detected: StemmingSession?, english: StemmingSession?, into warnings: inout [String]
    ) throws -> CompiledNode {
        switch node {
        case .and(let children):
            return .and(try children.map {
                try compileNode($0, prefixLast: prefixLast, seen: &seen, detected: detected, english: english, into: &warnings)
            })
        case .or(let children):
            return .or(try children.map {
                try compileNode($0, prefixLast: prefixLast, seen: &seen, detected: detected, english: english, into: &warnings)
            })
        case .not(let inner):
            return .not(try compileNode(inner, prefixLast: prefixLast, seen: &seen, detected: detected, english: english, into: &warnings))
        case .clause(let clause):
            return try compileClause(clause, prefixLast: prefixLast, seen: &seen, detected: detected, english: english, into: &warnings)
        }
    }

    // MARK: Clauses

    static func compileClause(
        _ clause: Clause, prefixLast: Int?, seen: inout Int,
        detected: StemmingSession?, english: StemmingSession?, into warnings: inout [String]
    ) throws -> CompiledNode {
        switch clause {
        case .text(let field, let raw):
            let prefix = seen == prefixLast
            seen += 1
            return try textNode(field: field, raw: raw, phrase: false, prefixLast: prefix, detected: detected, english: english)
        case .phrase(let field, let raw):
            let prefix = seen == prefixLast
            seen += 1
            return try textNode(field: field, raw: raw, phrase: true, prefixLast: prefix, detected: detected, english: english)
        case .from(let value):
            return fromNode(value, detected: detected, english: english)
        case .recipient(let kind, let value):
            return recipientNode(kind: kind, value: value)
        case .hasAttachment(let wanted):
            let exists = "EXISTS (SELECT 1 FROM attachment a WHERE a.messageID = m.id)"
            return .filter(SQLFilter(sql: wanted ? exists : "NOT \(exists)", arguments: []))
        case .filename(let value):
            return .filter(SQLFilter(
                sql: "EXISTS (SELECT 1 FROM attachment a WHERE a.messageID = m.id AND a.filename LIKE ? ESCAPE '\\')",
                arguments: ["%\(escapeLike(TokenPipeline.folded(value)))%"]
            ))
        case .fileType(let kind):
            return fileTypeNode(kind)
        case .label(let value):
            return .filter(SQLFilter(
                sql: """
                EXISTS (SELECT 1 FROM message_label ml JOIN label l ON l.id = ml.labelID
                        WHERE ml.messageID = m.id AND l.name LIKE ? ESCAPE '\\')
                """,
                arguments: [escapeLike(TokenPipeline.folded(value))]
            ))
        case .folder(let value):
            return .filter(SQLFilter(
                sql: """
                EXISTS (SELECT 1 FROM message_mailbox mm JOIN mailbox mb ON mb.id = mm.mailboxID
                        WHERE mm.messageID = m.id AND mb.name LIKE ? ESCAPE '\\')
                """,
                arguments: ["%\(escapeLike(TokenPipeline.folded(value)))%"]
            ))
        case .account(let value):
            return .filter(SQLFilter(
                sql: """
                EXISTS (SELECT 1 FROM message_mailbox mm
                        JOIN mailbox mb ON mb.id = mm.mailboxID
                        JOIN account ac ON ac.id = mb.accountID
                        WHERE mm.messageID = m.id AND ac.email LIKE ? ESCAPE '\\')
                """,
                arguments: ["%\(escapeLike(TokenPipeline.folded(value)))%"]
            ))
        case .flag(let kind):
            return flagNode(kind)
        case .before(let bound):
            return .filter(SQLFilter(
                sql: "COALESCE(m.dateSent, m.dateReceived) < ?",
                arguments: [bound]
            ))
        case .after(let bound):
            return .filter(SQLFilter(
                sql: "COALESCE(m.dateSent, m.dateReceived) >= ?",
                arguments: [bound]
            ))
        case .on(let range), .during(let range):
            return dateRangeNode(range)
        case .larger(let bytes):
            return .filter(SQLFilter(sql: "m.size >= ?", arguments: ["\(bytes)"]))
        case .smaller(let bytes):
            return .filter(SQLFilter(sql: "m.size <= ?", arguments: ["\(bytes)"]))
        case .domain(let value):
            return .filter(SQLFilter(
                sql: "m.fromEmail LIKE ? ESCAPE '\\'",
                arguments: ["%@\(escapeLike(TokenPipeline.folded(value)))"]
            ))
        case .amount(let raw):
            guard let comparison = AmountComparison(raw) else {
                warnings.append(
                    "amount: expected a number, optionally preceded by >, >=, <, <= or = (like amount:>100); this part matches nothing"
                )
                return .filter(SQLFilter(sql: "1 = 0", arguments: []))
            }
            return .filter(SQLFilter(
                sql: """
                EXISTS (SELECT 1 FROM message_entity e WHERE e.messageID = m.id \
                AND e.kind = 'amount' AND e.normalized \(comparison.op) ?)
                """,
                arguments: [comparison.bound]
            ))
        }
    }

    /// The parsed value of an `amount:` query: an optional comparison
    /// operator (defaults to equals) and a decimal number. Thousands
    /// separators in the query are accepted and dropped; anything else —
    /// "abc", ">", "" — fails to parse and the compiler warns.
    struct AmountComparison: Equatable, Sendable {
        /// One of "=", ">", "<", ">=", "<=", substituted into the SQL
        /// predicate from this closed set.
        var op: String
        var value: Double

        /// The parameter bound into SQL: fixed six-decimal form so the
        /// query path never depends on Double's default description.
        var bound: String { String(format: "%.6f", value) }

        init?(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            var op = "="
            var rest = trimmed[...]
            for candidate in [">=", "<=", ">", "<", "="] where trimmed.hasPrefix(candidate) {
                op = candidate
                rest = trimmed.dropFirst(candidate.count)
                break
            }
            let numberText = rest.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: ",", with: "")
            guard Self.isPlainNumber(numberText), let value = Double(numberText) else {
                return nil
            }
            self.op = op
            self.value = value
        }

        private static func isPlainNumber(_ s: String) -> Bool {
            var dots = 0
            for character in s {
                if character == "." {
                    dots += 1
                    if dots > 1 { return false }
                    continue
                }
                guard character.isASCII, character.isNumber else { return false }
            }
            return !s.isEmpty
        }
    }

    static func textNode(
        field: SearchField, raw: String, phrase: Bool, prefixLast: Bool = false,
        detected: StemmingSession?, english: StemmingSession?
    ) throws -> CompiledNode {
        let tokens = TokenPipeline.tokens(for: raw, field: textColumn(field))
        guard !tokens.isEmpty else {
            // Pure punctuation or noise: honest zero results, not "match all".
            return .filter(SQLFilter(sql: "1 = 0", arguments: []))
        }
        let columns: String
        switch field {
        case .any: columns = phrase ? phraseColumns : bareColumns
        case .subject: columns = "{subject}"
        case .sender: columns = "{from_name from_addr}"
        case .recipient: columns = "{recipients}"
        case .body: columns = "{body}"
        }
        let inner = columns.dropFirst().dropLast()
        let stemCols = Self.stemColumns(field: field, phrase: phrase)
        // Stemming (DESIGN 6A, decision 0026): the folded forms stay in the
        // original columns, where phrases keep their adjacency; the stems go
        // in the stem columns, which give term recall. A wrong language guess
        // can never lose the exact match, because the folded forms are always
        // searched in the original columns.
        let folded = tokens
        let allStems = tokens.map {
            Stemming.stemForms($0, detected: detected, english: english)
        }
        let expression: String
        if phrase {
            // A phrase is the OR of the folded phrase (original columns,
            // adjacency preserved) and one stem phrase per language (stem
            // columns): "running budgets" matches the indexed stem stream
            // "run budget". A message's stems are all in its one detected
            // language, so per-language phrases are the honest matches; a
            // mixed per-token combination could only match where the stems
            // coincide, which the pure phrases already cover.
            let origPhrase = folded.joined(separator: " ")
            // The prefix marker sits outside the quotes: "phrase"* is the
            // FTS5 prefix form; "phrase*" would match the literal token
            // "phrase*".
            let origPart = prefixLast ? "\"\(origPhrase)\"*" : "\"\(origPhrase)\""
            var parts = ["{\(inner)} : \(origPart)"]
            if let stemCols {
                // An OR group cannot live inside a quoted FTS5 phrase, so
                // the active prefix emits one phrase per candidate ("runn"
                // offers "runn" and the stems of its own prefixes, which
                // reach the indexed stem "run" of "running").
                let last = tokens.count - 1
                var stemPhrases: [String] = []
                for session in [detected, english] {
                    guard let session else { continue }
                    let stemTokens = tokens.map { session.transform($0) }
                    if prefixLast {
                        let candidates = Stemming.prefixCandidates(
                            tokens[last], detected: detected, english: english
                        )
                        for candidate in candidates {
                            var withCandidate = stemTokens
                            withCandidate[last] = candidate
                            let stemPhrase = withCandidate.joined(separator: " ")
                            if !stemPhrases.contains(stemPhrase) {
                                stemPhrases.append(stemPhrase)
                            }
                        }
                    } else {
                        let stemPhrase = stemTokens.joined(separator: " ")
                        if !stemPhrases.contains(stemPhrase) {
                            stemPhrases.append(stemPhrase)
                        }
                    }
                }
                for stemPhrase in stemPhrases {
                    let marker = prefixLast ? "*" : ""
                    parts.append("\(stemCols) : \"\(stemPhrase)\"\(marker)")
                }
            }
            expression = Self.parenthesizedJoin(parts, "OR")
        } else {
            // A bare term is the AND of per-token groups; each group is the
            // OR of the folded form (original columns) and the stem forms
            // (stem columns). The last token is a prefix when prefixLast.
            let last = tokens.count - 1
            var tokenExprs: [String] = []
            for i in 0..<tokens.count {
                let isPrefix = prefixLast && i == last
                let origTerm = isPrefix ? "\(folded[i])*" : folded[i]
                var parts = ["{\(inner)} : \(origTerm)"]
                if let stemCols {
                    let stemTerm: String
                    if isPrefix {
                        // The typed prefix is rarely a prefix of the indexed
                        // stem ("runn" vs "run"): offer the stems of the
                        // prefix's own prefixes as alternates (decision 0026).
                        let candidates = Stemming.prefixCandidates(
                            folded[i], detected: detected, english: english
                        )
                        stemTerm = Stemming.expression(for: candidates.map { "\($0)*" })
                    } else if allStems[i].isEmpty {
                        // No session (should not happen: English is always
                        // vendored) — fall back to the folded form, which
                        // the stem columns hold for unstemmed tokens.
                        stemTerm = folded[i]
                    } else {
                        stemTerm = Stemming.expression(for: allStems[i])
                    }
                    parts.append("\(stemCols) : \(stemTerm)")
                }
                tokenExprs.append(Self.parenthesizedJoin(parts, "OR"))
            }
            expression = Self.parenthesizedJoin(tokenExprs, "AND")
        }
        // The trigram fallback matches substrings, so it works on the raw
        // text's folded form (punctuation survives), not on the query's
        // tokens alone: CJK tokens are two-character pairs, below the
        // trigram minimum, while the whole CJK run is a real substring
        // candidate. CJK spans differently in the query and the indexed
        // text, so its fallback also runs eagerly in the predicate path,
        // not only on a zero-hit retry (DESIGN 6A, M2.1).
        let foldedRaw = TokenPipeline.folded(raw)
        // The folded raw becomes its own trigram phrase only when it is one
        // run (no whitespace): it rescues punctuation forms ("don't") and
        // whole CJK runs, whose tokenized pieces fall below the trigram
        // minimum. For multi-word text the tokens are the phrases — the raw
        // string would demand adjacency ("hutopuza capu" as one literal
        // substring), which the fallback must not require.
        let fallbackPhrases: [String]
        if phrase {
            fallbackPhrases = [foldedRaw]
        } else if foldedRaw.contains(where: \.isWhitespace) {
            fallbackPhrases = tokens
        } else {
            fallbackPhrases = tokens + [foldedRaw]
        }
        return .fts(FTSLeaf(
            // The per-token groups carry their own column filters (original
            // vs stem columns); wrapping them again in the leaf's base
            // columns would NARROW the stem half to an empty set, because
            // nested FTS5 column filters intersect. No outer wrap.
            expression: expression,
            trigramFallback: TrigramPlan.fallback(columns: String(inner), phrases: fallbackPhrases),
            trigramEager: TokenPipeline.containsCJK(raw)
        ))
    }

    static func textColumn(_ field: SearchField) -> TextField {
        switch field {
        case .any, .body: return .body
        case .subject: return .subject
        case .sender: return .sender
        case .recipient: return .recipient
        }
    }

    /// from:value with an @ searches the address column as a folded phrase
    /// (so `jane.doe@example.com` matches that exact address); otherwise it
    /// matches tokens across the sender's name and address, each token's
    /// group adding its stem forms on the sender stem column (decision
    /// 0030). Addresses never stem.
    static func fromNode(
        _ value: String, detected: StemmingSession?, english: StemmingSession?
    ) -> CompiledNode {
        if value.contains("@") {
            let folded = TokenPipeline.folded(value)
            return .fts(FTSLeaf(
                expression: "{from_addr} : \(quoted(folded))",
                trigramFallback: TrigramPlan.fallback(columns: "from_addr", phrases: [folded])
            ))
        }
        let tokens = TokenPipeline.tokens(for: value, field: .sender)
        guard !tokens.isEmpty else {
            return .filter(SQLFilter(sql: "1 = 0", arguments: []))
        }
        let tokenExprs = tokens.map { token -> String in
            var parts = ["{from_name from_addr} : \(token)"]
            let forms = Stemming.stemForms(token, detected: detected, english: english)
            if !forms.isEmpty {
                parts.append("{from_name_stem} : \(Stemming.expression(for: forms))")
            }
            return Self.parenthesizedJoin(parts, "OR")
        }
        return .fts(FTSLeaf(
            expression: Self.parenthesizedJoin(tokenExprs, "AND"),
            trigramFallback: TrigramPlan.fallback(
                columns: "from_name from_addr", phrases: tokens
            ),
            trigramEager: TokenPipeline.containsCJK(value)
        ))
    }

    /// to/cc/bcc with an @ filters exactly on the parsed address rows;
    /// without one it falls back to tokens over the recipients column,
    /// which cannot distinguish to from cc (documented in DESIGN 6A).
    static func recipientNode(kind: RecipientKind, value: String) -> CompiledNode {
        if value.contains("@") {
            return .filter(SQLFilter(
                sql: """
                EXISTS (SELECT 1 FROM message_address ma JOIN address a ON a.id = ma.addressID
                        WHERE ma.messageID = m.id AND ma.kind = ? AND a.email = ?)
                """,
                arguments: [kind.rawValue, TokenPipeline.folded(value)]
            ))
        }
        let tokens = TokenPipeline.tokens(for: value, field: .recipient)
        guard !tokens.isEmpty else {
            return .filter(SQLFilter(sql: "1 = 0", arguments: []))
        }
        return .fts(FTSLeaf(
            expression: "{recipients} : \(Self.parenthesizedJoin(tokens, "AND"))",
            trigramFallback: TrigramPlan.fallback(columns: "recipients", phrases: tokens),
            trigramEager: TokenPipeline.containsCJK(value)
        ))
    }

    static func flagNode(_ kind: FlagKind) -> CompiledNode {
        switch kind {
        case .unread:
            return .filter(SQLFilter(
                // Unread until every copy of the message is marked seen.
                sql: """
                NOT EXISTS (SELECT 1 FROM message_mailbox mm
                            WHERE mm.messageID = m.id AND mm.flags LIKE '%seen%')
                """,
                arguments: []
            ))
        case .starred:
            return .filter(SQLFilter(
                sql: """
                EXISTS (SELECT 1 FROM message_mailbox mm
                        WHERE mm.messageID = m.id AND mm.flags LIKE '%flagged%')
                """,
                arguments: []
            ))
        case .sent:
            return .filter(SQLFilter(
                sql: """
                (EXISTS (SELECT 1 FROM message_mailbox mm
                         JOIN mailbox mb ON mb.id = mm.mailboxID
                         WHERE mm.messageID = m.id
                           AND (mb.role = 'sent' OR lower(mb.name) LIKE '%sent%'))
                 OR EXISTS (SELECT 1 FROM account ac WHERE lower(ac.email) = m.fromEmail))
                """,
                arguments: []
            ))
        }
    }

    static func fileTypeNode(_ kind: String) -> CompiledNode {
        let spec = Self.fileTypes[kind] ?? ([], [], [])
        var likes: [String] = []
        var arguments: [String] = []
        for ext in spec.0 {
            likes.append("lower(a.filename) LIKE ? ESCAPE '\\'")
            arguments.append("%\(escapeLike(ext))")
        }
        for prefix in spec.1 {
            likes.append("a.contentType LIKE ? ESCAPE '\\'")
            arguments.append("\(escapeLike(prefix))%")
        }
        for exact in spec.2 {
            likes.append("a.contentType LIKE ? ESCAPE '\\'")
            arguments.append("\(escapeLike(exact))%")
        }
        return .filter(SQLFilter(
            sql: "EXISTS (SELECT 1 FROM attachment a WHERE a.messageID = m.id AND (\(likes.joined(separator: " OR "))))",
            arguments: arguments
        ))
    }

    /// (extensions, MIME prefixes, MIME exact prefixes) per `type:` class.
    static let fileTypes: [String: ([String], [String], [String])] = [
        "pdf": ([".pdf"], [], ["application/pdf"]),
        "image": ([".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic", ".tiff", ".tif", ".bmp"], ["image/"], []),
        "doc": ([".doc", ".docx", ".rtf", ".rtfd", ".odt", ".pages"], ["application/msword", "application/vnd.openxmlformats-officedocument.wordprocessingml", "application/rtf"], []),
        "spreadsheet": ([".xls", ".xlsx", ".numbers", ".ods", ".csv"], ["application/vnd.ms-excel", "application/vnd.openxmlformats-officedocument.spreadsheetml", "application/vnd.oasis.opendocument.spreadsheet", "text/csv"], []),
        "presentation": ([".ppt", ".pptx", ".key", ".odp"], ["application/vnd.ms-powerpoint", "application/vnd.openxmlformats-officedocument.presentationml", "application/vnd.oasis.opendocument.presentation"], []),
        "archive": ([".zip", ".tar", ".gz", ".tgz", ".7z", ".rar"], ["application/zip", "application/x-tar", "application/gzip", "application/x-7z-compressed", "application/x-rar-compressed"], []),
        "calendar": ([".ics"], [], ["text/calendar"]),
        "contact": ([".vcf"], [], ["text/vcard"]),
        "text": ([".txt", ".md"], ["text/plain", "text/markdown"], []),
        "audio": ([".mp3", ".m4a", ".wav", ".aac"], ["audio/"], []),
        "video": ([".mp4", ".mov", ".avi", ".mkv"], ["video/"], []),
    ]

    static func dateRangeNode(_ range: DateRange) -> CompiledNode {
        var parts: [String] = []
        var arguments: [String] = []
        if let start = range.start {
            parts.append("COALESCE(m.dateSent, m.dateReceived) >= ?")
            arguments.append(start)
        }
        if let end = range.end {
            parts.append("COALESCE(m.dateSent, m.dateReceived) < ?")
            arguments.append(end)
        }
        guard !parts.isEmpty else { return .filter(SQLFilter(sql: "1 = 1", arguments: [])) }
        return .filter(SQLFilter(sql: parts.joined(separator: " AND "), arguments: arguments))
    }

    // MARK: FTS expression helpers

    /// Wraps text as a double-quoted FTS5 phrase; embedded quotes become
    /// spaces so hostile input cannot break out of the phrase.
    static func quoted(_ text: String) -> String {
        "\"\(text.replacingOccurrences(of: "\"", with: " "))\""
    }

    /// Escapes LIKE wildcards; the caller pairs this with ESCAPE '\'.
    static func escapeLike(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
