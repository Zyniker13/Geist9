// What a person decided an agent may see (DESIGN 9A). The person writes
// this in the app's Agent Access settings; it is names, not ids, because
// the index renumbers every import. The MCP layer resolves it against
// the index into a MessageVisibility and enforces it SQL-side.

import GRDB

/// Access policy for agent tools over one archive. JSON on disk, tolerant
/// to absent keys so the default posture stays intact as fields are added.
public struct AccessPolicy: Sendable, Equatable {
    /// How message content is redacted on the way out (see Redactor).
    public enum Redaction: String, Sendable, CaseIterable, Codable {
        /// Content unchanged.
        case none
        /// Email addresses and phone numbers replaced by markers.
        case contactDetails
        /// No bodies or snippets at all: headers, labels, attachments
        /// metadata only.
        case headersOnly
    }

    /// Messages in folders whose role is `junk` or `trash` are hidden.
    /// Defaults true: the Junk view of a mailbox is not what anyone means
    /// by "the archive", and hiding it costs nothing.
    public var excludeJunkAndTrash: Bool
    /// Accounts hidden whole, matched case-insensitively on email.
    public var excludedAccounts: Set<String>
    /// Mailboxes hidden, matched on the name the person wrote, compared
    /// case-insensitively against the last path component of the folder
    /// name (`Work/Invoices` matches `Invoices` in any account).
    public var excludedMailboxes: Set<String>
    /// Labels whose messages are hidden, compared case-insensitively.
    public var excludedLabels: Set<String>
    /// Content redaction mode on every tool result.
    public var redaction: Redaction
    /// Most messages any one tool call may return.
    public var maxResultsPerCall: Int
    /// Most content characters any one tool call may emit.
    public var maxCharsPerCall: Int
    /// Tool calls per minute before the server answers 429-shaped errors.
    public var callsPerMinute: Int

    public static let `default` = AccessPolicy(
        excludeJunkAndTrash: true,
        excludedAccounts: [],
        excludedMailboxes: [],
        excludedLabels: [],
        redaction: .none,
        maxResultsPerCall: 100,
        maxCharsPerCall: 200_000,
        callsPerMinute: 60
    )
}

extension AccessPolicy: Codable {
    private enum CodingKeys: String, CodingKey {
        case excludeJunkAndTrash
        case excludedAccounts
        case excludedMailboxes
        case excludedLabels
        case redaction
        case maxResultsPerCall
        case maxCharsPerCall
        case callsPerMinute
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let base = AccessPolicy.default
        self.excludeJunkAndTrash = try container.decodeIfPresent(
            Bool.self, forKey: .excludeJunkAndTrash) ?? base.excludeJunkAndTrash
        self.excludedAccounts = try container.decodeIfPresent(
            Set<String>.self, forKey: .excludedAccounts) ?? []
        self.excludedMailboxes = try container.decodeIfPresent(
            Set<String>.self, forKey: .excludedMailboxes) ?? []
        self.excludedLabels = try container.decodeIfPresent(
            Set<String>.self, forKey: .excludedLabels) ?? []
        self.redaction = try container.decodeIfPresent(
            Redaction.self, forKey: .redaction) ?? base.redaction
        let maxResults = try container.decodeIfPresent(
            Int.self, forKey: .maxResultsPerCall) ?? base.maxResultsPerCall
        self.maxResultsPerCall = max(1, maxResults)
        let maxChars = try container.decodeIfPresent(
            Int.self, forKey: .maxCharsPerCall) ?? base.maxCharsPerCall
        self.maxCharsPerCall = max(100, maxChars)
        let calls = try container.decodeIfPresent(
            Int.self, forKey: .callsPerMinute) ?? base.callsPerMinute
        self.callsPerMinute = max(1, calls)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(excludeJunkAndTrash, forKey: .excludeJunkAndTrash)
        try container.encode(excludedAccounts, forKey: .excludedAccounts)
        try container.encode(excludedMailboxes, forKey: .excludedMailboxes)
        try container.encode(excludedLabels, forKey: .excludedLabels)
        try container.encode(redaction, forKey: .redaction)
        try container.encode(maxResultsPerCall, forKey: .maxResultsPerCall)
        try container.encode(maxCharsPerCall, forKey: .maxCharsPerCall)
        try container.encode(callsPerMinute, forKey: .callsPerMinute)
    }
}

extension ArchiveStore {
    /// Resolves a person's policy against this index (DESIGN 9A): the
    /// named exclusions become id sets, and `junk`/`trash` roles join
    /// them when the policy says so. Names that match nothing stay
    /// silent — writing a name that is not in the index yet must not
    /// error, and must start matching the moment it appears. Mailbox
    /// names compare on the last path component of the folder name, so
    /// `Work/Invoices` matches an exclusion of `Invoices` in any account.
    public func resolveVisibility(policy: AccessPolicy) throws -> MessageVisibility {
        var excludedMailboxIDs = Set<Int64>()
        var excludedAccountIDs = Set<Int64>()
        var excludedLabelIDs = Set<Int64>()

        let wantedMailboxes = Set(policy.excludedMailboxes.map { $0.lowercased() })
        let wantedAccounts = Set(policy.excludedAccounts.map { $0.lowercased() })
        let wantedLabels = Set(policy.excludedLabels.map { $0.lowercased() })

        try db.read { db in
            for row in try Row.fetchAll(db, sql: "SELECT id, email FROM account") {
                let email: String = row["email"]
                if wantedAccounts.contains(email.lowercased()) {
                    excludedAccountIDs.insert(row["id"])
                }
            }
            for row in try Row.fetchAll(db, sql: "SELECT id, name FROM mailbox") {
                let name: String = row["name"]
                let leaf = MessageVisibility.leafName(name).lowercased()
                if wantedMailboxes.contains(leaf) {
                    excludedMailboxIDs.insert(row["id"])
                }
            }
            for row in try Row.fetchAll(db, sql: "SELECT id, name FROM label") {
                let name: String = row["name"]
                if wantedLabels.contains(name.lowercased()) {
                    excludedLabelIDs.insert(row["id"])
                }
            }
            if policy.excludeJunkAndTrash {
                excludedMailboxIDs.formUnion(try Int64.fetchAll(
                    db,
                    sql: "SELECT id FROM mailbox WHERE role IN ('junk', 'trash')"
                ))
            }
        }
        return MessageVisibility(
            excludedMailboxIDs: excludedMailboxIDs,
            excludedAccountIDs: excludedAccountIDs,
            excludedLabelIDs: excludedLabelIDs
        )
    }

    /// Whether one message passes a visibility filter — the per-message
    /// gate for lookups that go straight to an id (get_message,
    /// get_thread, resources, attachment text). Answering false here is
    /// what makes a hidden id indistinguishable from a missing one.
    public func messageIsVisible(
        messageID: Int64, visibility: MessageVisibility
    ) throws -> Bool {
        try db.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                SELECT \(visibility.predicate(messageAlias: "message"))
                FROM message WHERE message.id = ?
                """,
                arguments: [messageID]
            ) ?? false
        }
    }
}
