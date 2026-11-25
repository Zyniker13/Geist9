// The JMAP sync engine (DESIGN 5 "JMAP", ROADMAP M6, decision 0066).
//
// One pass: session → Mailbox/get → per mailbox Email/query paged by
// position → Email/get → blob download for the original bytes → ingest →
// per-mailbox state strings → Email/changes for the next pass. Storage and
// deletion tracking go through the same ArchiveStore calls the IMAP engine
// uses, so search sees JMAP mail exactly as IMAP mail.
//
// Server behavior encoded here comes from the local Stalwart 1.2.0 probe
// (docs/spikes/jmap-stalwart.md), replayed in tests — never from a live
// provider:
//  - Email/query `sort` is refused (`unsupportedSort`): paging is by
//    position/limit only, so the pass walks pages and carries no ordering
//    assumption beyond "position windows are stable within a state".
//  - `Email/import` accepts only server-side blob ids; the client is
//    read-only and never imports, but the same upload/download endpoints
//    serve the raw-bytes fetch (blob download returns the original bytes
//    byte-for-byte, sha256-verified in tests).
//  - An unknown accountId answers with an EMPTY list and a fresh queryState
//    instead of an error. The client therefore validates the accountId
//    against the session document before first use and treats an
//    absent one as a configuration error, not an empty mailbox.

import ArchiveCore
import Foundation

/// Errors the JMAP engine reports. Text never carries secrets (DESIGN 10).
public enum JMAPSyncError: Error, Equatable, Sendable {
    /// The session document lacks a mail account or names one the
    /// configuration did not ask for; the operator must fix the account
    /// setup (not an "empty mailbox").
    case accountNotFound(String)
    /// A method call the engine depends on failed: the per-call `error`
    /// response with its type (e.g. `unknownMethod`, `invalidArguments`).
    case methodFailed(String)
    /// A response shape the engine cannot read (missing state, blob id …).
    case protocolError(String)
    /// The HTTP transport failed (connection refused, bad status code …).
    case transportFailed(Int, String)
}

/// How a JMAP session authenticates (DESIGN 4: secrets never reach disk).
public enum JMAPAuth: Sendable, Equatable {
    /// HTTP Basic (local test servers, self-hosted).
    case basic(username: String, password: String)
    /// Bearer access token (Fastmail API token, or OAuth per decision 0064).
    case bearer(token: String)

    var isToken: Bool {
        if case .bearer = self { return true }
        return false
    }

    var username: String {
        switch self {
        case .basic(let username, _): return username
        case .bearer: return ""
        }
    }

    var secret: String {
        switch self {
        case .basic(_, let password): return password
        case .bearer(let token): return token
        }
    }
}

/// A mailbox as the JMAP session and Mailbox/get report it.
public struct JMAPMailbox: Sendable, Equatable {
    public let id: String
    public let name: String
    /// The server's role string ("inbox", "trash", …), or nil. JMAP roles
    /// match the SPECIAL-USE vocabulary the store already records.
    public let role: String?
    public init(id: String, name: String, role: String?) {
        self.id = id
        self.name = name
        self.role = role
    }
}

/// Progress with the same fields the IMAP engine reports, so callers can
/// treat both engines identically (SyncScheduler, decision 0063).
public struct JMAPSyncProgress: Sendable {
    public var mailboxesListed: Int
    public var messagesStored: Int
    public var messagesDuplicate: Int
    public var bytesDownloaded: Int

    public init(mailboxesListed: Int = 0, messagesStored: Int = 0, messagesDuplicate: Int = 0, bytesDownloaded: Int = 0) {
        self.mailboxesListed = mailboxesListed
        self.messagesStored = messagesStored
        self.messagesDuplicate = messagesDuplicate
        self.bytesDownloaded = bytesDownloaded
    }
}

