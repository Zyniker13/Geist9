// Agent access control (DESIGN 9A, decision 0052): every tool call and
// resource read goes through an AccessContext resolved from the person's
// policy. The archive itself is never filtered or rewritten; visibility
// is a read-side predicate applied at the query layer, so excluded
// messages cannot surface through search, listings, resources, or
// per-message lookups. Per-message checks answer "not found", never
// "denied", so an agent cannot even learn that a hidden id exists.

import ArchiveCore
import Foundation

/// Replaces contact details in text before it leaves the server.
/// Heuristic and best-effort by design: it guards the common case
/// (an agent summarizing mail must not leak addresses and numbers into
/// its own context), not an adversarial extractor.
public enum Redactor {
    /// RFC-ish addresses: `alice@example.com`, `First.Last+tag@sub.example.org`.
    private static let email = try! NSRegularExpression(
        pattern: "[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}")

    /// Phone-like runs: separators (space, dash, dot, slash, parens) or a
    /// leading `+`, 7..15 digits after stripping. A bare long digit run
    /// (order numbers, ids) stays readable. ISO dates (`2024-01-15`) are
    /// filtered out by the date-shaped guard below.
    private static let phone = try! NSRegularExpression(
        pattern: "(?<![0-9])\\+?\\(?\\d{1,4}\\)?(?:[ .\\-/]\\(?\\d{1,4}\\)?){1,4}(?![0-9])")

    /// True for matches whose digits look like a date, not a phone:
    /// exactly 8 digits in year-first shape (`2024-01-15`).
    static func looksLikeDate(_ match: String) -> Bool {
        let digits = match.filter(\.isNumber)
        return digits.count == 8 && match.contains("-")
            && (digits.hasPrefix("19") || digits.hasPrefix("20"))
    }

    /// Applies one policy redaction mode to text. `headersOnly` redacts
    /// nothing here — that mode omits whole content fields instead.
    public static func apply(_ mode: AccessPolicy.Redaction, to text: String) -> String {
        switch mode {
        case .none:
            return text
        case .contactDetails:
            var out = replace(text, regex: email, marker: "[email removed]")
            out = replace(
                out, regex: phone, marker: "[phone number removed]"
            ) { !looksLikeDate($0) }
            return out
        case .headersOnly:
            return text
        }
    }

    private static func replace(
        _ text: String, regex: NSRegularExpression, marker: String,
        keep: (String) -> Bool = { _ in true }
    ) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var out = ""
        var cursor = text.startIndex
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match, let matchRange = Range(match.range, in: text) else { return }
            let matched = String(text[matchRange])
            guard keep(matched) else { return }
            out += String(text[cursor..<matchRange.lowerBound])
            out += marker
            cursor = matchRange.upperBound
        }
        out += String(text[cursor...])
        return out
    }
}

/// Fixed-window call rate limiter (DESIGN 9A budgets): `limit` tool
/// calls per minute, then a flat refusal. Not a boundary against the
/// person themself; it keeps a runaway agent loop from chewing through
/// the archive.
final class RateLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [Date] = []
    private let limit: Int

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func allowCall(now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        calls.removeAll { now.timeIntervalSince($0) >= 60 }
        guard calls.count < limit else { return false }
        calls.append(now)
        return true
    }
}

/// One JSON line per tool call. Lives beside the archive; it is the
/// person's receipt of what agents asked for. Best effort: a logging
/// failure never fails a tool call.
final class ActivityLog: @unchecked Sendable {
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
    }

    struct Entry: Encodable {
        var date: Date
        var tool: String
        var query: String?
        var resultCount: Int?
    }

    func record(tool: String, query: String?, resultCount: Int?) {
        let entry = Entry(date: Date(), tool: tool, query: query, resultCount: resultCount)
        lock.lock()
        defer { lock.unlock() }
        guard let line = try? encoder.encode(entry) else { return }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        _ = try? handle.write(line + Data("\n".utf8))
    }
}

/// Everything one server instance enforces, resolved once against the
/// index at startup: the person's policy turned into id sets by
/// ArchiveCore, plus the budgets. `@unchecked Sendable` because the
/// resolved parts are immutable after init and the mutable parts lock
/// their own state.
final class AccessContext: @unchecked Sendable {
    let visibility: MessageVisibility
    let redaction: AccessPolicy.Redaction
    let maxResultsPerCall: Int
    let maxCharsPerCall: Int
    let rateLimiter: RateLimiter
    let activityLog: ActivityLog

    /// True when any exclusion is active — callers use it to drop
    /// zero-count rows that would otherwise leak the sizes of hidden
    /// things.
    var isFiltered: Bool { !visibility.isPermissive }

    init(visibility: MessageVisibility, policy: AccessPolicy, activityLog: ActivityLog) {
        self.visibility = visibility
        self.redaction = policy.redaction
        self.maxResultsPerCall = min(policy.maxResultsPerCall, ArchiveTools.maxPageSize)
        self.maxCharsPerCall = policy.maxCharsPerCall
        self.rateLimiter = RateLimiter(limit: policy.callsPerMinute)
        self.activityLog = activityLog
    }

    /// Whether one message is visible. Hidden ids answer `false`, and
    /// callers turn that into "not found" so existence never leaks.
    func isVisible(messageID: Int64, store: ArchiveStore) throws -> Bool {
        if visibility.isPermissive { return true }
        return try store.messageIsVisible(messageID: messageID, visibility: visibility)
    }

    /// Whether one thread has at least one visible message. Fully hidden
    /// threads answer `false` and callers turn that into "not found".
    /// Partially visible threads answer `true`; reads show only the
    /// visible messages, which threadJSON enforces by taking its subject
    /// from the first *visible* message.
    func threadIsVisible(threadID: Int64, store: ArchiveStore) throws -> Bool {
        if visibility.isPermissive { return true }
        return !(try store.threadMessages(
            threadID: threadID, visible: visibility
        )).isEmpty
    }
}
