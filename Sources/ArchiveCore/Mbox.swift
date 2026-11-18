// mbox import and export (DESIGN 9). The splitter recognizes all four
// classic variants - mboxo, mboxrd, mboxcl, mboxcl2 - and never trusts a
// message boundary it cannot verify. Message bytes are stored as the file
// attests them: only mboxrd/mboxcl2 ">From " quoting is undone on import,
// and only the From_ separator line itself is dropped. See
// docs/decisions/0015-import-export-semantics.md for the exact rules.

import Foundation
import MailMIME

public enum MboxVariant: String, Sendable, CaseIterable {
    case mboxo
    case mboxrd
    case mboxcl
    case mboxcl2
}

/// One message carved out of an mbox file.
public struct MboxMessage: Sendable {
    /// Sender token from the From_ line, or nil when absent.
    public var envelopeFrom: String?
    /// Parsed From-line date (UTC), or nil when absent or unparseable.
    public var envelopeDate: Date?
    /// Message bytes: headers, blank line, body - the From_ line itself is
    /// not part of the message.
    public var data: [UInt8]
    /// Best-effort variant classification (heuristic for mboxo vs mboxrd).
    public var variant: MboxVariant
    /// True when the message's extent came from a verified Content-Length.
    public var contentLengthTrusted: Bool
}

/// Splits an mbox file into messages. Streams from disk in file mode;
/// line-scan mode is the default and Content-Length is used only when its
/// framing verifies. The splitter never throws on malformed input: worst
/// case it classifies bytes as one message instead of two.
public struct MboxSplitter {
    private let reader: MboxLineReader
    private var sawFirstBoundary = false
    /// Explicit variant override. Detection cannot tell mboxo from mboxrd
    /// when a body merely contains a literal ">From " line, so a caller who
    /// knows the file's variant can pin it; nil keeps content-based detection.
    private let variantHint: MboxVariant?

    /// Bytes skipped before the first From_ line (leading garbage).
    public private(set) var skippedLeadingBytes = 0

    public init(data: Data, variant: MboxVariant? = nil) {
        reader = MboxLineReader(data: [UInt8](data))
        variantHint = variant
    }

    public init(url: URL, variant: MboxVariant? = nil) throws {
        let handle = try FileHandle(forReadingFrom: url)
        reader = MboxLineReader(fileHandle: handle)
        variantHint = variant
    }

    /// Returns the next message, or nil at end of file.
    public mutating func next() -> MboxMessage? {
        while true {
            guard let message = extractOne() else { return nil }
            if !message.data.isEmpty { return message }
            // A From_ line with nothing after it (two boundaries in a row)
            // carries no message content; skip it.
        }
    }

    /// Releases buffered bytes already consumed; safe to call between messages.
    public mutating func compact() {
        reader.compact()
    }

    // MARK: - One message

