import ArchiveCore
import ArchiveMCP
import XCTest

/// The DESIGN 9A end-to-end contract: the real `email-archiver-mcp`
/// executable, launched as a subprocess with real stdio pipes, speaks real
/// newline-delimited JSON-RPC with this test acting as an MCP client. This
/// is the whole path a client sees: initialize handshake, tools/list,
/// tools/call over a live search, resources/list, resources/read, and the
/// failure forms (unknown tool, unknown URI). Nothing here is mocked at the
/// protocol layer — the only fixture is a tiny temporary archive.
final class StdioEndToEndTests: XCTestCase {
    private var tempDir: URL!
    private var process: Process!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("geist9-mcp-e2e-\(UUID().uuidString)")
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

    private var archiveURL: URL { tempDir.appendingPathComponent("E2E.emailarchive") }

    /// Two messages forming a thread plus one unrelated message.
    private func makeArchive() throws -> ArchiveStore {
        let store = try ArchiveStore.create(at: archiveURL, appVersion: "0.1.0")
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
        return store
    }

    // MARK: - Executable discovery

    private func helperExecutableURL() throws -> URL {
        // An explicit override wins (CI or another harness may relocate the build).
        if let override = ProcessInfo.processInfo.environment["MCP_HELPER_BIN"],
           FileManager.default.fileExists(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        // The built product lives in .build/<arch>/debug with a `debug`
        // symlink next to it; try both spellings.
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/ArchiveMCPTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // package root
        let candidates = [
            packageRoot.appendingPathComponent(".build/debug/email-archiver-mcp"),
            packageRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/email-archiver-mcp"),
            packageRoot.appendingPathComponent(".build/x86_64-apple-macosx/debug/email-archiver-mcp"),
            packageRoot.appendingPathComponent(".build/x86_64-unknown-linux-gnu/debug/email-archiver-mcp"),
            packageRoot.appendingPathComponent(".build/aarch64-unknown-linux-gnu/debug/email-archiver-mcp"),
        ]
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        throw E2EError("email-archiver-mcp not built; run swift build --build-tests first")
    }

    // MARK: - The contract

    /// DESIGN 9A C4: helper launched over stdio, checked end to end.
    func testStdioServerSpeaksMCPOverRealPipes() throws {
        _ = try makeArchive()

        let executable = try helperExecutableURL()
        let client = try StdioMCPClient(executable: executable, archivePath: archiveURL.path)
        defer { client.shutdown() }
        process = client.process
        let exited = expectation(description: "helper exits after stdin EOF")
        process.terminationHandler = { _ in exited.fulfill() }

        // 1. Initialize handshake.
        let initResult = try client.requestResult("initialize", params: [
            "protocolVersion": "2025-03-26",
            "capabilities": [String: Any](),
            "clientInfo": ["name": "geist9-e2e-test", "version": "0.0.0"],
        ])
        let serverInfo = try dict(initResult["serverInfo"], as: "serverInfo")
        XCTAssertEqual(try str(serverInfo["name"], as: "serverInfo.name"), "Bristlecone Email Archiver")
        XCTAssertNotNil(try str(serverInfo["version"], as: "serverInfo.version"))
        client.notify("notifications/initialized")

        // 2. tools/list: exactly the ten DESIGN 9A tools.
        let tools = try client.requestResult("tools/list", params: [String: Any]())
        let toolNames = Set(try strArray(try arr(tools["tools"], as: "tools").map { $0["name"] }))
        XCTAssertEqual(
            toolNames,
            [
                "search_messages", "get_message", "get_thread", "list_accounts",
                "list_folders", "list_labels", "list_attachments",
                "get_attachment_text", "find_contacts", "archive_stats",
            ]
        )

        // 3. Resource templates: the two message/thread shapes.
        let templates = try client.requestResult("resources/templates/list", params: [String: Any]())
        let templateURIs = Set(try strArray(try arr(templates["resourceTemplates"], as: "resourceTemplates").map { $0["uriTemplate"] }))
        XCTAssertEqual(
            templateURIs,
            ["emailarchiver://message/{id}", "emailarchiver://thread/{id}"]
        )

        // 4. resources/list: every stored message and thread is listed.
        let resources = try client.requestResult("resources/list", params: [String: Any]())
        let resourceURIs = Set(try strArray(try arr(resources["resources"], as: "resources").map { $0["uri"] }))
        XCTAssertEqual(resourceURIs, [
            "emailarchiver://message/1",
            "emailarchiver://message/2",
            "emailarchiver://message/3",
            "emailarchiver://thread/1",
            "emailarchiver://thread/2",
        ])
        XCTAssertNil(resources["nextCursor"])

        // 5. search_messages end to end through the index.
        let search = try client.requestResult("tools/call", params: [
            "name": "search_messages",
            "arguments": ["query": "alpha", "limit": 10],
        ])
        XCTAssertNotEqual(search["isError"] as? Bool, true)
        let searchContent = try dict(search["structuredContent"], as: "structuredContent")
        let hits = try arr(searchContent["messages"], as: "messages")
        XCTAssertEqual(try int(searchContent["count"], as: "count"), 1)
        let hit = try dict(hits.first, as: "messages[0]")
        let messageID = try int(hit["id"], as: "messages[0].id")
        XCTAssertEqual(try int(hit["thread_id"], as: "messages[0].thread_id"), 1)
        // Subject and snippet always arrive inside the untrusted fence.
        let hitSubject = try str(hit["subject"], as: "messages[0].subject")
        XCTAssertTrue(hitSubject.contains("BEGIN UNTRUSTED CONTENT (subject)"))
        XCTAssertTrue(hitSubject.contains("Lease renewal"))
        let hitSnippet = try str(hit["snippet"], as: "messages[0].snippet")
        XCTAssertTrue(hitSnippet.contains("BEGIN UNTRUSTED CONTENT (snippet)"))
        // FTS5 snippet() highlights the matched term with [[...]].
        XCTAssertTrue(hitSnippet.contains("[[alpha]]"), "snippet highlights the hit term, got: \(hitSnippet)")
        XCTAssertTrue(hitSnippet.contains("lease letter"))

        // 6. get_message by the id the search returned.
        let message = try client.requestResult("tools/call", params: [
            "name": "get_message",
            "arguments": ["id": messageID],
        ])
        let messageContent = try dict(message["structuredContent"], as: "structuredContent")
        XCTAssertTrue(try str(messageContent["subject"], as: "subject").contains("Lease renewal"))
        XCTAssertEqual(try str(messageContent["from"], as: "from"), "Alice <alice@example.com>")
        let messageDetail = try dict(messageContent["message"], as: "message")
        let messageBody = try str(messageDetail["body"], as: "message.body")
        XCTAssertTrue(messageBody.contains("BEGIN UNTRUSTED CONTENT (message body)"))
        XCTAssertTrue(messageBody.contains("alpha lease letter"))
        XCTAssertEqual(try int(messageContent["thread_id"], as: "thread_id"), 1)

        // 7. get_thread: the two thread members, oldest first.
        let thread = try client.requestResult("tools/call", params: [
            "name": "get_thread",
            "arguments": ["id": 1],
        ])
        let threadContent = try dict(thread["structuredContent"], as: "structuredContent")
        let threadMessages = try arr(threadContent["messages"], as: "messages")
        XCTAssertEqual(try int(threadContent["count"], as: "count"), 2)
        XCTAssertEqual(threadMessages.count, 2)
        let threadSubjects = try strArray(threadMessages.map { $0["subject"] })
        XCTAssertTrue(threadSubjects[0].contains("Lease renewal"))
        XCTAssertTrue(threadSubjects[0].contains("BEGIN UNTRUSTED CONTENT (subject)"))
        XCTAssertTrue(threadSubjects[1].contains("Re: Lease renewal"))
        // Bodies flow into thread members under the same fence.
        let threadBody = try str(try dict(threadMessages[0], as: "messages[0]")["body"], as: "messages[0].body")
        XCTAssertTrue(threadBody.contains("alpha lease letter"))

        // 8. resources/read of the message document.
        let readMessage = try client.requestResult("resources/read", params: [
            "uri": "emailarchiver://message/\(messageID)",
        ])
        let messageContents = try arr(readMessage["contents"], as: "contents")
        let messageDoc = try dict(messageContents.first?["text"] as? String)
        XCTAssertTrue(try str(messageDoc["body"], as: "body").contains("alpha lease letter"))
        XCTAssertEqual(try int(messageDoc["thread_id"], as: "thread_id"), 1)
        let messageHeaders = try dict(messageDoc["headers"], as: "headers")
        XCTAssertEqual(try str(messageHeaders["Subject"], as: "headers.Subject"), "Lease renewal")

        // 9. resources/read of the thread document.
        let readThread = try client.requestResult("resources/read", params: [
            "uri": "emailarchiver://thread/1",
        ])
        let threadContents = try arr(readThread["contents"], as: "contents")
        let threadDoc = try dict(threadContents.first?["text"] as? String)
        XCTAssertEqual(try int(threadDoc["message_count"], as: "message_count"), 2)
        XCTAssertTrue(try str(threadDoc["subject"], as: "subject").contains("Lease renewal"))

        // 10. Failure forms: unknown id fails the request; unknown tool fails.
        let unknownMessage = try client.request("resources/read", params: [
            "uri": "emailarchiver://message/999",
        ])
        XCTAssertNotNil(unknownMessage["error"], "unknown id must fail the request")
        let unknownTool = try client.request("tools/call", params: [
            "name": "not_a_tool",
            "arguments": [String: Any](),
        ])
        XCTAssertNotNil(unknownTool["error"], "unknown tool must fail the request")

        // 11. Clean shutdown: closing stdin ends the helper with status 0.
        client.shutdown()
        wait(for: [exited], timeout: 30)
        XCTAssertEqual(process?.terminationStatus, 0)
    }
}

private struct E2EError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - Minimal stdio MCP client

/// Reads newline-delimited JSON-RPC from the helper's stdout with a
/// deadline, skipping messages it doesn't care about. All shared state is
/// guarded by the condition; the reader thread only appends.
private final class LineReader: @unchecked Sendable {
    private var buffer: [UInt8] = []
    private var eof = false
    private let condition = NSCondition()

