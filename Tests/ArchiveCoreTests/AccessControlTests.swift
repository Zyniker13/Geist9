import XCTest
import GRDB
@testable import ArchiveCore

/// Access control (DESIGN 9A): the person's policy resolves against the
/// index into id sets, and every read filters through that one
/// `MessageVisibility` — SQL-side, so counts, listings, searches and
/// lookups all agree. These tests pin the contract the MCP layer leans
/// on: hidden ids are indistinguishable from missing ones, counts never
/// leak hidden rows, and the permissive path answers exactly like a
/// no-filter call.
final class AccessControlTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("geist9-access-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
    }

    private var archiveURL: URL { tempDir.appendingPathComponent("Access.emailarchive") }

    private struct Fixture {
        var visible: Int64        // alice, INBOX, no label
        var hiddenMailbox: Int64  // alice, Work/Invoices
        var hiddenJunk: Int64     // alice, Junk
        var hiddenLabel: Int64    // alice, INBOX, label Private
        var hiddenAccount: Int64  // bob, INBOX
        var threadHiddenMember: Int64  // alice, Work/Invoices, replies to `visible`
    }

    /// Five messages, each hidden a different way, plus one thread whose
    /// second member sits in a hidden folder (partial visibility).
    private func makeArchive() throws -> (ArchiveStore, Fixture) {
        let store = try ArchiveStore.create(at: archiveURL, appVersion: "0.1.0")
        func ingest(
            subject: String,
            body: String,
            dateReceived: String,
            from: Recipient,
            messageID: String,
            mailbox: String,
            labels: [LabelName] = [],
            inReplyTo: [String] = [],
            intoAccountEmail: String = "alice@example.com"
        ) throws -> Int64 {
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
            let data = Data("From: \(from.email)\r\nSubject: \(subject)\r\n\r\n\(body)\r\n".utf8)
            let result = try store.ingest(
                IngestedMessage(
                    record: record,
                    data: data,
                    memberships: [Membership(mailbox: mailbox, uid: nil)],
                    labels: labels,
                    attachments: [],
                    searchText: SearchText(body: body, quoted: nil)
                ),
                into: AccountIdentity(
                    email: intoAccountEmail,
                    displayName: intoAccountEmail,
                    providerKind: "import"
                )
            )
            switch result {
            case .created(let id): return id
            case .duplicate(let id): return id
            }
        }
        let visible = try ingest(
            subject: "Lease renewal", body: "delta lease letter",
            dateReceived: "2024-01-01T09:00:00Z",
            from: Recipient(name: "Alice", email: "alice@example.com"),
            messageID: "lease-1@example.com", mailbox: "INBOX"
        )
        let hiddenMailbox = try ingest(
            subject: "Invoice overdue", body: "delta invoice letter",
            dateReceived: "2024-01-02T09:00:00Z",
            from: Recipient(name: "Billing", email: "billing@example.com"),
            messageID: "invoice-1@example.com", mailbox: "Work/Invoices"
        )
        let hiddenJunk = try ingest(
            subject: "You won a prize", body: "delta prize letter",
            dateReceived: "2024-01-03T09:00:00Z",
            from: Recipient(name: "Prizes", email: "prizes@example.com"),
            messageID: "prize-1@example.com", mailbox: "Junk"
        )
        let hiddenLabel = try ingest(
            subject: "Doctor results", body: "delta medical letter",
            dateReceived: "2024-01-04T09:00:00Z",
            from: Recipient(name: "Clinic", email: "clinic@example.com"),
            messageID: "clinic-1@example.com", mailbox: "INBOX",
            labels: [LabelName(name: "Private")]
        )
        let hiddenAccount = try ingest(
            subject: "Side project", body: "vector only note",
            dateReceived: "2024-01-05T09:00:00Z",
            from: Recipient(name: "Bob", email: "bob@example.org"),
            messageID: "side-1@example.org", mailbox: "INBOX",
            intoAccountEmail: "bob@example.org"
        )
        let threadHiddenMember = try ingest(
            subject: "Re: Lease renewal", body: "delta reply letter",
            dateReceived: "2024-01-06T09:00:00Z",
            from: Recipient(name: "Billing", email: "billing@example.com"),
            messageID: "lease-2@example.com", mailbox: "Work/Invoices",
            inReplyTo: ["lease-1@example.com"]
        )
        return (store, Fixture(
            visible: visible,
            hiddenMailbox: hiddenMailbox,
            hiddenJunk: hiddenJunk,
            hiddenLabel: hiddenLabel,
            hiddenAccount: hiddenAccount,
            threadHiddenMember: threadHiddenMember
        ))
    }

    /// The policy every visibility test filters through: one of each
    /// exclusion kind, matched case-insensitively; junk/trash by role.
    private func policy() -> AccessPolicy {
        AccessPolicy(
            excludeJunkAndTrash: true,
            excludedAccounts: ["BOB@example.ORG"],
            excludedMailboxes: ["invoices"],
            excludedLabels: ["private"],
            redaction: .none,
            maxResultsPerCall: 100,
            maxCharsPerCall: 200_000,
            callsPerMinute: 60
        )
    }

    // MARK: - Policy resolution

    func testResolveVisibilityMapsNamesToIDs() throws {
        let (store, f) = try makeArchive()

        let vis = try store.resolveVisibility(policy: policy())

        XCTAssertTrue(try store.messageIsVisible(messageID: f.visible, visibility: vis))
        XCTAssertFalse(try store.messageIsVisible(messageID: f.hiddenMailbox, visibility: vis))
        XCTAssertFalse(try store.messageIsVisible(messageID: f.hiddenJunk, visibility: vis))
        XCTAssertFalse(try store.messageIsVisible(messageID: f.hiddenLabel, visibility: vis))
        XCTAssertFalse(try store.messageIsVisible(messageID: f.hiddenAccount, visibility: vis))
    }

    func testUnknownNamesStaySilentAndPermissivePolicySeesAll() throws {
        let (store, f) = try makeArchive()

        // A name that matches nothing resolves silently — it must start
        // matching the moment it appears, not error at launch.
        let future = AccessPolicy(
            excludeJunkAndTrash: false,
            excludedAccounts: ["nobody@example.net"],
            excludedMailboxes: ["not-a-folder"],
            excludedLabels: ["not-a-label"],
            redaction: .none,
            maxResultsPerCall: 100,
            maxCharsPerCall: 200_000,
            callsPerMinute: 60
        )
        let vis = try store.resolveVisibility(policy: future)
        XCTAssertTrue(try store.messageIsVisible(messageID: f.visible, visibility: vis))
        // With no exclusions matched and junk allowed, everything is visible.
        XCTAssertTrue(try store.messageIsVisible(messageID: f.hiddenMailbox, visibility: vis))
        XCTAssertTrue(try store.messageIsVisible(messageID: f.hiddenJunk, visibility: vis))
        XCTAssertTrue(try store.messageIsVisible(messageID: f.hiddenAccount, visibility: vis))

        // The empty policy (no names, junk allowed) is the truly
        // permissive one; it answers exactly like a no-filter call.
        let empty = AccessPolicy(
            excludeJunkAndTrash: false,
            excludedAccounts: [], excludedMailboxes: [], excludedLabels: [],
            redaction: .none, maxResultsPerCall: 100,
            maxCharsPerCall: 200_000, callsPerMinute: 60
        )
        let permissive = try store.resolveVisibility(policy: empty)
        XCTAssertTrue(permissive.isPermissive)
        for id in [f.visible, f.hiddenMailbox, f.hiddenJunk, f.hiddenLabel, f.hiddenAccount] {
            XCTAssertTrue(try store.messageIsVisible(messageID: id, visibility: permissive))
        }
    }

    func testExcludeJunkAndTrashToggle() throws {
        let (store, f) = try makeArchive()

        let keeping = try store.resolveVisibility(policy: policy())
        XCTAssertFalse(try store.messageIsVisible(messageID: f.hiddenJunk, visibility: keeping))

        let allowing = AccessPolicy(
            excludeJunkAndTrash: false,
            excludedAccounts: [], excludedMailboxes: [], excludedLabels: [],
            redaction: .none, maxResultsPerCall: 100,
            maxCharsPerCall: 200_000, callsPerMinute: 60
        )
        let vis = try store.resolveVisibility(policy: allowing)
        XCTAssertTrue(try store.messageIsVisible(messageID: f.hiddenJunk, visibility: vis))
    }

    // MARK: - Per-message gate

    func testMessageIsVisibleAnswersFalseForMissingIDs() throws {
        let (store, f) = try makeArchive()
        let vis = try store.resolveVisibility(policy: policy())

        // Hidden and unknown must be indistinguishable: both false.
        XCTAssertFalse(try store.messageIsVisible(messageID: f.hiddenMailbox, visibility: vis))
        XCTAssertFalse(try store.messageIsVisible(messageID: 999, visibility: vis))
    }

    // MARK: - Search-side enforcement (SQL, before LIMIT/OFFSET)

    func testKeywordSearchFiltersSQLSide() throws {
        let (store, f) = try makeArchive()
        let vis = try store.resolveVisibility(policy: policy())

        // Every body but the account-hidden one contains "delta": the
        // permissive keyword search finds all five, the filtered search
        // exactly the visible one.
        let permissive = try store.search("delta", limit: 50)
        XCTAssertEqual(
            Set(permissive.hits.map(\.messageID)),
            [f.visible, f.hiddenMailbox, f.hiddenJunk, f.hiddenLabel, f.threadHiddenMember]
        )

        let filtered = try store.search("delta", limit: 50, visible: vis)
        XCTAssertEqual(filtered.hits.map(\.messageID), [f.visible])

        // Pagination agrees with the count: page two under the filter is
        // empty, proving the predicate ran before OFFSET, not after.
        let pageTwo = try store.search("delta", limit: 1, offset: 1, visible: vis)
        XCTAssertTrue(pageTwo.hits.isEmpty)
    }

    func testVectorSideDropsHiddenBeforeFusion() throws {
        let (store, f) = try makeArchive()
        let vis = try store.resolveVisibility(policy: policy())

        // Seed embeddings so the account-hidden message is reachable only
        // through the semantic side: its body never matches the query text.
        let model = FixedEmbedding()
        try store.db.write { db in
            for id in [f.visible, f.hiddenMailbox, f.hiddenAccount] {
                try VectorIndex.upsert(
                    db, messageID: id, model: model.identifier,
                    vector: [1, 0, 0, 0]
                )
            }
        }

        let permissive = try store.search(
            "delta", limit: 50, semanticModel: model
        )
        // Keyword reaches the five "delta" bodies; the semantic side adds
        // the seeded account-hidden message whose body has no "delta".
        XCTAssertEqual(
            Set(permissive.hits.map(\.messageID)),
            [f.visible, f.hiddenMailbox, f.hiddenJunk, f.hiddenLabel,
             f.hiddenAccount, f.threadHiddenMember]
        )

        let filtered = try store.search(
            "delta", limit: 50, semanticModel: model, visible: vis
        )
        // The account-hidden message was only ever reachable through the
        // semantic side — its absence from the filtered result is the
        // vector-side filter proving itself.
        XCTAssertEqual(filtered.hits.map(\.messageID), [f.visible])
    }

    // MARK: - Listings

    func testAccountAndMailboxListingsHideExcluded() throws {
        let (store, _) = try makeArchive()
        let vis = try store.resolveVisibility(policy: policy())

        let accounts = try store.listAccounts(visible: vis)
        let counts = Dictionary(
            uniqueKeysWithValues: accounts.map { ($0.email, $0.messageCount) }
        )
        // Counts are filtered SQL-side: alice keeps exactly her one
        // visible message; bob's excluded account reports zero.
        XCTAssertEqual(counts["alice@example.com"], 1)
        XCTAssertEqual(counts["bob@example.org"], 0)

        // Unfiltered counts answer as before the filter existed.
        let unfiltered = try store.listAccounts()
        let unfilteredCounts = Dictionary(
            uniqueKeysWithValues: unfiltered.map { ($0.email, $0.messageCount) }
        )
        XCTAssertEqual(unfilteredCounts["alice@example.com"], 5)
        XCTAssertEqual(unfilteredCounts["bob@example.org"], 1)

        let aliceBoxes = try store.listMailboxes(
            accountEmail: "alice@example.com", visible: vis
        )
        // INBOX stays, with only its visible message counted; Invoices is
        // excluded outright; Junk is excluded by role; nothing reports 0.
        XCTAssertEqual(aliceBoxes.map(\.name), ["INBOX"])
        XCTAssertEqual(aliceBoxes.map(\.messageCount), [1])
    }

    // MARK: - Threads

    func testThreadMessagesLeaveHiddenMembersOut() throws {
        let (store, f) = try makeArchive()
        let vis = try store.resolveVisibility(policy: policy())

        // The thread holds the visible lease renewal and the hidden reply
        // in Work/Invoices: permissive shows both, filtered shows one, and
        // the count a client sees matches the listing.
        let threadID: Int64 = 1
        let permissive = try store.threadMessages(threadID: threadID)
        XCTAssertEqual(permissive.map(\.id), [f.visible, f.threadHiddenMember])

        let filtered = try store.threadMessages(threadID: threadID, visible: vis)
        XCTAssertEqual(filtered.map(\.id), [f.visible])
    }
}

/// A deterministic fake embedding model: every text and every query maps
/// to the same unit vector, so all seeded documents tie at cosine 1.0 and
/// the test controls reachability purely through which ids it seeds.
private struct FixedEmbedding: EmbeddingModel {
    var identifier: String { "access-probe-v1" }
    var dimension: Int { 4 }
    func embed(_ text: String) -> [Float]? { [1, 0, 0, 0] }
    func queryEmbed(_ text: String) -> [Float]? { [1, 0, 0, 0] }
}