    private mutating func extractOne() -> MboxMessage? {
        reader.compact()

        // Find the boundary From_ line.
        guard let boundary = reader.nextLine(where: { MboxFormat.isFromLine($0) }) else {
            return nil
        }
        if !sawFirstBoundary {
            skippedLeadingBytes = boundary.start
            sawFirstBoundary = true
        }
        let envelope = MboxFormat.parseFromLine(boundary.bytes)

        // Collect the header block: every line up to the first blank line.
        // A From_ line before the blank line means the previous boundary had
        // no message content at all; the loop simply treats this line as the
        // next boundary (empty data -> skipped by next()).
        var headerBytes: [UInt8] = []
        var contentLength: Int? = nil
        var bodyStart: Int? = nil
        while let line = reader.nextLine() {
            let content = MboxFormat.withoutTrailingCR(line.bytes)
            if MboxFormat.isFromLine(content) {
                // Rewind: this line is the next message's boundary.
                reader.seek(to: line.start)
                return message(
                    envelope: envelope, bytes: [], variant: .mboxo, trusted: false
                )
            }
            headerBytes += reader.terminated(line)
            if content.isEmpty {
                bodyStart = reader.absolutePosition
                break
            }
            if contentLength == nil {
                contentLength = MboxFormat.parseContentLength(content)
            }
        }

        guard let body = bodyStart else {
            // EOF inside the header block: keep what is there.
            return message(
                envelope: envelope, bytes: headerBytes, variant: .mboxo, trusted: false
            )
        }

        // Preferred path: a Content-Length whose framing verifies exactly.
        if let count = contentLength, count > 0,
            let (bodyBytes, _) = tryContentLengthBody(start: body, count: count)
        {
            let variant: MboxVariant =
                variantHint ?? (MboxFormat.containsQuotedFrom(bodyBytes) ? .mboxcl2 : .mboxcl)
            return message(
                envelope: envelope, bytes: headerBytes + bodyBytes,
                variant: variant, trusted: true
            )
        }

        // Fallback: scan line by line for the next boundary.
        reader.seek(to: body)
        var bodyBytes: [UInt8] = []
        while let line = reader.nextLine() {
            if MboxFormat.isFromLine(line.bytes) {
                reader.seek(to: line.start)
                break
            }
            bodyBytes += reader.terminated(line)
        }
        // Unquote only when the variant says so: an explicit hint wins, and
        // auto-detection unquotes only on evidence. With an unverified mboxcl
        // or mboxcl2 hint (no Content-Length), store bytes verbatim - rd
        // unquoting on an unverified frame could rewrite real content.
        let variant: MboxVariant
        let stored: [UInt8]
        if let hint = variantHint, hint != .mboxrd {
            variant = hint
            stored = bodyBytes
        } else if variantHint == .mboxrd || MboxFormat.containsQuotedFrom(bodyBytes) {
            variant = .mboxrd
            stored = MboxFormat.unquoteBody(bodyBytes)
        } else {
            variant = .mboxo
            stored = bodyBytes
        }
        return message(
            envelope: envelope, bytes: headerBytes + stored, variant: variant,
            trusted: false
        )
    }

    private func message(
        envelope: (sender: String?, date: Date?)?, bytes: [UInt8], variant: MboxVariant,
        trusted: Bool
    ) -> MboxMessage {
        MboxMessage(
            envelopeFrom: envelope?.sender,
            envelopeDate: envelope?.date,
            data: bytes,
            variant: variant,
            contentLengthTrusted: trusted
        )
    }

    /// Reads `count` bytes at `start` and verifies the framing that follows:
    /// at most one final line terminator (belonging to the body when the body
    /// itself does not end with one), then an optional blank separator line,
    /// then another From_ line or end of file. Returns nil when anything does
    /// not line up, which sends the caller to the line-scan fallback.
    private func tryContentLengthBody(start: Int, count: Int) -> ([UInt8], Bool)? {
        guard let span = reader.readSpan(start: start, length: count) else {
            return nil
        }

        var body = span
        var position = start + count

        if !MboxFormat.endsWithLineTerminator(body) {
            // The writer counted the body's final newline outside Content-Length.
            if let terminator = reader.lineTerminator(at: position) {
                body += terminator
                position += terminator.count
            }
        }
        // Skip the optional blank separator line.
        if let blank = reader.lineTerminator(at: position) {
            position += blank.count
        }
        // The next thing must be a From_ line or end of file.
        if reader.isAtEnd(position) {
            return (body, true)
        }
        guard let line = reader.peekLine(at: position), MboxFormat.isFromLine(line.bytes) else {
            return nil
        }
        return (body, true)
    }
}

// MARK: - From_ lines

public enum MboxFormat {
    static let fromPrefix: [UInt8] = [0x46, 0x72, 0x6F, 0x6D, 0x20]  // "From "

