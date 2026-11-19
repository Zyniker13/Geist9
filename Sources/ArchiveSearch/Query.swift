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
    /// Money amounts: accepted by the grammar, unbacked in M1.
    case amount(String)
}

// MARK: - Parser

public enum QueryParser {
    /// Parses one query line. Returns nil for an empty (or all-whitespace)
    /// query, which callers treat as "browse everything".
    public static func parse(_ query: String) throws -> SearchNode? {
        let tokens = scan(query)
        guard !tokens.isEmpty else { return nil }
        var index = 0
        let node = try parseOr(tokens, &index)
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
        var scalars = query.unicodeScalars
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
    static func parseOr(_ tokens: [ScanToken], _ index: inout Int) throws -> SearchNode {
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
            current.append(try parseAtom(tokens, &index))
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

    static func parseAtom(_ tokens: [ScanToken], _ index: inout Int) throws -> SearchNode {
        switch tokens[index] {
        case .open:
            index += 1
            guard index < tokens.count, !isClose(tokens[index]) else {
                throw QueryError.emptyGroup
            }
            let inner = try parseOr(tokens, &index)
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
            return try parseWord(word, tokens, &index)
        case .close:
            throw QueryError.unbalancedParenthesis
        }
    }

    /// One word: a negation, an operator with a value, or a plain term.
    static func parseWord(_ word: String, _ tokens: [ScanToken], _ index: inout Int) throws -> SearchNode {
        if word == "-" {
            guard index < tokens.count else { throw QueryError.missingOperatorValue(op: "-") }
            return .not(try parseAtom(tokens, &index))
        }
        if word.hasPrefix("-") {
            return .not(try parseWord(String(word.dropFirst()), tokens, &index))
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
        return .clause(try clause(for: op, value: trimming(value)))
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

    static func clause(for op: String, value: String) throws -> Clause {
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
        case "before": return .before(try dateBound(value, op: op))
        case "after": return .after(try dateBound(value, op: op))
        case "on": return .on(try dateSpan(value, op: op))
        case "during": return .during(try dateSpan(value, op: op))
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
    static func dateBound(_ value: String, op: String) throws -> String {
        func bad(_ reason: String) -> QueryError {
            .badOperatorValue(op: op, value: value, reason: reason)
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
    static func dateSpan(_ value: String, op: String) throws -> DateRange {
        func bad(_ reason: String) -> QueryError {
            .badOperatorValue(op: op, value: value, reason: reason)
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
    /// Operators that parse but have nothing behind them yet (e.g. amount).
    public var warnings: [String]

    public init(root: CompiledNode, warnings: [String]) {
        self.root = root
        self.warnings = warnings
    }
}

public enum QueryCompiler {
    /// message_text column order; the bm25 weight list must match it.
    static let columns = ["subject", "from_name", "from_addr", "recipients", "body", "quoted", "attachments"]
    /// Field weights (DESIGN 6A): subject ranks highest, then sender name
    /// and address, then other recipients, then the body; quoted text and
    /// attachment names barely count.
    public static let bm25Weights = "12.0, 8.0, 6.0, 5.0, 1.0, 0.4, 0.3"
    /// Fields bare terms search: everything indexed at message level except
    /// quoted text (which only phrase-quoted terms reach, at low weight).
    static let bareColumns = "{subject from_name from_addr recipients body attachments}"
    /// Columns an unquoted-field phrase searches: the bare columns plus
    /// quoted text, so a phrase like `"budget looks fine"` still finds a
    /// reply's quoted text — at quoted's low rank (DESIGN 6A).
    static let phraseColumns = "{subject from_name from_addr recipients body quoted attachments}"

    public static func compile(_ node: SearchNode) throws -> CompiledQuery {
        var warnings: [String] = []
        let root = try compileNode(node, into: &warnings)
        return CompiledQuery(root: root, warnings: warnings)
    }

    static func compileNode(_ node: SearchNode, into warnings: inout [String]) throws -> CompiledNode {
        switch node {
        case .and(let children):
            return .and(try children.map { try compileNode($0, into: &warnings) })
        case .or(let children):
            return .or(try children.map { try compileNode($0, into: &warnings) })
        case .not(let inner):
            return .not(try compileNode(inner, into: &warnings))
        case .clause(let clause):
            return try compileClause(clause, into: &warnings)
        }
    }

    // MARK: Clauses

    static func compileClause(_ clause: Clause, into warnings: inout [String]) throws -> CompiledNode {
        switch clause {
        case .text(let field, let raw):
            return try textNode(field: field, raw: raw, phrase: false)
        case .phrase(let field, let raw):
            return try textNode(field: field, raw: raw, phrase: true)
        case .from(let value):
            return fromNode(value)
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
        case .amount:
            warnings.append("amount: searches extracted entities, which are not indexed yet; this part matches nothing")
            return .filter(SQLFilter(sql: "1 = 0", arguments: []))
        }
    }

    static func textNode(field: SearchField, raw: String, phrase: Bool) throws -> CompiledNode {
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
        let expression = phrase
            ? "\"\(tokens.joined(separator: " "))\""
            : tokens.joined(separator: " AND ")
        // The trigram fallback matches substrings, so it works on the raw
        // text's folded form (punctuation survives), not on the query's
        // tokens alone: CJK tokens are two-character pairs, below the
        // trigram minimum, while the whole CJK run is a real substring
        // candidate. CJK spans differently in the query and the indexed
        // text, so its fallback also runs eagerly in the predicate path,
        // not only on a zero-hit retry (DESIGN 6A, M2.1).
        let foldedRaw = TokenPipeline.folded(raw)
        let fallbackPhrases = phrase ? [foldedRaw] : tokens + [foldedRaw]
        return .fts(FTSLeaf(
            expression: "{\(inner)} : \(expression)",
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
    /// matches tokens across the sender's name and address.
    static func fromNode(_ value: String) -> CompiledNode {
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
        return .fts(FTSLeaf(
            expression: "{from_name from_addr} : \(tokens.joined(separator: " AND "))",
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
            expression: "{recipients} : \(tokens.joined(separator: " AND "))",
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
