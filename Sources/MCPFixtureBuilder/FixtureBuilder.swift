import ArchiveCore
import Foundation

/// Builds the tiny fixture archive the MCP inspector gate (DESIGN 9A) drives.
/// The archive mirrors the end-to-end test's fixture: two messages in one
/// thread plus one unrelated message, so every tool the inspector probes has
/// real data to touch. Writing it through the same public ingest path keeps
/// the gate in step with schema migrations automatically.
@main
struct FixtureBuilder {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(Data("usage: mcp-fixture-builder <archive path>\n".utf8))
            exit(2)
        }
        let path = CommandLine.arguments[1]
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.removeItem(at: url)
        let store = try ArchiveStore.create(at: url, appVersion: "0.1.0")

        func ingest(
            subject: String,
            body: String,
            dateReceived: String,
            from: Recipient,
            messageID: String,
            uid: Int64,
            inReplyTo: [String] = []
        ) throws {
            let record = MessageRecord(
                subject: subject,
                normalizedSubject: subject,
                dateSent: Timestamp.date(dateReceived),
                dateReceived: Timestamp.date(dateReceived),
                messageID: messageID,
                inReplyTo: inReplyTo,
                from: from,
                to: [Recipient(name: "Alice", email: "alice@example.com")]
            )
            let data = Data("""
            From: \(from.email)\r
            Subject: \(subject)\r
            \r
            \(body)\r

            """.utf8)
            _ = try store.ingest(
                IngestedMessage(
                    record: record,
                    data: data,
                    memberships: [Membership(mailbox: "INBOX", uid: uid)],
                    labels: [],
                    attachments: [],
                    searchText: SearchText(body: body, quoted: nil)
                ),
                into: AccountIdentity(
                    email: "alice@example.com",
                    displayName: "Alice Personal",
                    providerKind: "import"
                )
            )
        }

        try ingest(
            subject: "Lease renewal",
            body: "alpha lease letter",
            dateReceived: "2023-11-02T09:15:00Z",
            from: Recipient(name: "Alice", email: "alice@example.com"),
            messageID: "lease-1@example.com",
            uid: 1
        )
        try ingest(
            subject: "Re: Lease renewal",
            body: "beta lease letter",
            dateReceived: "2024-01-10T11:00:00Z",
            from: Recipient(name: "Bob", email: "bob@example.org"),
            messageID: "lease-2@example.org",
            uid: 2,
            inReplyTo: ["lease-1@example.com"]
        )
        try ingest(
            subject: "Unrelated note",
            body: "gamma letter",
            dateReceived: "2024-02-01T08:00:00Z",
            from: Recipient(name: "Carol", email: "carol@example.net"),
            messageID: "note-1@example.net",
            uid: 3
        )
        FileHandle.standardError.write(Data("fixture archive written: \(path)\n".utf8))
    }
}