    /// A message boundary: a line starting with "From " followed by a
    /// non-empty sender token or a parseable asctime date. This is the
    /// classic rule; mboxo files genuinely split on body lines like this.
    public static func isFromLine(_ line: [UInt8]) -> Bool {
        let content = withoutTrailingCR(line)
        guard starts(content, with: fromPrefix) else { return false }
        let rest = Array(content.dropFirst(fromPrefix.count))
        guard !rest.isEmpty else { return false }
        if parseAsctime(rest) != nil { return true }
        // Sender token: bytes up to the first space.
        let senderEnd = rest.firstIndex(of: 0x20) ?? rest.count
        return senderEnd > 0
    }

    /// Sender and date from a From_ line.
    public static func parseFromLine(_ line: [UInt8]) -> (sender: String?, date: Date?)? {
        let content = withoutTrailingCR(line)
        guard starts(content, with: fromPrefix) else { return nil }
        let rest = Array(content.dropFirst(fromPrefix.count))
        let senderEnd = rest.firstIndex(of: 0x20) ?? rest.count
        let senderBytes = Array(rest[..<senderEnd])
        let sender = senderBytes.isEmpty
            ? nil : String(decoding: senderBytes, as: UTF8.self)
        let date = parseAsctime(Array(rest[senderEnd...]))
        return (sender, date)
    }

    /// Parses "Wdy Mon DD HH:MM[:SS] YYYY" with tolerant spacing and junk
    /// around it (timezone suffixes, envelope add-ons). UTC assumed: mbox
    /// From-lines carry no usable zone.
    public static func parseAsctime(_ text: [UInt8]) -> Date? {
        let string = String(decoding: text, as: UTF8.self)
        let tokens = string.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard tokens.count >= 4 else { return nil }
        var monthIndex: Int? = nil
        for (index, token) in tokens.enumerated() where token.count == 3 {
            if monthNumber(String(token)) != nil {
                monthIndex = index
                break
            }
        }
        guard let m = monthIndex, m + 3 < tokens.count else { return nil }
        let dayToken = tokens[m + 1]
        guard let day = Int(dayToken), (1...31).contains(day) else { return nil }
        let timeToken = tokens[m + 2]
        let timeParts = timeToken.split(separator: ":")
        guard (2...3).contains(timeParts.count),
            let hour = Int(timeParts[0]), (0...23).contains(hour),
            let minute = Int(timeParts[1]), (0...59).contains(minute)
        else { return nil }
        var second = 0
        if timeParts.count == 3 {
            guard let s = Int(timeParts[2]), (0...60).contains(s) else { return nil }
            second = s
        }
        let yearToken = tokens[m + 3]
        guard yearToken.count == 4, let year = Int(yearToken), (1000...9999).contains(year)
        else { return nil }
        guard let month = monthNumber(String(tokens[m])) else { return nil }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return Timestamp.utcCalendar.date(from: components)
    }

    private static func monthNumber(_ token: String) -> Int? {
        let names = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        guard let index = names.firstIndex(of: token.lowercased()) else { return nil }
        return index + 1
    }

    /// The export-side From_ line: "From sender asctime\n" with asctime's
    /// space-padded day ("Mon Jan  2 15:04:05 2006"), UTC.
    public static func fromLine(sender: String, date: Date) -> [UInt8] {
        [UInt8]("From \(sender) \(asctimeString(from: date))\n".utf8)
    }