    init(_ handle: FileHandle) {
        let thread = Thread { [self] in
            while true {
                let chunk = handle.availableData
                condition.lock()
                if chunk.isEmpty {
                    condition.unlock()
                    break
                }
                buffer.append(contentsOf: chunk)
                condition.broadcast()
                condition.unlock()
            }
            condition.lock()
            eof = true
            condition.broadcast()
            condition.unlock()
        }
        thread.name = "mcp-e2e-line-reader"
        thread.start()
    }

    func nextLine(timeout: TimeInterval) -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while true {
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = Data(buffer[0..<newline])
                buffer.removeFirst(newline + 1)
                if !line.isEmpty { return line }
                continue
            }
            if eof && buffer.isEmpty { return nil }
            if !condition.wait(until: deadline) { return nil }
        }
    }
}

/// A tiny MCP client that talks to the helper over real stdio pipes.
/// Only what the test needs: initialize/notify/request, JSON-RPC shaped.
final class StdioMCPClient {
    let process: Process
    private let input: FileHandle
    private let reader: LineReader
    private let responseTimeout: TimeInterval = 60
    private var nextID = 0
    private var closed = false

    init(executable: URL, archivePath: String) throws {
        process = Process()
        process.executableURL = executable
        // Minimal environment: the helper reads ARCHIVE_PATH and nothing
        // else; it must not inherit more than it needs.
        process.environment = [
            "ARCHIVE_PATH": archivePath,
            "PATH": "/usr/bin:/bin",
        ]
        let stdout = Pipe()
        let stdin = Pipe()
        process.standardOutput = stdout
        process.standardInput = stdin
        let stderr = Pipe() // diagnostics are allowed on stderr; don't assert them
        process.standardError = stderr
        try process.run()
        input = stdin.fileHandleForWriting
        reader = LineReader(stdout.fileHandleForReading)
    }

