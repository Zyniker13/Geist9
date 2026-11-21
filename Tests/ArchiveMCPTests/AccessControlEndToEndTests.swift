// Access-control end to end (DESIGN 9A 9A.4a): the policy shapes every
// answer the helper gives, over real stdio JSON-RPC, with no mocking of the
// protocol. The failure modes pinned here are the ones that matter:
//
//   1. A policy file that cannot be read refuses the launch — never starts
//      with a silently permissive filter (checked by exit status).
//   2. Under a filtered policy the hidden message is indistinguishable from
//      a missing one at every surface: search, get_message, resources,
//      threads, attachments, contacts.
//   3. Names in the policy that match nothing stay silent and permissive.
//
// The core-layer guarantees (SQL-side filtering, no count/offset leaks)
// have their own tests in ArchiveCoreTests/AccessControlTests.swift; this
// file checks that the MCP layer upholds them over the wire.

import ArchiveCore
import XCTest

final class AccessControlEndToEndTests: XCTestCase {
    private var tempDir: URL!
    private var process: Process?

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("geist9-mcp-policy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let process, process.isRunning {
            process.terminate()
        }
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        process = nil
    }

    // MARK: - Fixture

    private var archiveURL: URL { tempDir.appendingPathComponent("Policy.emailarchive") }

    /// A thread (visible root, visible reply), a Work/Invoices message, a
    /// Junk message, a Private-labeled message, and a message in a second
    /// account whose whole account is excluded. Returns nothing; ids are
    /// deterministic 1..5 in ingest order.
    @discardableResult
    private func makeFilteredFixture() throws -> ArchiveStore {
        let store = try ArchiveStore.create(at: archiveURL, appVersion: "0.1.0")
        func ingest(
            subject: String,
            body: String,
            dateReceived: String,
            from: Recipient,
            messageID: String,
            uid: Int64,
            inReplyTo: [String] = [],
            mailbox: String = "INBOX",
            labels: [LabelName] = [],
            intoAccountEmail: String = "alice@example.com"
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
                    memberships: [Membership(mailbox: mailbox, uid: uid)],
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
        }
        try ingest(
            subject: "Lease renewal", body: "alpha lease letter",
            dateReceived: "2023-11-02T09:15:00Z",
            from: Recipient(name: "Alice", email: "alice@example.com"),
            messageID: "lease-1@example.com", uid: 1
        )
        try ingest(
            subject: "Re: Lease renewal", body: "beta lease letter",
            dateReceived: "2024-01-10T11:00:00Z",
            from: Recipient(name: "Bob", email: "bob@example.org"),
            messageID: "lease-2@example.org", uid: 2,
            inReplyTo: ["lease-1@example.com"]
        )
        try ingest(
            subject: "Invoice #7", body: "gamma invoice letter",
            dateReceived: "2024-02-01T08:00:00Z",
            from: Recipient(name: "Billing", email: "billing@example.com"),
            messageID: "invoice-1@example.com", uid: 3,
            mailbox: "Work/Invoices"
        )
        try ingest(
            subject: "You won a prize", body: "delta prize letter",
            dateReceived: "2024-02-02T08:00:00Z",
            from: Recipient(name: "Prizes", email: "prizes@example.com"),
            messageID: "prize-1@example.com", uid: 4,
            mailbox: "Junk"
        )
        try ingest(
            subject: "Medical results", body: "epsilon clinic letter",
            dateReceived: "2024-02-03T08:00:00Z",
            from: Recipient(name: "Clinic", email: "clinic@example.com"),
            messageID: "clinic-1@example.com", uid: 5,
            labels: [LabelName(name: "Private")]
        )
        try ingest(
            subject: "Side project", body: "zeta vector note",
            dateReceived: "2024-02-04T08:00:00Z",
            from: Recipient(name: "Bob", email: "bob@example.org"),
            messageID: "side-1@example.org", uid: 1,
            intoAccountEmail: "bob@example.org"
        )
        return store
    }

    private func writePolicyFile(_ json: String) throws -> String {
        let url = tempDir.appendingPathComponent("policy.json")
        try Data(json.utf8).write(to: url)
        return url.path
    }

    // MARK: - Executable discovery

    private func helperExecutableURL() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["MCP_HELPER_BIN"],
           FileManager.default.fileExists(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/ArchiveMCPTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // package root
        let candidates = [
            packageRoot.appendingPathComponent(".build/debug/email-archiver-mcp"),
            packageRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/email-archiver-mcp"),
            packageRoot.appendingPathComponent(".build/x86_64-apple-macosx/debug/email-archiver-mcp"),
        ]
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        throw PolicyE2EError("email-archiver-mcp not built; run swift build --build-tests first")
    }

    /// The policy every filtered test uses: exclude the Invoices folder, the
    /// Private label, bob's account; junk stays excluded by default.
    private func filteredPolicyJSON() -> String {
        """
        {
          "excludedAccounts": ["bob@example.org"],
          "excludedMailboxes": ["Invoices"],
          "excludedLabels": ["Private"],
          "redaction": "none",
          "maxResultsPerCall": 100,
          "maxCharsPerCall": 200000,
          "callsPerMinute": 60
        }
        """
    }

    // MARK: - 1. Unreadable policy refuses the launch

    func testUnreadablePolicyFileRefusesTheLaunch() throws {
        _ = try makeFilteredFixture()
        let executable = try helperExecutableURL()
        let client = try StdioMCPClient(
            executable: executable, archivePath: archiveURL.path,
            extraEnvironment: [
                "BRISTLECONE_ACCESS_POLICY":
                    tempDir.appendingPathComponent("no-such-policy.json").path,
            ]
        )
        defer { client.shutdown() }
        process = client.process
        let proc = try XCTUnwrap(process, "the helper process must exist")
        let exited = expectation(description: "helper exits")
        proc.terminationHandler = { _ in exited.fulfill() }
        client.shutdown()
        wait(for: [exited], timeout: 30)
        XCTAssertNotEqual(
            proc.terminationStatus, 0,
            "an unreadable policy must refuse the launch, not start permissive"
        )
    }

    // MARK: - 2. The filtered policy shapes every answer

    func testFilteredPolicyShapesEveryAnswer() throws {
        _ = try makeFilteredFixture()
        let executable = try helperExecutableURL()
        let client = try StdioMCPClient(
            executable: executable, archivePath: archiveURL.path,
            extraEnvironment: [
                "BRISTLECONE_ACCESS_POLICY": try writePolicyFile(filteredPolicyJSON()),
            ]
        )
        defer { client.shutdown() }
        process = client.process

        try client.requestResult("initialize", params: [
            "protocolVersion": "2025-06-18",
            "capabilities": [String: Any](),
            "clientInfo": ["name": "geist9-policy-test", "version": "0.0.0"],
        ])
        client.notify("notifications/initialized")

        // tools/list is unchanged by filtering: the shape is stable, the
        // answers are filtered.
        let tools = try client.requestResult("tools/list", params: [String: Any]())
        XCTAssertEqual((tools["tools"] as? [[String: Any]])?.count, 10)

        // search: exactly the visible thread pair; count is the filtered
        // count, not the archive count.
        let search = try client.requestResult("tools/call", params: [
            "name": "search_messages",
            "arguments": ["query": "letter", "limit": 50],
        ])
        let searchContent = try policyDict(search["structuredContent"])
        let hitIDs = Set(try policyArray(searchContent["messages"]).map { try policyInt($0["id"]) })
        XCTAssertEqual(hitIDs, [1, 2], "only the visible thread members match; got \(hitIDs.sorted())")
        XCTAssertEqual(try policyInt(searchContent["count"]), 2)

        // get_message on a hidden id: the request fails, exactly like an
        // unknown id would.
        let hiddenByFolder = try client.request("tools/call", params: [
            "name": "get_message", "arguments": ["id": 3],
        ])
        XCTAssertNotNil(hiddenByFolder["error"], "folder-hidden message must fail like a missing one")
        let hiddenByLabel = try client.request("tools/call", params: [
            "name": "get_message", "arguments": ["id": 5],
        ])
        XCTAssertNotNil(hiddenByLabel["error"], "label-hidden message must fail like a missing one")
        let hiddenByAccount = try client.request("tools/call", params: [
            "name": "get_message", "arguments": ["id": 6],
        ])
        XCTAssertNotNil(hiddenByAccount["error"], "account-hidden message must fail like a missing one")

        // The visible message still answers, with the untrusted fence.
        let visible = try client.requestResult("tools/call", params: [
            "name": "get_message", "arguments": ["id": 1],
        ])
        XCTAssertNil(visible["isError"])
        XCTAssertTrue(
            try policyStr(try policyDict(visible["structuredContent"])["subject"]).contains("Lease renewal")
        )

        // The partially visible thread shows only its visible members, and
        // its count is the filtered count.
        let thread = try client.requestResult("tools/call", params: [
            "name": "get_thread", "arguments": ["id": 1],
        ])
        let threadContent = try policyDict(thread["structuredContent"])
        XCTAssertEqual(try policyInt(threadContent["count"]), 2)

        // resources/list: the hidden messages and their threads do not
        // exist as far as this client is concerned.
        let resources = try client.requestResult("resources/list", params: [String: Any]())
        let uris = Set(try policyArray(resources["resources"]).compactMap { $0["uri"] as? String })
        XCTAssertEqual(
            uris,
            ["emailarchiver://message/1", "emailarchiver://message/2", "emailarchiver://thread/1"]
        )

        // resources/read of a hidden message fails the request.
        let readHidden = try client.request("resources/read", params: [
            "uri": "emailarchiver://message/3",
        ])
        XCTAssertNotNil(readHidden["error"], "hidden message resource must fail like a missing one")
        let readVisible = try client.requestResult("resources/read", params: [
            "uri": "emailarchiver://message/1",
        ])
        XCTAssertTrue(
            try policyStr((try policyArray(readVisible["contents"]).first?["text"]) ?? "")
                .contains("alpha lease letter")
        )

        // list_accounts: the excluded account does not appear at all.
        let accounts = try client.requestResult("tools/call", params: [
            "name": "list_accounts", "arguments": [String: Any](),
        ])
        let accountText = try policyStr((try policyArray(accounts["content"]).first?["text"]) ?? "")
        XCTAssertFalse(accountText.contains("bob@example.org"), "excluded account must not appear")
        XCTAssertTrue(accountText.contains("alice@example.com"))
    }

    // MARK: - 3. Unknown names stay silent and permissive

    func testUnknownNamesInPolicyStaySilent() throws {
        _ = try makeFilteredFixture()
        let executable = try helperExecutableURL()
        let json = """
        {
          "excludeJunkAndTrash": false,
          "excludedAccounts": ["no-such-account@example.com"],
          "excludedMailboxes": ["not-a-folder"],
          "excludedLabels": ["no-such-label"]
        }
        """
        let client = try StdioMCPClient(
            executable: executable, archivePath: archiveURL.path,
            extraEnvironment: ["BRISTLECONE_ACCESS_POLICY": try writePolicyFile(json)]
        )
        defer { client.shutdown() }
        process = client.process

        try client.requestResult("initialize", params: [
            "protocolVersion": "2025-06-18",
            "capabilities": [String: Any](),
            "clientInfo": ["name": "geist9-policy-test", "version": "0.0.0"],
        ])
        client.notify("notifications/initialized")

        // Junk is not excluded by this policy, so every message answers
        // exactly as it would with no policy at all.
        let search = try client.requestResult("tools/call", params: [
            "name": "search_messages",
            "arguments": ["query": "letter", "limit": 50],
        ])
        let searchContent = try policyDict(search["structuredContent"])
        XCTAssertEqual(try policyInt(searchContent["count"]), 5)
        let resources = try client.requestResult("resources/list", params: [String: Any]())
        // Six messages and five threads, all listed.
        XCTAssertEqual((resources["resources"] as? [[String: Any]])?.count, 11)
    }

    // MARK: - 4. Redaction on the way out

    func testHeadersOnlyRedactionStripsBodiesOverTheWire() throws {
        _ = try makeFilteredFixture()
        let executable = try helperExecutableURL()
        let json = """
        {"redaction": "headersOnly"}
        """
        let client = try StdioMCPClient(
            executable: executable, archivePath: archiveURL.path,
            extraEnvironment: ["BRISTLECONE_ACCESS_POLICY": try writePolicyFile(json)]
        )
        defer { client.shutdown() }
        process = client.process

        try client.requestResult("initialize", params: [
            "protocolVersion": "2025-06-18",
            "capabilities": [String: Any](),
            "clientInfo": ["name": "geist9-policy-test", "version": "0.0.0"],
        ])
        client.notify("notifications/initialized")

        let search = try client.requestResult("tools/call", params: [
            "name": "search_messages",
            "arguments": ["query": "alpha", "limit": 10],
        ])
        let searchContent = try policyDict(search["structuredContent"])
        XCTAssertEqual(searchContent["body_omitted"] as? Bool, true, "headersOnly must say so")
        let hit = try policyArray(searchContent["messages"]).first
        XCTAssertNil(hit?["snippet"], "no snippet text under headersOnly")

        let message = try client.requestResult("tools/call", params: [
            "name": "get_message", "arguments": ["id": 1],
        ])
        let messageContent = try policyDict(message["structuredContent"])
        let inner = try policyDict(messageContent["message"])
        XCTAssertEqual(inner["body_omitted"] as? Bool, true)
        XCTAssertNil(inner["body"], "no body under headersOnly")
        let rendered = try policyStr((try policyArray(message["content"]).first?["text"]) ?? "")
        XCTAssertFalse(rendered.contains("alpha lease letter"), "no body in the text rendering either")
    }

    // MARK: - 5. The rate limit refuses, and says why

    func testRateLimitRefusesAfterTheBudget() throws {
        _ = try makeFilteredFixture()
        let executable = try helperExecutableURL()
        let client = try StdioMCPClient(
            executable: executable, archivePath: archiveURL.path,
            extraEnvironment: ["BRISTLECONE_ACCESS_POLICY": try writePolicyFile(
                """
                {"excludeJunkAndTrash": false, "callsPerMinute": 1}
                """
            )]
        )
        defer { client.shutdown() }
        process = client.process

        try client.requestResult("initialize", params: [
            "protocolVersion": "2025-06-18",
            "capabilities": [String: Any](),
            "clientInfo": ["name": "geist9-policy-test", "version": "0.0.0"],
        ])
        client.notify("notifications/initialized")

        let first = try client.requestResult("tools/call", params: [
            "name": "search_messages", "arguments": ["query": "alpha", "limit": 5],
        ])
        XCTAssertNil(first["isError"], "the first call inside the budget answers normally")
        let second = try client.request("tools/call", params: [
            "name": "search_messages", "arguments": ["query": "alpha", "limit": 5],
        ])
        XCTAssertNotNil(second["error"], "the second call past the budget must refuse")
        let text = try policyStr(try policyDict(second["error"])["message"])
        XCTAssertTrue(text.contains("rate limit"), "the refusal says why: \(text)")
    }

    // MARK: - 6. Agents off entirely

    /// The app's master switch: `enabled: false` refuses every tool call
    /// and every resource read with its own error (not "rate limit", not
    /// "not found"), and the refusal still reads as a sentence. Schema
    /// advertisement (`tools/list`) stays static so the client's setup
    /// steps don't break while agents are off.
    func testDisabledPolicyRefusesToolsAndResources() throws {
        _ = try makeFilteredFixture()
        let executable = try helperExecutableURL()
        let client = try StdioMCPClient(
            executable: executable, archivePath: archiveURL.path,
            extraEnvironment: ["BRISTLECONE_ACCESS_POLICY": try writePolicyFile(
                """
                {"excludeJunkAndTrash": false, "enabled": false}
                """
            )]
        )
        defer { client.shutdown() }
        process = client.process

        try client.requestResult("initialize", params: [
            "protocolVersion": "2025-06-18",
            "capabilities": [String: Any](),
            "clientInfo": ["name": "geist9-policy-test", "version": "0.0.0"],
        ])
        client.notify("notifications/initialized")

        let listing = try client.requestResult("tools/list", params: [String: Any]())
        XCTAssertFalse(try policyArray(listing["tools"]).isEmpty)

        let call = try client.request("tools/call", params: [
            "name": "archive_stats", "arguments": [String: Any](),
        ])
        let callError = try policyDict(call["error"])
        XCTAssertEqual(try policyInt(callError["code"]), -32003)
        XCTAssertTrue(
            try policyStr(callError["message"]).contains("turned off"),
            "the refusal names the switch: \(callError["message"] ?? "")"
        )

        let read = try client.request("resources/read", params: [
            "uri": "emailarchiver://message/1",
        ])
        let readError = try policyDict(read["error"])
        XCTAssertEqual(try policyInt(readError["code"]), -32003)
    }
}

private struct PolicyE2EError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - JSON navigation helpers (local to this file)

private func policyDict(_ any: Any?) throws -> [String: Any] {
    guard let value = any as? [String: Any] else {
        throw PolicyE2EError("expected a JSON object, got: \(String(describing: any))")
    }
    return value
}

private func policyArray(_ any: Any?) throws -> [[String: Any]] {
    guard let value = any as? [[String: Any]] else {
        throw PolicyE2EError("expected a JSON array of objects, got: \(String(describing: any))")
    }
    return value
}

private func policyStr(_ any: Any?) throws -> String {
    guard let value = any as? String else {
        throw PolicyE2EError("expected a string, got: \(String(describing: any))")
    }
    return value
}

private func policyInt(_ any: Any?) throws -> Int {
    guard let value = any as? Int else {
        throw PolicyE2EError("expected an integer, got: \(String(describing: any))")
    }
    return value
}
