// JMAP engine unit tests (decision 0066). These replay the exact behaviors
// observed against local Stalwart 1.2.0 (docs/spikes/jmap-stalwart.md) on
// the JMAPHTTPClient seam — no network, no live server:
//   - Email/query `sort` would be refused: the engine pages by position
//     only and never sends `sort`.
//   - A session document without a mail account is an error, not an empty
//     mailbox (Stalwart answers unknown accountIds with an EMPTY list —
//     the engine must not let that look like a successful empty sync).
//   - Blob downloads return the original bytes byte-for-byte.
//   - `Email/changes` drives the incremental pass; destroyed ids mark
//     memberships removed, nothing is deleted from the archive.

import ArchiveCore
import XCTest
@testable import MailSync

/// A JMAP server replayed from canned responses, recording every request so
/// the tests assert on the exact JSON the engine sends.
final class FakeJMAPServer: JMAPHTTPClient, @unchecked Sendable {
    /// (method, url path, body) tuples in arrival order.
    struct Recorded: Sendable {
        var method: String
        var path: String
        var body: String?
    }

    private let lock = NSLock()
    private var _recorded: [Recorded] = []
    var recorded: [Recorded] {
        lock.withLock { _recorded }
    }

    /// Response bodies keyed by URL path; a path not present answers 404.
    private var routes: [String: (status: Int, body: Data)] = [:]
    /// Canned responses keyed by the request's first method name. Consumed
    /// in registration order: each call takes the next unused response for
    /// that method; once exhausted, the last one repeats (so a walk that
    /// pages until a short page can register the terminal page last).
    private var jmapResponses: [(match: String, used: Bool, body: String)] = []

    func route(_ path: String, status: Int, _ body: String) {
        routes[path] = (status, Data(body.utf8))
    }

    func onJMAP(method firstMethod: String, respond body: String) {
        lock.withLock { jmapResponses.append((firstMethod, false, body)) }
    }

