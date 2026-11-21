import XCTest
import GRDB
@testable import ArchiveCore

/// The read-side queries the MCP tools rest on (DESIGN 9A): thread
/// listings, attachment listings with their OCR state, labels, contacts,
/// archive stats, and per-part attachment text. Everything is read-only
/// toward the store; ingest happens only in setup, and every archive is a
/// temporary directory.
final class AgentQueryTests: XCTestCase {
    private var tempDir: URL!
    private var store: ArchiveStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("geist9-agent-query-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = try ArchiveStore.create(at: archiveURL, appVersion: "0.1.0")
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
    }

    private var archiveURL: URL { tempDir.appendingPathComponent("AgentQuery.emailarchive") }

    @discardableResult
    private func ingest(
        subject: String,
        body: String,
        dateReceived: String,
        from: Recipient,
        to: [Recipient] = [],
        messageID: String,
        uid: Int64,
        labels: [LabelName] = [],
        attachments: [AttachmentInfo] = [],
        inReplyTo: [String] = []
    ) throws -> IngestResult {
        let record = MessageRecord(
            subject: subject,
            normalizedSubject: subject.isEmpty ? nil : subject,
            dateSent: Timestamp.date(dateReceived),
            dateReceived: Timestamp.date(dateReceived),
            messageID: messageID,
            inReplyTo: inReplyTo,
            from: from,
            to: to
        )
        let data = Data("""
        From: \(from.email)\r
        To: \(to.map(\.email).joined(separator: ", "))\r
        Subject: \(subject)\r
        \r
        \(body)\r

        """.utf8)
        return try store.ingest(
            IngestedMessage(
                record: record,
                data: data,
                memberships: [Membership(mailbox: "INBOX", uid: uid)],
                labels: labels,
                attachments: attachments,
                searchText: SearchText(body: body, quoted: nil)
            ),
            into: AccountIdentity(
                email: "alice@example.com",
                displayName: "Alice Personal",
                providerKind: "import"
            )
        )
    }

    // MARK: - Threads

    func testThreadMessagesOldestFirstWithSubject() throws {
        _ = try ingest(
            subject: "Lease renewal",
            body: "alpha lease letter",
            dateReceived: "2023-11-02T09:15:00Z",
            from: Recipient(name: "Alice", email: "alice@example.com"),
            to: [Recipient(name: "Bob", email: "bob@example.org")],
            messageID: "lease-1@example.com",
            uid: 1
        )
        _ = try ingest(
            subject: "Re: Lease renewal",
            body: "beta lease letter",
            dateReceived: "2024-01-10T11:00:00Z",
            from: Recipient(name: "Bob", email: "bob@example.org"),
            to: [Recipient(name: "Alice", email: "alice@example.com")],
            messageID: "lease-2@example.org",
            uid: 2,
            inReplyTo: ["lease-1@example.com"]
        )
        _ = try ingest(
            subject: "Unrelated note",
            body: "gamma letter",
            dateReceived: "2024-02-01T08:00:00Z",
            from: Recipient(name: "Carol", email: "carol@example.net"),
            to: [Recipient(name: "Alice", email: "alice@example.com")],
            messageID: "note-1@example.net",
            uid: 3
        )

        let alpha = try store.search("alpha", limit: 10)
        let threadID = try XCTUnwrap(alpha.hits.first?.threadID)

        let subject = try store.threadSubject(threadID: threadID)
        XCTAssertEqual(subject, "Lease renewal")

        let messages = try store.threadMessages(threadID: threadID)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.map(\.fromEmail), ["alice@example.com", "bob@example.org"])
        let dates = messages.map { $0.dateReceived ?? .distantPast }
        XCTAssertEqual(dates, dates.sorted())
        // Only the two thread members, not the unrelated message.
        XCTAssertFalse(messages.map(\.subject).contains("Unrelated note"))

