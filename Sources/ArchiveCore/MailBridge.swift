// MailBridge (DESIGN 6 + DESIGN 9): the one place where MailMIME's parse tree
// meets the index models. Sync and every import format produce MessageRecords
// and attachment rows through this file, so index facts never depend on which
// format the bytes arrived in. Parsing is read-only over the original bytes:
// nothing here rewrites a message.

import Foundation
import MailMIME

/// The text the search index gets from one message: the body a person
/// wrote (ranks high) and quoted or signature text (ranks low). The
/// plain-text part wins; HTML is reduced to text only when the message
/// has no plain part. Nested messages (message/rfc822) are skipped: their
/// content belongs to the inner message, and the outer body usually
/// quotes it anyway.
public struct SearchText: Sendable, Equatable {
    /// Body text outside quotes and signature; nil when empty.
    public var body: String?
    /// Quoted replies and signature lines; nil when empty.
    public var quoted: String?

    public init(body: String?, quoted: String?) {
        self.body = body
        self.quoted = quoted
    }
}

public enum MailBridge {
    /// Everything the index needs from one message, parsed in a single pass
    /// over the bytes. Import formats call this once per message; `record(for:)`
    /// and `attachments(for:)` remain as thin accessors for other callers.
    public struct ParsedMail: Sendable {
        public var record: MessageRecord
        public var attachments: [AttachmentInfo]
        /// Gmail labels from X-Gmail-Labels, cleaned of Takeout's empty slots
        /// and hex digest entries; empty when the message has none.
        public var gmailLabels: [String]
        /// X-GM-THRID value exactly as found, for provider thread joining
        /// (DESIGN 7); nil when the message has none.
        public var gmailThreadID: String?
        /// Body text the search index stores (DESIGN 6A): the part the person
        /// wrote, and quoted or signature text kept separate so ranking can
        /// treat them differently.
        public var searchText: SearchText
    }

