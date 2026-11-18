// The fields the index records for every message (DESIGN 6). Parsers produce a
// MessageRecord; ArchiveStore.ingest writes it and the message bytes in one
// transaction. ArchiveCore never parses: MailMIME does that, imports call both.

import Foundation

/// A parsed header identity: one email address as it appears in a header.
public struct Recipient: Sendable, Equatable, Hashable, Codable {
    /// Decoded display name, or nil when the header had none.
    public var name: String?
    /// Normalized address: lower-cased. May be empty for group syntax or
    /// malformed input; the header text is preserved in the raw bytes.
    public var email: String

    public init(name: String? = nil, email: String) {
        self.name = name
        self.email = email
    }
}

/// The header-level facts the index stores about one message.
/// Everything here is derived from the message's original bytes, which stay
/// untouched in `messages/`.
public struct MessageRecord: Sendable, Equatable {
    public var subject: String?
    /// JWZ-normalized subject (Re:/Fwd: prefixes stripped, whitespace
    /// collapsed, lower-cased) for grouping; nil when there is no subject.
    public var normalizedSubject: String?
    /// Date header, parsed to UTC; nil when absent or unparseable.
    public var dateSent: Date?
    /// Arrival time: IMAP INTERNALDATE, mbox From-line date, or import time.
    public var dateReceived: Date?
    /// RFC 5322 Message-ID without angle brackets, normalized (lower-cased
    /// domain per JWZ; whole value lower-cased).
    public var messageID: String?
    public var inReplyTo: [String]
    /// References chain in header order.
    public var references: [String]
    public var from: Recipient?
    public var to: [Recipient]
    public var cc: [Recipient]
    public var bcc: [Recipient]
    public var replyTo: [Recipient]
    /// List-Id header value, normalized to the bare list id.
    public var listID: String?

    public init(
        subject: String? = nil,
        normalizedSubject: String? = nil,
        dateSent: Date? = nil,
        dateReceived: Date? = nil,
        messageID: String? = nil,
        inReplyTo: [String] = [],
        references: [String] = [],
        from: Recipient? = nil,
        to: [Recipient] = [],
        cc: [Recipient] = [],
        bcc: [Recipient] = [],
        replyTo: [Recipient] = [],
        listID: String? = nil
    ) {
        self.subject = subject
        self.normalizedSubject = normalizedSubject
        self.dateSent = dateSent
        self.dateReceived = dateReceived
        self.messageID = messageID
        self.inReplyTo = inReplyTo
        self.references = references
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.replyTo = replyTo
        self.listID = listID
    }
}

/// An account in the index. Imports create one pseudo-account per source.
public struct AccountIdentity: Sendable, Equatable {
    /// Normalized (lower-cased) address or a stable import source id.
    public var email: String
    public var displayName: String
    /// "imap", "jmap", or "import".
    public var providerKind: String

    public init(email: String, displayName: String, providerKind: String) {
        self.email = email
        self.displayName = displayName
        self.providerKind = providerKind
    }
}

/// One mailbox membership of one message.
public struct Membership: Sendable, Equatable {
    /// Full mailbox path as reported by the server or implied by an import
    /// folder, e.g. "INBOX", "Archive/2024", "Sent Messages".
    public var mailbox: String
    /// IMAP UID, or nil for imports.
    public var uid: Int64?
    /// Flags and keywords, normalized lower-case, e.g. ["seen", "flagged"].
    public var flags: [String]
    /// INTERNALDATE for IMAP, or the message's date for imports.
    public var dateReceived: Date?

    public init(mailbox: String, uid: Int64? = nil, flags: [String] = [], dateReceived: Date? = nil) {
        self.mailbox = mailbox
        self.uid = uid
        self.flags = flags
        self.dateReceived = dateReceived
    }
}

/// A Gmail-style label (DESIGN 6); Takeout maps folders to these.
public struct LabelName: Sendable, Equatable, Hashable {
    public var name: String
    public init(name: String) { self.name = name }
}

/// An attachment recorded in the index. Attachment bytes stay inside the
/// message's .eml; extracted text later goes to `attachments-text/`.
public struct AttachmentInfo: Sendable, Equatable, Hashable {
    /// MIME part path within the message, e.g. "1.2".
    public var partIndex: String
    public var filename: String?
    public var contentType: String
    public var contentID: String?
    /// Decoded size in bytes (after transfer-encoding removal).
    public var size: Int

    public init(partIndex: String, filename: String? = nil, contentType: String, contentID: String? = nil, size: Int) {
        self.partIndex = partIndex
        self.filename = filename
        self.contentType = contentType
        self.contentID = contentID
        self.size = size
    }
}

/// Everything ingest needs for one message.
public struct IngestedMessage: Sendable {
    public var record: MessageRecord
    /// The message's original bytes, exactly as downloaded or imported.
    public var data: Data
    public var memberships: [Membership]
    public var labels: [LabelName]
    public var attachments: [AttachmentInfo]
    /// Where the message came from, for imports: e.g. "eml", "mbox", "apple-mail",
    /// "takeout", or a source-specific tag. nil for messages synced from a server.
    public var importSource: String?
    /// Provider thread id from the source format, e.g. Google Takeout's X-GM-THRID
    /// (hex or decimal string as found). Threading joins on this later (DESIGN 7).
    public var providerThreadID: String?

    public init(
        record: MessageRecord,
        data: Data,
        memberships: [Membership],
        labels: [LabelName] = [],
        attachments: [AttachmentInfo] = [],
        importSource: String? = nil,
        providerThreadID: String? = nil
    ) {
        self.record = record
        self.data = data
        self.memberships = memberships
        self.labels = labels
        self.attachments = attachments
        self.importSource = importSource
        self.providerThreadID = providerThreadID
    }
}

/// Result of ingesting one message.
public enum IngestResult: Sendable, Equatable {
    /// Stored a new message; this is its row id in `message`.
    case created(messageID: Int64)
    /// The same bytes were already stored; nothing was added twice.
    /// The existing row's id is returned.
    case duplicate(messageID: Int64)
}