        // Unknown thread id: no subject, no messages.
        XCTAssertNil(try store.threadSubject(threadID: 999_999))
        XCTAssertTrue(try store.threadMessages(threadID: 999_999).isEmpty)
    }

    // MARK: - Attachments

    private let mimeWithAttachments = """
    From: alice@example.com\r
    To: bob@example.org\r
    Subject: Prices\r
    Message-ID: <prices-1@example.com>\r
    Content-Type: multipart/mixed; boundary="BOUND"\r
    \r
    --BOUND\r
    Content-Type: text/plain\r
    \r
    See attached.\r
    --BOUND\r
    Content-Disposition: attachment; filename="prices.csv"\r
    Content-Type: text/csv\r
    \r
    item,price\r
    Widget,9.99\r
    --BOUND\r
    Content-Disposition: attachment; filename="notes.txt"\r
    Content-Type: text/plain\r
    \r
    Plain notes about prices.\r
    --BOUND--\r

    """

    private func ingestMime(_ data: Data) throws -> IngestResult {
        let bridge = try MailBridge.parse(for: data)
        return try store.ingest(
            IngestedMessage(
                record: bridge.record,
                data: data,
                memberships: [Membership(mailbox: "INBOX", uid: 21)],
                attachments: bridge.attachments,
                searchText: bridge.searchText
            ),
            into: AccountIdentity(
                email: "alice@example.com",
                displayName: "Alice Personal",
                providerKind: "import"
            )
        )
    }

    func testMessageAttachmentsInPartOrderWithTextState() throws {
        _ = try ingestMime(Data(mimeWithAttachments.utf8))

        let hit = try store.search("attached", limit: 10)
        let messageID = try XCTUnwrap(hit.hits.first?.messageID)

        let attachments = try store.messageAttachments(messageID: messageID)
        XCTAssertEqual(attachments.map(\.partIndex), ["2", "3"])
        XCTAssertEqual(attachments.map(\.filename), ["prices.csv", "notes.txt"])
        // Non-OCR-eligible parts are settled at ingest (decision 0050).
        XCTAssertEqual(attachments.map(\.textState), ["done", "done"])
        XCTAssertEqual(attachments.first?.contentType, "text/csv")

        // A message without attachments has an empty listing.
        _ = try ingest(
            subject: "No files",
            body: "plain message",
            dateReceived: "2024-03-01T10:00:00Z",
            from: Recipient(name: "Alice", email: "alice@example.com"),
            messageID: "plain-1@example.com",
            uid: 4
        )
        let plainHit = try store.search("plain message", limit: 10)
        let plainID = try XCTUnwrap(plainHit.hits.first?.messageID)
        XCTAssertTrue(try store.messageAttachments(messageID: plainID).isEmpty)
    }

    func testAttachmentTextPerPart() throws {
        let data = Data(mimeWithAttachments.utf8)
        XCTAssertEqual(
            MailBridge.attachmentText(at: "2", in: data),
            "item,price\r\nWidget,9.99"
        )
        XCTAssertEqual(
            MailBridge.attachmentText(at: "3", in: data),
            "Plain notes about prices."
        )
        // Body leaves are not attachments; unknown paths have no part.
        XCTAssertNil(MailBridge.attachmentText(at: "1", in: data))
        XCTAssertNil(MailBridge.attachmentText(at: "4", in: data))
        // Unparseable bytes have no parts at all.
        XCTAssertNil(MailBridge.attachmentText(at: "2", in: Data("not mime".utf8)))
    }

    // MARK: - Labels

    func testMessageLabelsSorted() throws {
        _ = try ingest(
            subject: "Receipts",
            body: "receipt letter",
            dateReceived: "2024-03-02T10:00:00Z",
            from: Recipient(name: "Alice", email: "alice@example.com"),
            messageID: "receipt-1@example.com",
            uid: 5,
            labels: [LabelName(name: "Work"), LabelName(name: "Receipts")]
        )
        let hit = try store.search("receipt", limit: 10)
        let messageID = try XCTUnwrap(hit.hits.first?.messageID)
        XCTAssertEqual(try store.messageLabels(messageID: messageID), ["Receipts", "Work"])

        let other = try store.search("plain message", limit: 10)
        XCTAssertNil(other.hits.first)
    }

    // MARK: - Contacts

    func testFindContactsCountsAndOrder() throws {
        _ = try ingest(
            subject: "One",
            body: "letter one",
            dateReceived: "2023-11-02T09:15:00Z",
            from: Recipient(name: "Alice", email: "alice@example.com"),
            to: [Recipient(name: "Bob", email: "bob@example.org")],
            messageID: "one@example.com",
            uid: 6
        )
        _ = try ingest(
            subject: "Two",
            body: "letter two",
            dateReceived: "2024-01-10T11:00:00Z",
            from: Recipient(name: "Alice", email: "alice@example.com"),
            to: [Recipient(name: "Bob", email: "bob@example.org")],
            messageID: "two@example.com",
            uid: 7
        )
        _ = try ingest(
            subject: "Three",
            body: "letter three",
            dateReceived: "2024-06-20T08:00:00Z",
            from: Recipient(name: "Carol", email: "carol@example.net"),
            to: [Recipient(name: "Alice", email: "alice@example.com")],
            messageID: "three@example.net",
            uid: 8
        )

        let contacts = try store.findContacts()
        XCTAssertEqual(contacts.map(\.email), [
            "alice@example.com", "bob@example.org", "carol@example.net",
        ])
        // A message counts for an address once, whatever roles it carries.
        XCTAssertEqual(contacts.map(\.messageCount), [3, 2, 1])
        XCTAssertEqual(contacts[0].name, "Alice")
        XCTAssertEqual(contacts[0].firstDate, Timestamp.date("2023-11-02T09:15:00Z"))
        XCTAssertEqual(contacts[0].lastDate, Timestamp.date("2024-06-20T08:00:00Z"))
        XCTAssertEqual(contacts[1].name, "Bob")

        // The limit caps the list, most involved addresses first.
        let capped = try store.findContacts(limit: 1)
        XCTAssertEqual(capped.map(\.email), ["alice@example.com"])
    }

    // MARK: - Archive stats

    func testArchiveStatsByAccountYearAndSender() throws {
        _ = try ingest(
            subject: "One",
            body: "letter one",
            dateReceived: "2023-11-02T09:15:00Z",
            from: Recipient(name: "Alice", email: "alice@example.com"),
            to: [Recipient(name: "Bob", email: "bob@example.org")],
            messageID: "one@example.com",
            uid: 6
        )
        _ = try ingest(
            subject: "Two",
            body: "letter two",
            dateReceived: "2024-01-10T11:00:00Z",
            from: Recipient(name: "Alice", email: "alice@example.com"),
            to: [Recipient(name: "Bob", email: "bob@example.org")],
            messageID: "two@example.com",
            uid: 7
        )
        _ = try ingest(
            subject: "Three",
            body: "letter three",
            dateReceived: "2024-06-20T08:00:00Z",
            from: Recipient(name: "Carol", email: "carol@example.net"),
            to: [Recipient(name: "Alice", email: "alice@example.com")],
            messageID: "three@example.net",
            uid: 8
        )

        let stats = try store.archiveStats()
        // Both messages and the reply live in the one test account.
        XCTAssertEqual(stats.byAccount.map(\.email), ["alice@example.com"])
        XCTAssertEqual(stats.byAccount.first?.messageCount, 3)
        XCTAssertEqual(stats.byYear.map(\.year), ["2023", "2024"])
        XCTAssertEqual(stats.byYear.map(\.messageCount), [1, 2])
        XCTAssertEqual(stats.bySender.count, 2)
        XCTAssertEqual(stats.bySender[0].email, "alice@example.com")
        XCTAssertEqual(stats.bySender[0].messageCount, 2)
        XCTAssertEqual(stats.bySender[1].email, "carol@example.net")
        XCTAssertEqual(stats.bySender[0].firstDate, Timestamp.date("2023-11-02T09:15:00Z"))
        // The sender list counts messages the address sent; the third
        // message has alice only as a recipient.
        XCTAssertEqual(stats.bySender[0].lastDate, Timestamp.date("2024-01-10T11:00:00Z"))

        // The sender list is capped; year and account lists are not.
        let capped = try store.archiveStats(senderLimit: 1)
        XCTAssertEqual(capped.bySender.count, 1)
        XCTAssertEqual(capped.bySender.first?.email, "alice@example.com")
        XCTAssertEqual(capped.byYear.count, 2)
    }
}