    func send(
        _ method: String, _ url: URL, body: Data?, tokenAuth: Bool,
        basicAuth username: String, password: String
    ) async throws -> (status: Int, body: Data) {
        let recordedBody = body.flatMap { String(data: $0, encoding: .utf8) }
        lock.withLock {
            _recorded.append(Recorded(
                method: method,
                path: url.path,
                body: recordedBody
            ))
        }

        if method == "POST" {
            if let body,
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let calls = json["methodCalls"] as? [[Any]],
               let first = calls.first, let name = first.first as? String {
                let response = lock.withLock { () -> String? in
                    // First unused response for this method; the last one repeats.
                    guard let range = jmapResponses.firstIndex(where: { $0.match == name && !$0.used }) else {
                        return jmapResponses.last(where: { $0.match == name })?.body
                    }
                    jmapResponses[range].used = true
                    return jmapResponses[range].body
                }
                if let response {
                    return (200, Data(response.utf8))
                }
            }
            return (200, Data(#"{"methodResponses":[]}"#.utf8))
        }
        if let route = routes[url.path] {
            return (route.status, route.body)
        }
        return (404, Data())
    }
}

/// Builds RFC 8620 envelopes and the state objects inside them.
enum JMAPFixtures {
    /// Wraps a state object in the response envelope the engine unwraps:
    /// `{"methodResponses":[[name, state, "c0"]]}`.
    static func envelope(name: String, _ state: String) -> String {
        let object: [String: Any] = [
            "methodResponses": [[name, try! JSONSerialization.jsonObject(with: Data(state.utf8)), "c0"]],
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [])
        return String(data: data, encoding: .utf8)!
    }
    static func session(accounts: [String: String] = ["u1": "acc1"], apiUrl: String = "http://localhost/jmap/") -> String {
        var primary: [String: Any] = [:]
        for value in accounts.values {
            primary["urn:ietf:params:jmap:mail"] = value
        }
        let object: [String: Any] = [
            "capabilities": [:],
            "accounts": accounts,
            "primaryAccounts": primary,
            "username": "alice@example.com",
            "apiUrl": apiUrl,
            "downloadUrl": "http://localhost/jmap/download/{accountId}/{blobId}/{name}?accept={type}",
            "uploadUrl": "http://localhost/jmap/upload/{accountId}/",
            "eventSourceUrl": "http://localhost/jmap/eventsource/?types={types}&closeafter={closeafter}&ping={ping}",
            "state": "s0",
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [])
        return String(data: data, encoding: .utf8)!
    }

    static func sessionWithoutMailAccount() -> String {
        let object: [String: Any] = [
            "capabilities": [:],
            "accounts": ["u1": [:]],
            "primaryAccounts": [:],
            "username": "alice@example.com",
            "apiUrl": "http://localhost/jmap/",
            "downloadUrl": "http://localhost/jmap/download/{accountId}/{blobId}/{name}?accept={type}",
            "uploadUrl": "http://localhost/jmap/upload/{accountId}/",
            "state": "s0",
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [])
        return String(data: data, encoding: .utf8)!
    }

    static func mailboxesJSON(_ entries: [[String: Any]], state: String = "mb1") -> String {
        let object: [String: Any] = [
            "list": entries, "notFound": [], "state": state,
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [])
        return String(data: data, encoding: .utf8)!
    }

    static func mailbox(id: String, name: String, role: String? = nil) -> [String: Any] {
        var entry: [String: Any] = ["id": id, "name": name]
        if let role { entry["role"] = role }
        return entry
    }

    static func emailGetJSON(_ entries: [[String: Any]], state: String = "em1") -> String {
        let object: [String: Any] = [
            "list": entries, "notFound": [], "state": state,
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [])
        return String(data: data, encoding: .utf8)!
    }

    static func emailEntry(id: String, blobID: String) -> [String: Any] {
        ["id": id, "blobId": blobID, "receivedAt": "2026-01-01T00:00:00Z"]
    }

    static func queryJSON(ids: [String], queryState: String, position: Int, total: Int) -> String {
        let object: [String: Any] = [
            "accountId": "acc1", "queryState": queryState,
            "ids": ids, "position": position, "total": total, "limit": ids.count,
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [])
        return String(data: data, encoding: .utf8)!
    }

    static func changesJSON(created: [String], destroyed: [String], newState: String, oldState: String) -> String {
        let object: [String: Any] = [
            "accountId": "acc1", "oldState": oldState, "newState": newState,
            "hasMoreChanges": false, "created": created, "updated": [], "destroyed": destroyed,
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [])
        return String(data: data, encoding: .utf8)!
    }

    static func errorJSON(type: String, description: String) -> String {
        let object: [String: Any] = [
            "type": type, "description": description,
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [])
        return String(data: data, encoding: .utf8)!
    }

    /// A minimal RFC 5322 message as the blob download would return it.
    static func message(_ subject: String) -> Data {
        Data("""
        From: Alice Example <alice@example.com>
        To: Bob Example <bob@example.org>
        Subject: \(subject)
        Message-ID: <\(subject.replacingOccurrences(of: " ", with: "-"))@example.com>
        Date: Mon, 05 Jan 2026 10:00:00 +0000
        Content-Type: text/plain; charset=utf-8

        Body of \(subject).
        """.utf8)
    }
}

final class JMAPSyncEngineTests: XCTestCase {
    private func makeStore(_ name: String) throws -> ArchiveStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jmap-tests-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try ArchiveStore.create(at: dir.appendingPathComponent("Test.emailarchive"), appVersion: "0.1.0")
    }

    private var account: AccountIdentity {
        AccountIdentity(email: "alice@example.com", displayName: "Alice", providerKind: "jmap")
    }

    private let sessionResponse = JMAPFixtures.session()

    private var mailboxResponse: String {
        JMAPFixtures.mailboxesJSON([
            JMAPFixtures.mailbox(id: "mbA", name: "Inbox", role: "inbox"),
            JMAPFixtures.mailbox(id: "mbB", name: "Archive", role: nil),
        ])
    }

    func testSessionWithoutMailAccountIsAnErrorNotAnEmptySync() async throws {
        let server = FakeJMAPServer()
        server.route("/jmap/session", status: 200, JMAPFixtures.sessionWithoutMailAccount())
        let store = try makeStore("nosession")
        let engine = JMAPSyncEngine(account: account)

        do {
            _ = try await engine.sync(
                store: store, base: URL(string: "http://localhost")!,
                auth: .basic(username: "u", password: "p"), client: server
            )
            XCTFail("expected accountNotFound")
        } catch let error as JMAPSyncError {
            guard case .accountNotFound = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testFullPassPagesByPositionWithoutSortAndStoresOriginalBytes() async throws {
        let server = FakeJMAPServer()
        server.route("/jmap/session", status: 200, sessionResponse)
        server.onJMAP(method: "Mailbox/get", respond: JMAPFixtures.envelope(name: "Mailbox/get", mailboxResponse))
        // Two pages: the first full (limit 2), the second short → walk ends.
        let page1 = JMAPFixtures.queryJSON(
            ids: ["m1", "m2"], queryState: "q1", position: 0, total: 3
        )
        let page2 = JMAPFixtures.queryJSON(
            ids: ["m3"], queryState: "q1", position: 2, total: 3
        )
        // The fake answers queries in registration order: page1, page2,
        // then the terminal empty page (which repeats for mailbox B).
        server.onJMAP(method: "Email/query", respond: JMAPFixtures.envelope(name: "Email/query", page1))
        server.onJMAP(method: "Email/query", respond: JMAPFixtures.envelope(name: "Email/query", page2))
        server.onJMAP(method: "Email/query", respond: JMAPFixtures.envelope(name: "Email/query", JMAPFixtures.queryJSON(
            ids: [], queryState: "q2", position: 3, total: 3
        )))
        let blobs = JMAPFixtures.emailGetJSON([
            JMAPFixtures.emailEntry(id: "m1", blobID: "b1"),
            JMAPFixtures.emailEntry(id: "m2", blobID: "b2"),
        ])
        let blobs2 = JMAPFixtures.emailGetJSON([
            JMAPFixtures.emailEntry(id: "m3", blobID: "b3"),
        ])
        // One get per page, consumed in order: page 1's ids (m1,m2) then
        // page 2's (m3). The fake serves them sequentially.
        server.onJMAP(method: "Email/get", respond: JMAPFixtures.envelope(name: "Email/get", blobs))
        server.onJMAP(method: "Email/get", respond: JMAPFixtures.envelope(name: "Email/get", blobs2))
        server.route("/jmap/download/acc1/b1/message.eml", status: 200, String(decoding: JMAPFixtures.message("Alpha"), as: UTF8.self))
        server.route("/jmap/download/acc1/b2/message.eml", status: 200, String(decoding: JMAPFixtures.message("Beta"), as: UTF8.self))
        server.route("/jmap/download/acc1/b3/message.eml", status: 200, String(decoding: JMAPFixtures.message("Gamma"), as: UTF8.self))

        let store = try makeStore("full")
        let engine = JMAPSyncEngine(account: account, pageLimit: 2)
        let progress = try await engine.sync(
            store: store, base: URL(string: "http://localhost")!,
            auth: .bearer(token: "t"), client: server
        )

        XCTAssertEqual(progress.mailboxesListed, 2)
        XCTAssertEqual(progress.messagesStored, 3)
        XCTAssertEqual(progress.messagesDuplicate, 0)

        // Every Email/query the engine sent carries position/limit and NO
        // sort key (the Stalwart unsupportedSort quirk).
        for call in server.recorded where call.path == "/jmap" {
            guard let body = call.body,
                  let json = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
                  let calls = json["methodCalls"] as? [[Any]],
                  let first = calls.first, let args = first[1] as? [String: Any],
                  (first.first as? String) == "Email/query"
            else { continue }
            XCTAssertNil(args["sort"], "engine must not send sort: \(args)")
            XCTAssertNotNil(args["position"])
            XCTAssertNotNil(args["limit"])
        }

        // The bytes are the originals, and search sees the subjects.
        let original = JMAPFixtures.message("Alpha")
        let hits = try store.search("Alpha", limit: 10, offset: 0, withSnippets: false, groupByThread: false, now: Date())
        XCTAssertEqual(hits.hits.count, 1)
        let hash: Data? = try await store.db.read { db in
            try Data.fetchOne(db, sql: "SELECT hash FROM message WHERE subject = ?", arguments: ["Alpha"])
        }
        let data = try store.messageData(MessageHash(bytes: XCTUnwrap(hash)))
        XCTAssertEqual(data, original)
    }

    func testRelativeApiUrlResolvesAgainstBase() async throws {
        // Real servers (e.g. Stalwart) may report a relative apiUrl
        // ("/jmap/"). URL(string:) alone yields a URL with no host, and
        // the engine must ride it on the session's base instead of
        // force-unwrapping into a crash.
        let server = FakeJMAPServer()
        server.route("/jmap/session", status: 200, JMAPFixtures.session(apiUrl: "/jmap/"))
        server.onJMAP(method: "Mailbox/get", respond: JMAPFixtures.envelope(name: "Mailbox/get", mailboxResponse))
        server.onJMAP(method: "Email/query", respond: JMAPFixtures.envelope(name: "Email/query", JMAPFixtures.queryJSON(
            ids: [], queryState: "q1", position: 0, total: 0
        )))
        server.onJMAP(method: "Email/query", respond: JMAPFixtures.envelope(name: "Email/query", JMAPFixtures.queryJSON(
            ids: [], queryState: "q2", position: 0, total: 0
        )))

        let store = try makeStore("relative")
        let engine = JMAPSyncEngine(account: account)
        let progress = try await engine.sync(
            store: store, base: URL(string: "http://localhost")!,
            auth: .bearer(token: "t"), client: server
        )
        XCTAssertEqual(progress.mailboxesListed, 2)
        XCTAssertEqual(progress.messagesStored, 0)
        // The API POSTs landed on the base-relative path, not nowhere.
        XCTAssertTrue(server.recorded.contains { $0.path == "/jmap" }, "POSTs must ride the base: \(server.recorded.map(\.path))")
    }

    func testIncrementalPassUsesChangesAndMarksDestroyed() async throws {
        let server = FakeJMAPServer()
        server.route("/jmap/session", status: 200, sessionResponse)
        server.onJMAP(method: "Mailbox/get", respond: JMAPFixtures.envelope(name: "Mailbox/get", mailboxResponse))
        // First pass: full walk, one message.
        server.onJMAP(method: "Email/query", respond: JMAPFixtures.envelope(name: "Email/query", JMAPFixtures.queryJSON(
            ids: ["m1"], queryState: "q1", position: 0, total: 1
        )))
        server.onJMAP(method: "Email/get", respond: JMAPFixtures.envelope(name: "Email/get", JMAPFixtures.emailGetJSON([
            JMAPFixtures.emailEntry(id: "m1", blobID: "b1"),
        ])))
        server.route("/jmap/download/acc1/b1/message.eml", status: 200, String(decoding: JMAPFixtures.message("Alpha"), as: UTF8.self))

        let store = try makeStore("incr")
        let engine = JMAPSyncEngine(account: account, pageLimit: 10)
        _ = try await engine.sync(
            store: store, base: URL(string: "http://localhost")!,
            auth: .bearer(token: "t"), client: server
        )

        // Second pass: the delta names m1 destroyed and m2 created.
        server.onJMAP(method: "Email/changes", respond: JMAPFixtures.envelope(name: "Email/changes", JMAPFixtures.changesJSON(
            created: ["m2"], destroyed: ["m1"], newState: "q3", oldState: "mb1"
        )))
        server.onJMAP(method: "Email/get", respond: JMAPFixtures.envelope(name: "Email/get", JMAPFixtures.emailGetJSON([
            JMAPFixtures.emailEntry(id: "m2", blobID: "b2"),
        ])))
        server.route("/jmap/download/acc1/b2/message.eml", status: 200, String(decoding: JMAPFixtures.message("Second"), as: UTF8.self))

        _ = try await engine.sync(
            store: store, base: URL(string: "http://localhost")!,
            auth: .bearer(token: "t"), client: server
        )

        // m1's membership is marked removed, m2 exists, NOTHING was deleted.
        let hits1 = try store.search("Alpha", limit: 10, offset: 0, withSnippets: false, groupByThread: false, now: Date())
        let hits2 = try store.search("Second", limit: 10, offset: 0, withSnippets: false, groupByThread: false, now: Date())
        XCTAssertEqual(hits1.hits.count, 1, "destroyed messages stay in the archive")
        XCTAssertEqual(hits2.hits.count, 1)
        let hash1: Data? = try await store.db.read { db in
            try Data.fetchOne(db, sql: "SELECT hash FROM message WHERE subject = ?", arguments: ["Alpha"])
        }
        let data1 = try store.messageData(MessageHash(bytes: XCTUnwrap(hash1)))
        XCTAssertEqual(data1, JMAPFixtures.message("Alpha"))
        let hash2: Data? = try await store.db.read { db in
            try Data.fetchOne(db, sql: "SELECT hash FROM message WHERE subject = ?", arguments: ["Second"])
        }
        let data2 = try store.messageData(MessageHash(bytes: XCTUnwrap(hash2)))
        XCTAssertEqual(data2, JMAPFixtures.message("Second"))
    }

    func testBlobDownloadFailureSurfacesAsTransportFailed() async throws {
        let server = FakeJMAPServer()
        server.route("/jmap/session", status: 200, sessionResponse)
        server.onJMAP(method: "Mailbox/get", respond: JMAPFixtures.envelope(name: "Mailbox/get", mailboxResponse))
        server.onJMAP(method: "Email/query", respond: JMAPFixtures.envelope(name: "Email/query", JMAPFixtures.queryJSON(
            ids: ["m1"], queryState: "q1", position: 0, total: 1
        )))
        server.onJMAP(method: "Email/get", respond: JMAPFixtures.envelope(name: "Email/get", JMAPFixtures.emailGetJSON([
            JMAPFixtures.emailEntry(id: "m1", blobID: "bMissing"),
        ])))
        // The download route is absent → 404.
        let store = try makeStore("dl404")
        let engine = JMAPSyncEngine(account: account, pageLimit: 10)

        do {
            _ = try await engine.sync(
                store: store, base: URL(string: "http://localhost")!,
                auth: .bearer(token: "t"), client: server
            )
            XCTFail("expected transportFailed")
        } catch let error as JMAPSyncError {
            guard case .transportFailed(404, _) = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testMethodErrorSurfacesWithType() async throws {
        let server = FakeJMAPServer()
        server.route("/jmap/session", status: 200, sessionResponse)
        server.onJMAP(method: "Mailbox/get", respond: JMAPFixtures.envelope(name: "Mailbox/get", JMAPFixtures.errorJSON(
            type: "unknownMethod", description: "no such method"
        )))
        let store = try makeStore("err")
        let engine = JMAPSyncEngine(account: account)

        do {
            _ = try await engine.sync(
                store: store, base: URL(string: "http://localhost")!,
                auth: .basic(username: "u", password: "p"), client: server
            )
            XCTFail("expected methodFailed")
        } catch let error as JMAPSyncError {
            guard case .methodFailed(let text) = error, text.contains("unknownMethod") else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testUnknownRoleIsDroppedAndKnownRolesMap() async throws {
        let server = FakeJMAPServer()
        server.route("/jmap/session", status: 200, sessionResponse)
        server.onJMAP(method: "Mailbox/get", respond: JMAPFixtures.envelope(name: "Mailbox/get", JMAPFixtures.mailboxesJSON([
            JMAPFixtures.mailbox(id: "mbA", name: "Inbox", role: "inbox"),
            JMAPFixtures.mailbox(id: "mbC", name: "Odd", role: "flagged"), // unknown
        ])))
        server.onJMAP(method: "Email/query", respond: JMAPFixtures.envelope(name: "Email/query", JMAPFixtures.queryJSON(
            ids: [], queryState: "q0", position: 0, total: 0
        )))
        let store = try makeStore("roles")
        let engine = JMAPSyncEngine(account: account)
        _ = try await engine.sync(
            store: store, base: URL(string: "http://localhost")!,
            auth: .bearer(token: "t"), client: server
        )
        // The inbox role survives; the unknown one did not create a bogus
        // role row (both mailboxes exist, but only via ensureMailbox).
        let account2 = self.account
        _ = try store.ensureMailbox(account: account2, name: "Inbox", role: "inbox")
        _ = try store.ensureMailbox(account: account2, name: "Odd", role: nil)
    }
}

final class JMAPDeletionTests: XCTestCase {
    func testHashedJMAPIDsAreNegativeAndStable() {
        let a = ArchiveStore.jmapMembershipUID("eaaaaab")
        let b = ArchiveStore.jmapMembershipUID("eaaaaab")
        let c = ArchiveStore.jmapMembershipUID("iaaaaac")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertLessThan(a, 0, "JMAP membership uids are negative (never a real IMAP UID)")
        XCTAssertLessThan(c, 0)
    }

    func testDestroyedMarkingKeepsTheArchiveIntact() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jmap-deletion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try ArchiveStore.create(at: dir.appendingPathComponent("Test.emailarchive"), appVersion: "0.1.0")
        let account = AccountIdentity(email: "alice@example.com", displayName: "Alice", providerKind: "jmap")

        let message = JMAPFixtures.message("Keep me")
        let record = MailBridge.record(for: message)
        let membership = Membership(mailbox: "Inbox", uid: ArchiveStore.jmapMembershipUID("m1"), flags: [], dateReceived: Date(), role: "inbox")
        let parsed = MailBridge.parse(for: message, ocr: .deferred)
        let ingested = IngestedMessage(
            record: record, data: message, memberships: [membership],
            labels: [], searchText: parsed.searchText
        )
        _ = try store.ingest(ingested, into: account)

        // Mark m1 destroyed: the membership flips, the bytes stay.
        let report = try store.markJMAPMembershipsDestroyed(
            account: account, mailbox: "Inbox", jmapIDs: ["m1"]
        )
        XCTAssertEqual(report.membershipsMarked, 1)

        let hits = try store.search("Keep me", limit: 10, offset: 0, withSnippets: false, groupByThread: false, now: Date())
        XCTAssertEqual(hits.hits.count, 1, "the message is still in the archive")
        let hash: Data? = try await store.db.read { db in
            try Data.fetchOne(db, sql: "SELECT hash FROM message WHERE subject = ?", arguments: ["Keep me"])
        }
        let data = try store.messageData(MessageHash(bytes: XCTUnwrap(hash)))
        XCTAssertEqual(data, message)
    }
}
