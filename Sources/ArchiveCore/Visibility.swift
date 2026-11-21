// Read-side visibility (DESIGN 9A): what a client of the archive may
// see. The archive itself stays complete and untouched; visibility is a
// query-layer filter. The MCP layer resolves a person's access policy
// into id sets (against this exact index), and the queries here append
// the predicate, so excluded messages never surface through any tool.
// Everything is SQL-side: one predicate shape, tested against the real
// index, so counts, listings, searches and contacts all agree.

/// The set of messages a client may see, expressed as exclusions
/// resolved against the index. Empty sets mean no restriction.
public struct MessageVisibility: Sendable, Equatable {
    /// Mailboxes the client may not see messages through. A message in
    /// an allowed mailbox AND an excluded one stays visible.
    public var excludedMailboxIDs: Set<Int64>
    /// Accounts excluded whole: no message of theirs is visible.
    public var excludedAccountIDs: Set<Int64>
    /// Labels whose messages are hidden.
    public var excludedLabelIDs: Set<Int64>

    public init(
        excludedMailboxIDs: Set<Int64> = [],
        excludedAccountIDs: Set<Int64> = [],
        excludedLabelIDs: Set<Int64> = []
    ) {
        self.excludedMailboxIDs = excludedMailboxIDs
        self.excludedAccountIDs = excludedAccountIDs
        self.excludedLabelIDs = excludedLabelIDs
    }

    /// True when nothing is excluded: callers may skip the predicate.
    public var isPermissive: Bool {
        excludedMailboxIDs.isEmpty
            && excludedAccountIDs.isEmpty
            && excludedLabelIDs.isEmpty
    }

    /// SQL predicate, true for visible messages, evaluated on a row of
    /// `message` aliased `alias`. Id sets are rendered as JSON array
    /// literals and compared through `json_each`: they are ids this
    /// module resolved from the index, so no escaping is involved, and
    /// SQLite's variable limit does not apply.
    public func predicate(messageAlias alias: String) -> String {
        if isPermissive { return "1" }
        let mailboxes = Self.jsonSet(excludedMailboxIDs)
        let accounts = Self.jsonSet(excludedAccountIDs)
        let labels = Self.jsonSet(excludedLabelIDs)
        return """
            (EXISTS (SELECT 1 FROM message_mailbox mm
                     JOIN mailbox mb ON mb.id = mm.mailboxID
                     WHERE mm.messageID = \(alias).id
                       AND mb.id NOT IN (SELECT value FROM json_each('\(mailboxes)'))
                       AND mb.accountID NOT IN (SELECT value FROM json_each('\(accounts)')))
             AND NOT EXISTS (SELECT 1 FROM message_label ml
                     WHERE ml.messageID = \(alias).id
                       AND ml.labelID IN (SELECT value FROM json_each('\(labels)'))))
            """
    }

    /// COUNT argument for a listing that joins messages in: counts only
    /// visible messages when a filter is set, and the join's own message
    /// id otherwise. The distinction matters under LEFT JOIN — a bare
    /// `1` would count the row even when the join found no message, so
    /// an empty mailbox would report one message. With a filter the CASE
    /// yields the message id for visible rows and NULL otherwise (COUNT
    /// ignores NULL, and the NULL-extended join row can never pass a
    /// predicate that reads the message id).
    public func countExpression(messageAlias alias: String, joinedColumn: String) -> String {
        guard !isPermissive else { return joinedColumn }
        return "CASE WHEN \(predicate(messageAlias: alias)) THEN \(alias).id END"
    }

    /// Extra WHERE conjuncts for a `mailbox` row aliased `alias`: rows
    /// of excluded mailboxes or of excluded accounts never pass. Empty
    /// string when permissive.
    public func mailboxRowExclusion(mailboxAlias alias: String) -> String {
        guard !isPermissive else { return "" }
        let mailboxes = Self.jsonSet(excludedMailboxIDs)
        let accounts = Self.jsonSet(excludedAccountIDs)
        return
            " AND \(alias).id NOT IN (SELECT value FROM json_each('\(mailboxes)'))"
            + " AND \(alias).accountID NOT IN (SELECT value FROM json_each('\(accounts)'))"
    }

    /// Extra WHERE conjunct for a `label` row aliased `alias`.
    public func labelRowExclusion(labelAlias alias: String) -> String {
        guard !isPermissive else { return "" }
        let labels = Self.jsonSet(excludedLabelIDs)
        return " AND \(alias).id NOT IN (SELECT value FROM json_each('\(labels)'))"
    }

    /// Compact JSON array literal for id sets, in sorted order so the
    /// generated SQL is deterministic (nice in tests and logs).
    static func jsonSet(_ ids: Set<Int64>) -> String {
        "[\(ids.sorted().map(String.init).joined(separator: ","))]"
    }

    /// The last path component of a folder name, tolerant of either
    /// separator: `Work/Invoices` and `Work\Invoices` both end at
    /// `Invoices`. Policy files name folders this way.
    public static func leafName(_ name: String) -> String {
        name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? name
    }
}