    public static func asctimeString(from date: Date) -> String {
        let parts = Timestamp.utcCalendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .weekday], from: date
        )
        let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let weekday = weekdays[(parts.weekday ?? 1) - 1]
        let month = months[(parts.month ?? 1) - 1]
        return String(
            format: "%@ %@ %2d %02d:%02d:%02d %04d",
            weekday, month,
            parts.day ?? 1, parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0,
            parts.year ?? 1970
        )
    }

    /// mboxrd/mboxcl2 unquoting: every body line matching /^>+From / loses
    /// one ">". Header bytes must not be passed in.
    public static func unquoteBody(_ body: [UInt8]) -> [UInt8] {
        mapBodyLines(body) { line in
            if quotedFromDepth(line) > 0 {
                // Drop exactly one leading ">".
                var line = line
                line.removeFirst()
                return line
            }
            return line
        }
    }

    /// Export-side quoting: every body line matching /^>*From / gains one
    /// ">" so it cannot be mistaken for a message boundary.
    public static func quoteBodyForExport(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        let bodyStart = HeaderScanner.scan(data).bodyStart
        guard bodyStart < bytes.count else { return data }
        let body = Array(bytes[bodyStart...])
        var result = Array(bytes[..<bodyStart])
        result += mapBodyLines(body) { line in
            // RFC 4155 writing rule: every line matching /^>*From / gains one
            // ">" - a bare "From " cannot pose as a boundary, and a line that
            // is already quoted round-trips byte-identically.
            let matches = MboxFormat.starts(line, with: MboxFormat.fromPrefix)
                || quotedFromDepth(line) > 0
            return matches ? [UInt8](Array(">".utf8)) + line : line
        }
        return Data(result)
    }

    /// How many ">" a line has before "From " (the /^>*From / rule); 0 when
    /// the line does not match.
    static func quotedFromDepth(_ line: [UInt8]) -> Int {
        let content = withoutTrailingCR(line)
        var depth = 0
        while depth < content.count, content[depth] == 0x3E { depth += 1 }  // ">"
        guard starts(Array(content.dropFirst(depth)), with: [UInt8]("From ".utf8)) else {
            return 0
        }
        return depth
    }

    static func containsQuotedFrom(_ body: [UInt8]) -> Bool {
        var line: [UInt8] = []
        for byte in body {
            if byte == 0x0A {
                if quotedFromDepth(line) > 0 { return true }
                line = []
            } else {
                line.append(byte)
            }
        }
        return quotedFromDepth(line) > 0
    }

    static func endsWithLineTerminator(_ bytes: [UInt8]) -> Bool {
        if bytes.count >= 2, bytes[bytes.count - 2] == 0x0D, bytes.last == 0x0A { return true }
        return bytes.last == 0x0A
    }

    static func withoutTrailingCR(_ line: [UInt8]) -> [UInt8] {
        line.last == 0x0D ? Array(line.dropLast()) : line
    }

    static func parseContentLength(_ headerLine: [UInt8]) -> Int? {
        let content = withoutTrailingCR(headerLine)
        guard content.count > 15 else { return nil }  // "Content-Length: " is 16
        let prefix = Array(content.prefix(15))
        guard String(decoding: prefix, as: UTF8.self).lowercased() == "content-length:"
        else { return nil }
        let value = String(decoding: content.dropFirst(15), as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        guard let count = Int(value), count > 0 else { return nil }
        return count
    }

    /// Applies a transform line by line, preserving each line's terminator.
    private static func mapBodyLines(_ body: [UInt8], _ transform: ([UInt8]) -> [UInt8])
        -> [UInt8]
    {
        var result: [UInt8] = []
        var line: [UInt8] = []
        var index = 0
        while index < body.count {
            let byte = body[index]
            line.append(byte)
            if byte == 0x0A {
                result += transform(line)
                line = []
            }
            index += 1
        }
        if !line.isEmpty { result += transform(line) }
        return result
    }

    static func starts(_ bytes: [UInt8], with prefix: [UInt8]) -> Bool {
        guard prefix.count <= bytes.count else { return false }
        for index in 0..<prefix.count where bytes[index] != prefix[index] { return false }
        return true
    }
}

// MARK: - Buffered reading

/// Line-oriented reader over a file or an in-memory buffer. Tracks absolute
/// offsets so the splitter can rewind into already-buffered bytes when a
/// Content-Length claim fails verification.
final class MboxLineReader {
    private let fileHandle: FileHandle?
    private var buffer: [UInt8] = []
    private var bufferStart = 0  // absolute offset of buffer[0]
    private var position = 0  // absolute offset of the next unread byte
    private var eofReached = false

    init(data: [UInt8]) {
        fileHandle = nil
        buffer = data
        eofReached = true
    }