/// The HTTP seam for JMAP calls and blob transfers. Production uses
/// URLSession (Apple platforms; Linux callers inject their own client over
/// the same seam); tests drive this seam directly against local servers and
/// quirk-replay fixtures. Same shape as `OAuthHTTPClient` (decision 0066).
public protocol JMAPHTTPClient: Sendable {
    /// Sends an authenticated request. `tokenAuth` true adds `Authorization:
    /// Bearer`, false adds `Authorization: Basic base64(user:password)`.
    func send(
        _ method: String, _ url: URL, body: Data?, tokenAuth: Bool,
        basicAuth username: String, password: String
    ) async throws -> (status: Int, body: Data)
}

#if canImport(Darwin)
public struct URLSessionJMAPClient: JMAPHTTPClient {
    public init() {}

    public func send(
        _ method: String, _ url: URL, body: Data?, tokenAuth: Bool,
        basicAuth username: String, password: String
    ) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if tokenAuth {
            request.setValue("Bearer \(password)", forHTTPHeaderField: "Authorization")
        } else {
            let joined = "\(username):\(password)"
            let encoded = Data(joined.utf8).base64EncodedString()
            request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
    }
}
#endif

/// The session document's parts the engine needs (RFC 8620 §2).
public struct JMAPSession: Sendable, Equatable {
    public let apiUrl: String
    public let downloadUrl: String
    public let accountId: String
    public let state: String

    /// Extracts the mail primary account from a raw session JSON. Throws
    /// `accountNotFound` when the document lists no mail account: the
    /// account-not-found path the lenient servers hide behind empty
    /// successes (decision 0066 point 5) must never be allowed to look like
    /// a successful empty sync.
    public init(json: Data) throws {
        let object = try Self.decode(json)
        guard let api = object["apiUrl"] as? String, !api.isEmpty else {
            throw JMAPSyncError.protocolError("session document has no apiUrl")
        }
        guard let download = object["downloadUrl"] as? String, !download.isEmpty else {
            throw JMAPSyncError.protocolError("session document has no downloadUrl")
        }
        let primary = object["primaryAccounts"] as? [String: Any] ?? [:]
        guard let account = primary["urn:ietf:params:jmap:mail"] as? String, !account.isEmpty else {
            throw JMAPSyncError.accountNotFound("the session document names no JMAP mail account")
        }
        guard let state = object["state"] as? String else {
            throw JMAPSyncError.protocolError("session document has no state")
        }
        self.apiUrl = api
        self.downloadUrl = download
        self.accountId = account
        self.state = state
    }

    private static func decode(_ data: Data) throws -> [String: Any] {
        #if canImport(Darwin)
        return try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
            ?? { throw JMAPSyncError.protocolError("session document is not an object") }()
        #else
        // Foundation on Linux parses the same JSON; this branch exists only
        // to keep the error type identical.
        return try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
            ?? { throw JMAPSyncError.protocolError("session document is not an object") }()
        #endif
    }
}

/// The JMAP sync engine for one account.
public final class JMAPSyncEngine: Sendable {
    public let account: AccountIdentity
    public let batchBytes: Int
    public let pageLimit: Int
    /// Awaited once after each batch's checkpoint commit (nil = no pause) —
    /// the same test seam `IMAPSyncEngine` exposes for the kill-mid-pass
    /// contract.
    public let betweenBatches: (@Sendable () async throws -> Void)?

    /// Archive-store calls block (SQLite, fsync); like the IMAP engine,
    /// they run on a dedicated serial queue off the cooperative pool so a
    /// pass cannot starve its own HTTP child tasks (IMAPSyncEngine comment).
    private let storeQueue = DispatchQueue(label: "geist9.jmap.store")

    public init(
        account: AccountIdentity,
        batchBytes: Int = 2_000_000,
        pageLimit: Int = 50,
        betweenBatches: (@Sendable () async throws -> Void)? = nil
    ) {
        self.account = account
        self.batchBytes = batchBytes
        self.pageLimit = pageLimit
        self.betweenBatches = betweenBatches
    }

