// MailBridge (DESIGN 6 + DESIGN 9): the one place where MailMIME's parse tree
// meets the index models. Sync and every import format produce MessageRecords
// and attachment rows through this file, so index facts never depend on which
// format the bytes arrived in. Parsing is read-only over the original bytes:
// nothing here rewrites a message.

import Foundation
import MailMIME

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
        if let root = try? parseRoot(data) {
            walk(root, path: "", into: &attachments)
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
            gmailThreadID: gmailThreadID
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