    init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
    }

    deinit {
        try? fileHandle?.close()
    }

    /// Absolute offset of the next unread byte.
    var absolutePosition: Int { position }

    /// Drops consumed bytes from the front of the buffer. Safe between
    /// messages; never call while a rewind target is still needed.
    func compact() {
        let consumed = position - bufferStart
        guard consumed > 1 << 20 else { return }  // trim in large steps only
        buffer.removeFirst(consumed)
        bufferStart = position
    }

    func seek(to offset: Int) {
        position = offset
    }

    private func fill() {
        if eofReached { return }
        if let handle = fileHandle {
            guard let chunk = try? handle.read(upToCount: 1 << 16), !chunk.isEmpty else {
                eofReached = true
                return
            }
            buffer.append(contentsOf: [UInt8](chunk))
        } else {
            eofReached = true  // in-memory mode: everything is already buffered
        }
    }

    private func available(to offset: Int) -> Bool {
        while bufferStart + buffer.count < offset, !eofReached { fill() }
        return bufferStart + buffer.count >= offset
    }

    func isAtEnd(_ offset: Int) -> Bool {
        if available(to: offset + 1) { return false }
        return offset >= bufferStart + buffer.count
    }

    /// The byte at an absolute offset, or nil past end of file.
    func byte(at offset: Int) -> UInt8? {
        guard available(to: offset + 1) else { return nil }
        return buffer[offset - bufferStart]
    }

    /// The CRLF or LF at an offset, if one is there.
    func lineTerminator(at offset: Int) -> [UInt8]? {
        if byte(at: offset) == 0x0D, byte(at: offset + 1) == 0x0A { return [0x0D, 0x0A] }
        if byte(at: offset) == 0x0A { return [0x0A] }
        return nil
    }

    struct RawLine {
        var bytes: [UInt8]  // without the trailing LF; a CR stays
        var start: Int  // absolute offset of bytes[0]
    }

    /// Reads one line, including its LF in the stream but not in `bytes`.
    func nextLine() -> RawLine? {
        nextLine(where: { _ in true })
    }

    /// The line's bytes plus its terminator when one was consumed, so
    /// reassembled message bytes stay byte-identical to the source file.
    func terminated(_ line: RawLine) -> [UInt8] {
        absolutePosition == line.start + line.bytes.count + 1
            ? line.bytes + [0x0A]
            : line.bytes
    }

    /// Reads the next line matching `predicate`, consuming everything before
    /// it; nil at end of file.
    func nextLine(where predicate: ([UInt8]) -> Bool) -> RawLine? {
        var scanFrom = position - bufferStart
        while true {
            while scanFrom < buffer.count {
                guard let lineEnd = buffer[scanFrom...].firstIndex(of: 0x0A) else {
                    scanFrom = buffer.count
                    break
                }
                let bytes = Array(buffer[scanFrom..<lineEnd])
                if predicate(bytes) {
                    let start = bufferStart + scanFrom
                    position = bufferStart + lineEnd + 1
                    return RawLine(bytes: bytes, start: start)
                }
                scanFrom = lineEnd + 1
            }
            if eofReached {
                // A final line without a terminator.
                if scanFrom < buffer.count {
                    let start = bufferStart + scanFrom
                    let bytes = Array(buffer[scanFrom...])
                    position = bufferStart + buffer.count
                    return RawLine(bytes: bytes, start: start)
                }
                return nil
            }
            fill()
        }
    }

    /// Looks at the line starting at `offset` without consuming it.
    func peekLine(at offset: Int) -> RawLine? {
        let saved = position
        defer { position = saved }
        guard offset >= position else { return nil }
        position = offset
        return nextLine()
    }

    /// Reads exactly `length` bytes starting at `start` and advances past
    /// them. Returns nil when end of file comes first (a claim that does not
    /// hold cannot be trusted).
    func readSpan(start: Int, length: Int) -> [UInt8]? {
        guard length > 0 else { return [] }
        guard available(to: start + length) else { return nil }
        let lower = start - bufferStart
        let bytes = Array(buffer[lower..<(lower + length)])
        position = start + length
        return bytes
    }
}