    /// Parses message bytes into everything the index stores, in one pass.
    /// Never throws: unparseable headers simply stay nil.
    public static func parse(for data: Data) -> ParsedMail {
        let block = HeaderScanner.scan(data)
        let headers = Headers(block)

        let subject = headers.subject()
        let normalizedSubject = subject.isEmpty ? nil : Threading.simplifiedSubject(subject)
        let normalizedSubjectOrNil = (normalizedSubject?.isEmpty ?? true) ? nil : normalizedSubject

        let record = MessageRecord(
            subject: subject.isEmpty ? nil : subject,
            normalizedSubject: normalizedSubjectOrNil,
            dateSent: headers.date(),
            messageID: normalizeID(headers.messageID()),
            inReplyTo: headers.inReplyTo().compactMap(normalizeID),
            references: headers.references().compactMap(normalizeID),
            from: recipients(headers.addresses("From")).first,
            to: recipients(headers.addresses("To")),
            cc: recipients(headers.addresses("Cc")),
            bcc: recipients(headers.addresses("Bcc")),
            replyTo: recipients(headers.addresses("Reply-To")),
            listID: bareListID(headers.listID())
        )

        var attachments: [AttachmentInfo] = []
        var searchText = SearchText(body: nil, quoted: nil)
        if let root = try? parseRoot(data) {
            walk(root, path: "", into: &attachments)
            searchText = extractSearchText(root)
        }

        var gmailLabels: [String] = []
        if let labels = block.first("X-Gmail-Labels") {
            gmailLabels = cleanGmailLabels(
                EncodedWord.decode(labels.valueBytes, fallback: nil)
            )
        }
        var gmailThreadID: String? = nil
        if let thread = block.first("X-GM-THRID") {
            let trimmed = String(decoding: thread.valueBytes, as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { gmailThreadID = trimmed }
        }

        return ParsedMail(
            record: record,
            attachments: attachments,
            gmailLabels: gmailLabels,
            gmailThreadID: gmailThreadID,
            searchText: searchText
        )
    }

    /// Parses message bytes into the header facts the index stores.
    /// Never throws: unparseable headers simply stay nil.
    public static func record(for data: Data) -> MessageRecord {
        parse(for: data).record
    }

    /// Walks the MIME tree and records every attachment per the DESIGN 6 rule:
    /// a leaf is an attachment when its disposition says so, or when it carries
    /// a file name or Content-ID and is not the body text (not text/*).
    public static func attachments(for data: Data) -> [AttachmentInfo] {
        guard let root = try? parseRoot(data) else { return [] }
        var result: [AttachmentInfo] = []
        walk(root, path: "", into: &result)
        return result
    }

    /// Returns the part path whose decoded bytes hold the HTML or plain-text
    /// body a viewer should render first, or nil when there is no text body.
    public static func bodyPartPath(for data: Data) -> String? {
        guard let root = try? parseRoot(data) else { return nil }
        var best: (path: String, html: Bool)? = nil
        walkBodies(root, path: "") { path, part in
            let (main, _) = part.contentType
            let isText = main == "text/plain" || main == "text/html"
            guard isText else { return }
            let preferHTML = main == "text/html"
            if best == nil || (preferHTML && !best!.html) {
                best = (path, preferHTML)
            }
        }
        return best?.path
    }

    /// The transfer-decoded bytes, content type, and file name of the MIME
    /// part at `path` — the paths `attachments(for:)` and `bodyPartPath(for:)`
    /// report. nil when the path names no leaf of this message.
    public static func part(
        at path: String, in data: Data
    ) -> (data: Data, contentType: String, filename: String?)? {
        guard let root = try? parseRoot(data) else { return nil }
        var found: (data: Data, contentType: String, filename: String?)? = nil
        walkBodies(root, path: "") { partPath, part in
            guard found == nil, partPath == path else { return }
            let (main, _) = part.contentType
            found = (Data(part.decodedBody), main, part.filename)
        }
        return found
    }

    /// The part whose Content-ID matches `cid` (the value a `cid:` URL
    /// carries: angle brackets stripped, case folded), for inline image
    /// rendering. nil when the message has no such part.
    public static func attachment(
        contentID: String, for data: Data
    ) -> (data: Data, contentType: String)? {
        guard let root = try? parseRoot(data) else { return nil }
        let wanted = contentID.lowercased()
        var found: (data: Data, contentType: String)? = nil
        walkBodies(root, path: "") { _, part in
            guard found == nil, let id = part.contentID, id.lowercased() == wanted else { return }
            let (main, _) = part.contentType
            found = (Data(part.decodedBody), main)
        }
        return found
    }

    // MARK: - Search text (DESIGN 6A)

    /// Extracts the search text from message bytes without the rest of the
    /// parse. Never throws; unparseable input yields empty text.
    public static func searchText(for data: Data) -> SearchText {
        guard let root = try? parseRoot(data) else { return SearchText(body: nil, quoted: nil) }
        return extractSearchText(root)
    }

    static func extractSearchText(_ root: MIMEPart) -> SearchText {
        var plain: String? = nil
        var html: String? = nil
        walkTextBodies(root) { part in
            let (main, parameters) = part.contentType
            guard main == "text/plain" || main == "text/html" else { return }
            let text = Charset.decode(parameters["charset"], Array(part.decodedBody))
            if main == "text/plain" {
                if plain == nil { plain = text }
            } else if html == nil {
                html = text
            }
        }
        let source: String
        if let plain, !plain.isEmpty {
            source = plain
        } else if let html, !html.isEmpty {
            source = htmlToText(html)
        } else {
            return SearchText(body: nil, quoted: nil)
        }
        return splitBodyText(source)
    }

    /// Leaves only: descends through multipart, never into message/rfc822.
    private static func walkTextBodies(_ part: MIMEPart, _ visit: (MIMEPart) -> Void) {
        if part.kind == .multipart {
            for child in part.children { walkTextBodies(child, visit) }
            return
        }
        if part.kind == .nestedMessage { return }
        visit(part)
    }

    /// Splits body text at the first quote or signature marker: everything
    /// above the marker is body, everything below is quoted. Heuristic per
    /// DESIGN 6A — text after an interleaved reply marker is still prose,
    /// but it is almost always the older text, so ranking it low is right
    /// far more often than not. Returns nils instead of empty strings.
    static func splitBodyText(_ text: String) -> SearchText {
        var body: [String] = []
        var quoted: [String] = []
        var belowMarker = false
        for line in text.components(separatedBy: "\n") {
            if belowMarker {
                quoted.append(line)
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "--" {
                // Signature delimiter; the signature itself is not even
                // worth the quoted bucket.
                belowMarker = true
                continue
            }
            if isQuoteMarker(trimmed) {
                belowMarker = true
                quoted.append(line)
                continue
            }
            body.append(line)
        }
        func clean(_ lines: [String]) -> String? {
            let joined = lines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : joined
        }
        return SearchText(body: clean(body), quoted: clean(quoted))
    }

    /// A line that starts the quoted region: `>` quoting, a one-line
    /// "On ... wrote:" attribution, or a forwarded/original-message marker.
    static func isQuoteMarker(_ line: String) -> Bool {
        if line.hasPrefix(">") { return true }
        let lowered = line.lowercased()
        if lowered.hasPrefix("on "),
           lowered.hasSuffix("wrote:") || lowered.hasSuffix("writes:") {
            return true
        }
        if lowered.hasPrefix("---"),
           lowered.contains("original message") || lowered.contains("forwarded") {
            return true
        }
        if lowered.hasPrefix("begin forwarded message") { return true }
        return false
    }

    /// Reduces HTML to plain text: drops script/style content and comments,
    /// turns block boundaries into newlines, decodes the common entities.
    /// Deliberately not a full HTML parser — the goal is search text.
    static func htmlToText(_ html: String) -> String {
        let scalars = Array(html.unicodeScalars)
        var out = String.UnicodeScalarView()
        let breaks: Set<String> = [
            "br", "p", "div", "tr", "li", "table", "hr", "pre", "blockquote",
            "ul", "ol", "dl", "dt", "dd", "form", "section", "article",
            "header", "footer", "main", "nav", "aside", "figure",
            "h1", "h2", "h3", "h4", "h5", "h6",
        ]
        var skipping: String? = nil
        var i = 0
        while i < scalars.count {
            let scalar = scalars[i]
            if scalar != "<" {
                if skipping == nil { out.append(scalar) }
                i += 1
                continue
            }
            guard let close = scalars[i...].firstIndex(of: ">"), close > i else {
                i += 1  // a lone '<' that never closes: keep scanning text
                continue
            }
            let raw = String(String.UnicodeScalarView(scalars[(i + 1)..<close])).lowercased()
            i = close + 1
            let name = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/!? \t\n\r"))
            let bare = String(name.prefix(while: { $0.isLetter || $0.isNumber }))
            if let inside = skipping {
                // Wait for the matching close tag; ignore everything else.
                if raw.hasPrefix("/"), bare == inside { skipping = nil }
                continue
            }
            if raw.hasPrefix("!") || raw.hasPrefix("?") { continue }  // comments, declarations
            if bare == "script" || bare == "style" {
                skipping = bare
                continue
            }
            if breaks.contains(bare) {
                out.append("\n")
            } else if bare == "td" || bare == "th" {
                out.append(" ")
            }
        }
        var text = String(out)
        if text.contains("&") { text = decodeEntities(text) }
        return collapseBlankRuns(text)
    }

    /// Decodes the entities HTML commonly carries; unknown or malformed
    /// entities stay literal.
    static func decodeEntities(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            guard scalars[i] == "&" else { out.append(scalars[i]); i += 1; continue }
            var j = i + 1
            var end: Int? = nil
            while j < scalars.count, j - i <= 10 {
                if scalars[j] == ";" { end = j; break }
                j += 1
            }
            guard let end, end > i + 1 else { out.append(scalars[i]); i += 1; continue }
            let entity = String(String.UnicodeScalarView(scalars[(i + 1)..<end]))
            i = end + 1
            switch entity {
            case "amp": out.append("&")
            case "lt": out.append("<")
            case "gt": out.append(">")
            case "quot": out.append("\"")
            case "apos": out.append("'")
            case "nbsp": out.append(" ")
            default:
                if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                    if let code = UInt32(entity.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(code) {
                        out.append(scalar)
                    } else {
                        out.append(contentsOf: "&\(entity);".unicodeScalars)
                    }
                } else if entity.first == "#", let code = UInt32(entity.dropFirst()), let scalar = Unicode.Scalar(code) {
                    out.append(scalar)
                } else {
                    out.append(contentsOf: "&\(entity);".unicodeScalars)
                }
            }
        }
        return String(out)
    }

    /// Collapses runs of blank lines to one blank line so long HTML mail
    /// does not bury later text under whitespace.
    static func collapseBlankRuns(_ text: String) -> String {
        var lines: [String] = []
        var blankRun = 0
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                blankRun += 1
                if blankRun == 1 { lines.append("") }
            } else {
                blankRun = 0
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Parsing

    /// MIMEParser.parse never throws in practice; this wrapper keeps the
    /// call sites honest and returns nil for empty input.
    static func parseRoot(_ data: Data) throws -> MIMEPart {
        guard !data.isEmpty else { throw ArchiveError.corruptLayout("empty message") }
        return MIMEParser.parse(data)
    }

    private static func walk(_ part: MIMEPart, path: String, into result: inout [AttachmentInfo]) {
        if part.kind == .multipart {
            for (index, child) in part.children.enumerated() {
                walk(child, path: childPath(path, index + 1), into: &result)
            }
            return
        }
        if part.kind == .nestedMessage {
            // The inner message's parts continue under ".1" (DESIGN 6).
            if let inner = part.children.first {
                walk(inner, path: childPath(path, 1), into: &result)
            }
            return
        }

        let (main, _) = part.contentType
        let disposition = part.contentDisposition["content-disposition"]
        let filename = decodedFilename(part)
        let isAttachment =
            disposition == "attachment"
            || (filename != nil && !main.hasPrefix("text/"))
            || (part.contentID != nil && !main.hasPrefix("text/"))
        if isAttachment {
            result.append(AttachmentInfo(
                partIndex: path.isEmpty ? "1" : path,
                filename: filename,
                contentType: main,
                contentID: part.contentID,
                size: part.decodedBody.count
            ))
        }
    }

    private static func walkBodies(
        _ part: MIMEPart, path: String, _ visit: (String, MIMEPart) -> Void
    ) {
        if part.kind == .multipart {
            for (index, child) in part.children.enumerated() {
                walkBodies(child, path: childPath(path, index + 1), visit)
            }
            return
        }
        if part.kind == .nestedMessage {
            if let inner = part.children.first {
                walkBodies(inner, path: childPath(path, 1), visit)
            }
            return
        }
        visit(path.isEmpty ? "1" : path, part)
    }

    private static func childPath(_ parent: String, _ index: Int) -> String {
        parent.isEmpty ? "\(index)" : "\(parent).\(index)"
    }

    /// File names arrive RFC 2231-decoded from MIMEPart.filename; RFC 2047
    /// words inside them (a common real-world quirk) decode here too.
    private static func decodedFilename(_ part: MIMEPart) -> String? {
        guard var name = part.filename, !name.isEmpty else { return nil }
        let decoded = EncodedWord.decode(Array(name.utf8), fallback: nil)
        if !decoded.isEmpty { name = decoded }
        return name
    }

    /// Message-ID normalization for the index: no angle brackets, lower-cased.
    /// Empty or bracket-less junk yields nil.
    static func normalizeID(_ raw: String) -> String? {
        var id = raw.trimmingCharacters(in: .whitespaces)
        if id.hasPrefix("<"), id.hasSuffix(">") {
            id = String(id.dropFirst().dropLast())
        }
        guard !id.isEmpty, id.contains("@") else { return nil }
        return id.lowercased()
    }

    /// X-Gmail-Labels in Takeout mixes human-readable labels with empty slots
    /// ("^u^u"), Takeout's hex digest entries, and system labels prefixed
    /// with "^" (older exports used commas as separators). Keep the names a
    /// person recognizes; drop the rest. This is a heuristic by necessity —
    /// the format is undocumented and varies between exports. `raw` arrives
    /// encoded-word-decoded from parse(for:).
    static func cleanGmailLabels(_ raw: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        // Real Takeout writes comma-separated labels; system labels carry a
        // leading caret ("^uds", "^i") and bare hex label ids appear too.
        // Splitting on the caret would erase the marker that identifies
        // system labels, so split on commas only.
        for token in raw.split(separator: ",") {
            let label = String(token).trimmingCharacters(in: .whitespaces)
            if label.isEmpty || label.hasPrefix("^") { continue }
            // Takeout emits hex digests as pseudo-labels (e.g. 400e6a7c814573db).
            if label.count >= 12, label.allSatisfy({ $0.isHexDigit }) { continue }
            if seen.insert(label).inserted { result.append(label) }
        }
        return result
    }

    /// List-Id header value reduced to the bare list id inside the angle
    /// brackets, e.g. "List Name <list.example.com>" -> "list.example.com".
    private static func bareListID(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if let open = text.firstIndex(of: "<"), let close = text.firstIndex(of: ">"), open < close {
            let inner = String(text[text.index(after: open)..<close])
                .trimmingCharacters(in: .whitespaces)
            if !inner.isEmpty { return inner }
        }
        return text
    }

    private static func recipients(_ addresses: [EmailAddress]) -> [Recipient] {
        addresses.map { address in
            Recipient(
                name: address.name.isEmpty ? nil : address.name,
                email: address.address.lowercased()
            )
        }
    }
}