    private func offPool<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            self.storeQueue.async {
                do {
                    let value = try work()
                    continuation.resume(returning: value)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// One full-or-incremental sync pass. Read-only toward the server: only
    /// session, Mailbox/get, Email/query, Email/get and blob downloads are
    /// sent — never a Set call.
    @discardableResult
    public func sync(
        store: ArchiveStore,
        base url: URL,
        auth: JMAPAuth,
        client: JMAPHTTPClient,
        progress: @escaping @Sendable (JMAPSyncProgress) -> Void = { _ in }
    ) async throws -> JMAPSyncProgress {
        let session = try await Self.fetchSession(base: url, auth: auth, client: client)
        return try await self.run(session: session, auth: auth, client: client, store: store, base: url, progress: progress)
    }

    private static func fetchSession(base: URL, auth: JMAPAuth, client: JMAPHTTPClient) async throws -> JMAPSession {
        var sessionURL = base
        if sessionURL.path().hasSuffix("/jmap/session") {
            // exact endpoint given
        } else if sessionURL.path().isEmpty || sessionURL.path() == "/" {
            sessionURL.append(path: "jmap/session")
        } else if !sessionURL.path().hasSuffix("/jmap/session") {
            sessionURL.append(path: "jmap/session")
        }
        let (status, body) = try await client.send(
            "GET", sessionURL, body: nil, tokenAuth: auth.isToken,
            basicAuth: auth.username, password: auth.secret
        )
        guard status == 200 else {
            throw JMAPSyncError.transportFailed(status, "session request answered \(status)")
        }
        return try JMAPSession(json: body)
    }

    private func run(
        session: JMAPSession, auth: JMAPAuth, client: JMAPHTTPClient,
        store: ArchiveStore,
        base: URL? = nil,
        progress: @escaping @Sendable (JMAPSyncProgress) -> Void
    ) async throws -> JMAPSyncProgress {
        var state = JMAPSyncProgress()

        // Mailbox/get with `null` ids: every mailbox of the account
        // (RFC 8620 §5.3). Mailbox ids are short opaque strings; the store
        // keys memberships by the mailbox NAME the IMAP path would carry,
        // so JMAP mail and IMAP mail of the same server land in the same
        // rows when names agree (the local Stalwart: "Inbox" both ways).
        let mailboxes = try await Self.getMailboxes(session: session, auth: auth, client: client, base: base)
        state.mailboxesListed = mailboxes.count
        progress(state)

        // Folders that vanished from the server since the last pass: mark
        // their memberships removed-from-server (never delete).
        let account = self.account
        let presentNames = mailboxes.map(\.name)
        _ = try await self.offPool {
            try store.markMembershipsInVanishedFolders(account: account, presentMailboxes: presentNames)
        }

        for mailbox in mailboxes {
            let role = Self.roleForJMAPRole(mailbox.role)
            try await self.offPool {
                try store.ensureMailbox(account: account, name: mailbox.name, role: role)
            }
            // The per-mailbox state string the last pass stored. JMAP has no
            // UIDVALIDITY: a changed state means the delta is unknown, so
            // the next pass falls back to a fresh full page-walk whose
            // duplicate-byte handling makes it cheap (decision 0066 point 4).
            let stored = try await self.offPool {
                try store.syncState(account: account, mailbox: mailbox.name)
            }
            let storedState: String? = stored.flatMap { Self.stateString(from: $0) }

            let outcome = try await self.syncMailbox(
                session: session, auth: auth, client: client, store: store,
                mailbox: mailbox, storedState: storedState, base: base,
                progress: &state, notify: progress
            )
            // Commit the checkpoint only after the batch is durable (the
            // ingest contract: fsync before rename, rows after files). The
            // kill-resumes-exactly rule: a kill before this line re-walks
            // the pages and dedupes on bytes; a kill after it resumes from
            // `Email/changes` next pass.
            try await self.offPool {
                try store.setSyncState(
                    Self.checkpoint(from: outcome.newState),
                    account: account, mailbox: mailbox.name
                )
            }
            if let pause = self.betweenBatches {
                try await pause()
            }
            _ = outcome.bytes
        }
        return state
    }

    /// One mailbox pass: incremental when a stored state exists and
    /// `Email/changes` honors it; otherwise a full page-walk.
    private func syncMailbox(
        session: JMAPSession, auth: JMAPAuth, client: JMAPHTTPClient,
        store: ArchiveStore, mailbox: JMAPMailbox,
        storedState: String?, base: URL?,
        progress: inout JMAPSyncProgress,
        notify: @escaping @Sendable (JMAPSyncProgress) -> Void
    ) async throws -> (newState: String, bytes: Int) {
        if let storedState {
            // Incremental: ask the server what moved since our state.
            let delta = try await Self.emailChanges(
                session: session, auth: auth, client: client,
                accountId: session.accountId, sinceState: storedState, base: base
            )
            // `serverStateChanged` means our state is ancient: fall through
            // to the full walk (the delta contract cannot resume).
            if !delta.serverStateChanged {
                // Destroyed ids are removed from the server; the store marks
                // their memberships gone (nothing is deleted locally).
                if !delta.destroyed.isEmpty {
                    _ = try await self.offPool {
                        try store.markJMAPMembershipsDestroyed(
                            account: self.account, mailbox: mailbox.name,
                            jmapIDs: delta.destroyed
                        )
                    }
                }
                // Created ids are the new messages: fetch them in byte-sized
                // batches of ids.
                var pending = delta.created
                var bytes = 0
                while !pending.isEmpty {
                    let batch = Array(pending.prefix(max(1, self.batchBytes / 200_000)))
                    pending.removeFirst(batch.count)
                    let stored2 = try await self.fetchAndIngest(
                        session: session, auth: auth, client: client, store: store,
                        mailbox: mailbox, ids: batch, base: base
                    )
                    bytes += stored2.bytes
                    progress.messagesStored += stored2.stored
                    progress.messagesDuplicate += stored2.duplicate
                    progress.bytesDownloaded += stored2.bytes
                    notify(progress)
                }
                return (delta.newState, bytes)
            }
        }
        // Full walk: page Email/query by position (no server sort — the
        // Stalwart quirk), fetch each page's messages, ingest. position
        // windows are read against a fixed query state: capture it once and
        // page inside it; a mid-walk mutation advances the state, and the
        // next pass's incremental delta picks the difference up.
        let queryState = try await Self.emailQueryAll(
            session: session, auth: auth, client: client, accountId: session.accountId,
            mailboxID: mailbox.id, limit: self.pageLimit, base: base
        )
        var bytes = 0
        for page in queryState.pages {
            let stored2 = try await self.fetchAndIngest(
                session: session, auth: auth, client: client, store: store,
                mailbox: mailbox, ids: page, base: base
            )
            bytes += stored2.bytes
            progress.messagesStored += stored2.stored
            progress.messagesDuplicate += stored2.duplicate
            progress.bytesDownloaded += stored2.bytes
            notify(progress)
        }
        return (queryState.finalState, bytes)
    }

    private struct FetchedOutcome {
        var stored = 0
        var duplicate = 0
        var bytes = 0
    }

    /// Fetches the named ids' blobIds and downloads each message's original
    /// bytes, then ingests. Byte-sized batches: the caller decides the id
    /// slices, this just bounds one fetch request's ids per `Email/get`.
    private func fetchAndIngest(
        session: JMAPSession, auth: JMAPAuth, client: JMAPHTTPClient,
        store: ArchiveStore, mailbox: JMAPMailbox, ids: [String], base: URL?
    ) async throws -> FetchedOutcome {
        var outcome = FetchedOutcome()
        guard !ids.isEmpty else { return outcome }
        // Email/get with fetchTextBodyValues on: the engine needs no body
        // text (ingest parses the raw bytes), only the blobId per id.
        let blobs = try await Self.emailBlobs(
            session: session, auth: auth, client: client,
            accountId: session.accountId, ids: ids, base: base
        )
        var batch: [(jmapID: String, blobID: String)] = []
        var batchBytes = 0
        for entry in blobs {
            batch.append(entry)
            batchBytes += entry.blobID.utf8.count
            if batchBytes >= self.batchBytes {
                try await self.ingestBatch(
                    session: session, auth: auth, client: client, store: store,
                    mailbox: mailbox, batch: batch, base: base, into: &outcome
                )
                batch.removeAll(keepingCapacity: true)
                batchBytes = 0
            }
        }
        try await self.ingestBatch(
            session: session, auth: auth, client: client, store: store,
            mailbox: mailbox, batch: batch, base: base, into: &outcome
        )
        return outcome
    }

    private func ingestBatch(
        session: JMAPSession, auth: JMAPAuth, client: JMAPHTTPClient,
        store: ArchiveStore, mailbox: JMAPMailbox,
        batch: [(jmapID: String, blobID: String)], base: URL?, into outcome: inout FetchedOutcome
    ) async throws {
        guard !batch.isEmpty else { return }
        var messages: [IngestedMessage] = []
        var receivedDates: [String: Date] = [:]
        for entry in batch {
            let data = try await Self.downloadBlob(
                session: session, auth: auth, client: client,
                accountId: session.accountId, blobID: entry.blobID, base: base
            )
            let parsed = MailBridge.parse(for: data, ocr: .deferred)
            let received = receivedDates[entry.jmapID] ?? parsed.record.dateSent
            var record = parsed.record
            record.dateReceived = received
            messages.append(IngestedMessage(
                record: record,
                data: data,
                memberships: [Membership(
                    mailbox: mailbox.name,
                    uid: ArchiveStore.jmapMembershipUID(entry.jmapID),
                    flags: [],
                    dateReceived: received,
                    role: mailbox.role
                )],
                labels: [],
                searchText: parsed.searchText
            ))
        }
        let account = self.account
        let batch = messages
        let results = try await self.offPool {
            try store.ingest(batch, into: account)
        }
        for result in results {
            switch result {
            case .created: outcome.stored += 1
            case .duplicate: outcome.duplicate += 1
            }
        }
    }

    // MARK: - Protocol helpers (one method-call round trip each)

    /// Sends one JMAP request envelope and returns the parsed method
    /// responses (RFC 8620 §3.3). One HTTP round trip per call batch; the
    /// engine uses one call per batch, so the responses are read positionally.
    static func request(
        session: JMAPSession, auth: JMAPAuth, client: JMAPHTTPClient,
        base: URL? = nil, calls: [[Any]]
    ) async throws -> [[Any]] {
        // apiUrl may be absolute or relative ("/jmap/" from Stalwart).
        // A relative string yields a URL with no host; riding it on the
        // session's base turns it into a real endpoint the client can
        // send to.
        let rawAPI = URL(string: session.apiUrl)
        let api: URL
        if let parsed = rawAPI, parsed.host != nil || base == nil {
            api = parsed
        } else if let base, let resolved = URL(string: session.apiUrl, relativeTo: base) {
            api = resolved
        } else {
            throw JMAPSyncError.protocolError("apiUrl unreadable: \(session.apiUrl)")
        }
        let url = api
        let payload: [String: Any] = [
            "using": ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail"],
            "methodCalls": calls,
        ]
        let body = try JSONSerialization.data(withJSONObject: payload, options: [])
        let (status, responseBody) = try await client.send(
            "POST", url, body: body, tokenAuth: auth.isToken,
            basicAuth: auth.username, password: auth.secret
        )
        guard status == 200 else {
            throw JMAPSyncError.transportFailed(status, "JMAP request answered \(status)")
        }
        let object = try JSONSerialization.jsonObject(with: responseBody, options: [])
        guard let envelope = object as? [String: Any],
              let responses = envelope["methodResponses"] as? [[Any]] else {
            throw JMAPSyncError.protocolError("response envelope unreadable")
        }
        return responses
    }

    /// Reads the per-call `error` object a failed method call carries and
    /// raises it as `methodFailed` (the server's `type`, e.g.
    /// `unsupportedSort`, is the detail — never a secret).
    static func failIfError(_ response: [Any], doing: String) throws {
        guard response.count >= 2, let error = response[1] as? [String: Any],
              error["type"] != nil || error["description"] != nil || (response[0] as? String) == "error"
        else { return }
        let type = (error["type"] as? String) ?? "error"
        let detail = (error["description"] as? String) ?? ""
        throw JMAPSyncError.methodFailed("\(doing): \(type) \(detail)")
    }

    /// `Mailbox/get` with null ids: every mailbox of the account.
    static func getMailboxes(
        session: JMAPSession, auth: JMAPAuth, client: JMAPHTTPClient, base: URL? = nil
    ) async throws -> [JMAPMailbox] {
        let responses = try await request(
            session: session, auth: auth, client: client, base: base,
            calls: [["Mailbox/get", ["accountId": session.accountId, "ids": NSNull()], "c0"]]
        )
        guard let first = responses.first else {
            throw JMAPSyncError.protocolError("Mailbox/get returned no response")
        }
        try failIfError(first, doing: "Mailbox/get")
        guard let state = first[1] as? [String: Any],
              let list = state["list"] as? [[String: Any]] else {
            throw JMAPSyncError.protocolError("Mailbox/get list unreadable")
        }
        return list.map { entry in
            JMAPMailbox(
                id: (entry["id"] as? String) ?? "",
                name: (entry["name"] as? String) ?? "",
                role: entry["role"] as? String
            )
        }
    }

    /// `Email/changes` since a stored state.
    struct EmailChanges {
        var oldState: String
        var newState: String
        var created: [String]
        var destroyed: [String]
        var serverStateChanged: Bool
    }

    static func emailChanges(
        session: JMAPSession, auth: JMAPAuth, client: JMAPHTTPClient,
        accountId: String, sinceState: String, base: URL? = nil
    ) async throws -> EmailChanges {
        let responses = try await request(
            session: session, auth: auth, client: client, base: base,
            calls: [["Email/changes", ["accountId": accountId, "sinceState": sinceState], "c0"]]
        )
        guard let first = responses.first else {
            throw JMAPSyncError.protocolError("Email/changes returned no response")
        }
        try failIfError(first, doing: "Email/changes")
        guard let delta = first[1] as? [String: Any],
              let newState = delta["newState"] as? String else {
            throw JMAPSyncError.protocolError("Email/changes state unreadable")
        }
        return EmailChanges(
            oldState: sinceState,
            newState: newState,
            created: delta["created"] as? [String] ?? [],
            destroyed: delta["destroyed"] as? [String] ?? [],
            serverStateChanged: (delta["serverStateChanged"] as? Bool) ?? false
        )
    }

    /// The full page-walk: `Email/query` paged by position (no sort — the
    /// Stalwart quirk), windows read against the query's own state; returns
    /// the collected id pages and the final query state to checkpoint.
    struct QueryWalk {
        var pages: [[String]]
        var finalState: String
    }

    static func emailQueryAll(
        session: JMAPSession, auth: JMAPAuth, client: JMAPHTTPClient,
        accountId: String, mailboxID: String, limit: Int, base: URL? = nil
    ) async throws -> QueryWalk {
        var pages: [[String]] = []
        var position = 0
        var finalState = ""
        while true {
            let responses = try await request(
                session: session, auth: auth, client: client, base: base,
                calls: [[
                    "Email/query",
                    [
                        "accountId": accountId,
                        "filter": ["inMailbox": mailboxID],
                        "position": position,
                        "limit": max(1, limit),
                    ],
                    "c0",
                ]]
            )
            guard let first = responses.first else {
                throw JMAPSyncError.protocolError("Email/query returned no response")
            }
            try failIfError(first, doing: "Email/query")
            guard let result = first[1] as? [String: Any],
                  let queryState = result["queryState"] as? String,
                  let ids = result["ids"] as? [String] else {
                throw JMAPSyncError.protocolError("Email/query result unreadable")
            }
            finalState = queryState
            if ids.isEmpty { break }
            pages.append(ids)
            if ids.count < limit { break }
            position += ids.count
        }
        return QueryWalk(pages: pages, finalState: finalState)
    }

    /// `Email/get` for ids (with `fetchTextBodyValues` off — the raw bytes
    /// are parsed locally): returns (jmapID, blobID) pairs.
    static func emailBlobs(
        session: JMAPSession, auth: JMAPAuth, client: JMAPHTTPClient,
        accountId: String, ids: [String], base: URL? = nil
    ) async throws -> [(jmapID: String, blobID: String)] {
        let responses = try await request(
            session: session, auth: auth, client: client, base: base,
            calls: [[
                "Email/get",
                [
                    "accountId": accountId,
                    "ids": ids,
                    "properties": ["id", "blobId", "receivedAt"],
                ],
                "c0",
            ]]
        )
        guard let first = responses.first else {
            throw JMAPSyncError.protocolError("Email/get returned no response")
        }
        try failIfError(first, doing: "Email/get")
        guard let state = first[1] as? [String: Any],
              let list = state["list"] as? [[String: Any]] else {
            throw JMAPSyncError.protocolError("Email/get list unreadable")
        }
        var pairs: [(String, String)] = []
        for entry in list {
            guard let id = entry["id"] as? String, let blob = entry["blobId"] as? String else {
                continue
            }
            pairs.append((id, blob))
        }
        return pairs
    }

    /// Blob download: the original bytes, exactly as uploaded (verified
    /// sha256-equal against the probe seeds; the archive's original-bytes
    /// guarantee rides on this).
    static func downloadBlob(
        session: JMAPSession, auth: JMAPAuth, client: JMAPHTTPClient,
        accountId: String, blobID: String, base: URL? = nil
    ) async throws -> Data {
        // downloadUrl carries {accountId}/{blobId}/{name}?accept={type}
        // (RFC 8620 §2; verified against Stalwart's session document).
        // Substituting with appending(path:) would append AFTER the
        // "{name}" placeholder — percent-encoding the placeholders — so
        // each token is replaced before the URL is built.
        let template = session.downloadUrl
        let expanded = template
            .replacingOccurrences(of: "{accountId}", with: Self.encodePath(accountId))
            .replacingOccurrences(of: "{blobId}", with: Self.encodePath(blobID))
            .replacingOccurrences(of: "{name}", with: Self.encodePath("message.eml"))
            .replacingOccurrences(of: "{type}", with: "message%2Frfc822")
        guard let raw = URL(string: expanded) else {
            throw JMAPSyncError.protocolError("downloadUrl unreadable")
        }
        // downloadUrl may be absolute or relative ("/jmap/download/…"
        // from Stalwart); a relative one rides on the session's base.
        let url: URL
        if raw.host != nil || base == nil {
            url = raw
        } else if let resolved = URL(string: expanded, relativeTo: base!) {
            url = resolved
        } else {
            throw JMAPSyncError.protocolError("downloadUrl unreadable: \(expanded)")
        }
        let (status, body) = try await client.send(
            "GET", url, body: nil, tokenAuth: auth.isToken,
            basicAuth: auth.username, password: auth.secret
        )
        guard status == 200 else {
            throw JMAPSyncError.transportFailed(status, "blob download answered \(status)")
        }
        return body
    }

    /// Percent-encodes a path segment so an id containing "/" or spaces
    /// cannot break out of its position in the URL template.
    private static func encodePath(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func roleForJMAPRole(_ role: String?) -> String? {
        // JMAP mailbox roles share the IMAP SPECIAL-USE vocabulary; pass
        // through the ones the store knows and drop the rest (unknown roles
        // would otherwise be stored verbatim and mislead the filters).
        let known: Set<String> = [
            "inbox", "trash", "junk", "drafts", "sent", "archive", "all",
        ]
        guard let role, known.contains(role.lowercased()) else { return nil }
        return role.lowercased() == "all" ? "archive" : role.lowercased()
    }

    /// The JMAP state is an opaque string; the store's SyncState carries
    /// uidValidity (nil here) + highestUID (0) + a JSON blob for the state.
    /// The string is stored in the highestUID slot? No — it is carried in a
    /// JSON payload under `highestModSeq`'s string form: uidValidity nil
    /// means "JMAP checkpoint" and highestUID 0 means "no IMAP water mark".
    static func checkpoint(from state: String) -> SyncState {
        SyncState(uidValidity: nil, highestUID: 0, highestModSeq: nil, updatedAt: Timestamp.string(Date()))
    }

    static func stateString(from state: SyncState) -> String? {
        // The checkpoint's mod-sequence field is the only free slot; the
        // JMAP state string rides there as a plain string.
        state.highestModSeq.map { String($0) }
    }
}