    /// Send a request and wait for the response with the matching id,
    /// skipping anything else (e.g. server-initiated messages). Returns the
    /// raw JSON-RPC envelope (has `result` or `error`).
    func request(_ method: String, params: [String: Any]) throws -> [String: Any] {
        let envelope = try requestEnvelope(method, params: params)
        return envelope
    }

    /// Same as `request`, but unwraps the `result` object, failing if the
    /// response is an error.
    func requestResult(_ method: String, params: [String: Any]) throws -> [String: Any] {
        let envelope = try requestEnvelope(method, params: params)
        guard envelope["error"] == nil else {
            throw E2EError("\(method) failed: \(envelope["error"] ?? "unknown error")")
        }
        return try dict(envelope["result"], as: "\(method) result")
    }

    private func requestEnvelope(_ method: String, params: [String: Any]) throws -> [String: Any] {
        nextID += 1
        let id = nextID
        send(json: [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ])
        let deadline = Date().addingTimeInterval(responseTimeout)
        while true {
            guard let line = reader.nextLine(timeout: max(0, deadline.timeIntervalSinceNow)) else {
                throw E2EError("timed out waiting for a response to \(method) (id \(id))")
            }
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                throw E2EError("stdout line was not JSON: \(String(decoding: line, as: UTF8.self))")
            }
            // Responses carry the id; notifications and server requests don't.
            guard message["id"] as? Int == id else { continue }
            return message
        }
    }

    func notify(_ method: String) {
        send(json: [
            "jsonrpc": "2.0",
            "method": method,
        ])
    }

    func shutdown() {
        guard !closed else { return }
        closed = true
        try? input.close()
    }

    private func send(json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        var line = data
        line.append(UInt8(ascii: "\n"))
        input.write(line)
    }
}

// MARK: - JSON navigation helpers

private func dict(_ any: Any?, as label: String) throws -> [String: Any] {
    guard let value = any as? [String: Any] else {
        throw E2EError("\(label) is not a JSON object")
    }
    return value
}

private func dict(_ string: String?) throws -> [String: Any] {
    guard let data = string?.data(using: .utf8),
          let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw E2EError("expected a JSON document, got: \(string?.prefix(80) ?? "nil")")
    }
    return value
}

private func arr(_ any: Any?, as label: String) throws -> [[String: Any]] {
    guard let value = any as? [[String: Any]] else {
        throw E2EError("\(label) is not a JSON array of objects")
    }
    return value
}

private func strArray(_ values: [Any?]) throws -> [String] {
    try values.map { value in
        guard let value else { throw E2EError("expected a string, got nil") }
        guard let string = value as? String else { throw E2EError("expected a string, got \(value)") }
        return string
    }
}

private func str(_ any: Any?, as label: String) throws -> String {
    guard let value = any as? String else { throw E2EError("\(label) is not a string") }
    return value
}

private func int(_ any: Any?, as label: String) throws -> Int {
    guard let value = any as? Int else { throw E2EError("\(label) is not an integer") }
    return value
}
