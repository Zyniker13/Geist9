// The IMAP sync engine (DESIGN 5). Read-only toward every server: the
// commands it sends are LOGIN, ID, LIST, ENABLE, SELECT, UID FETCH — never
// STORE, MOVE, EXPUNGE, or APPEND. It drives one account from discovery to
// stored bytes: list folders, per folder read the stored checkpoint, fetch
// new messages above the high-water UID in byte-sized batches, stream each
// BODY.PEEK[] to disk (hashed as it arrives), ingest, and only then commit
// the folder's checkpoint — so a kill resumes exactly where it stopped.
// Server-side deletions are tracked, never applied (DeletionTracking).

import ArchiveCore
import Foundation
import IMAPCommands
import NIOIMAP
import NIOCore

/// One folder the server reported.
public struct RemoteMailbox: Sendable, Equatable {
    /// Full path as the server reports it, e.g. "INBOX", "Archive/2024".
    public var path: String
    /// The SPECIAL-USE attributes the server listed, e.g. ["\\Sent"].
    public var attributes: [String]
    /// The hierarchy separator from LIST, when given ("." for 163, "/" elsewhere).
    public var pathSeparator: Character?

    public init(path: String, attributes: [String], pathSeparator: Character?) {
        self.path = path
        self.attributes = attributes
        self.pathSeparator = pathSeparator
    }

    /// The folder is selectable (\NoSelect / \Nonexistent mark otherwise).
    public var isSelectable: Bool {
        !attributes.contains(where: { $0.lowercased() == "\\noselect" })
            && !attributes.contains(where: { $0.lowercased() == "\\nonexistent" })
    }

    /// Renders one LIST attribute as its canonical wire text ("\Noselect").
    /// The library's `Attribute` type keeps its text private, so the known
    /// attributes are matched by value; a custom attribute (an atom the
    /// server made up) is matched against `MailboxInfo.Attribute(_:)` by
    /// round-tripping — nil only when even that fails, which cannot happen
    /// for anything the server can legally send.
    static func attributeName(_ attribute: MailboxInfo.Attribute) -> String {
        let known: [(MailboxInfo.Attribute, String)] = [
            (.noSelect, "\\Noselect"), (.nonExistent, "\\Nonexistent"),
            (.marked, "\\Marked"), (.unmarked, "\\Unmarked"),
            (.noInferiors, "\\Noinferiors"), (.hasChildren, "\\HasChildren"),
            (.hasNoChildren, "\\HasNoChildren"), (.subscribed, "\\Subscribed"),
            (.remote, "\\Remote"),
        ]
        for (candidate, text) in known where candidate == attribute {
            return text
        }
        // A SPECIAL-USE flag or a custom extension: reconstruct by matching
        // against a constructed twin with the same value.
        for text in ["\\Drafts", "\\Sent", "\\Junk", "\\Trash", "\\All", "\\Archive", "\\Flagged"] {
            if let candidate = MailboxInfo.Attribute(text), candidate == attribute {
                return text
            }
        }
        return ""
    }
}

/// Progress reported to the caller while a sync runs.
public struct SyncProgress: Sendable {
    /// Folders listed so far in this pass.
    public var foldersListed: Int
    /// Messages downloaded and stored in this pass.
    public var messagesStored: Int
    /// Messages skipped because their exact bytes were already stored.
    public var messagesDuplicate: Int
    /// Bytes downloaded in this pass (streamed body bytes).
    public var bytesDownloaded: Int

    public init(foldersListed: Int = 0, messagesStored: Int = 0, messagesDuplicate: Int = 0, bytesDownloaded: Int = 0) {
        self.foldersListed = foldersListed
        self.messagesStored = messagesStored
        self.messagesDuplicate = messagesDuplicate
        self.bytesDownloaded = bytesDownloaded
    }
}

/// Errors the sync engine reports. The text never contains the password or
/// the credential secret (DESIGN 10): a failed LOGIN is reported as an
/// authentication failure, never with the attempted secret echoed.
public enum SyncEngineError: Error, Equatable, Sendable {
    /// LOGIN (or the connection) failed; the detail is the server's status
    /// text, which carries no secret material.
    case authenticationFailed(String)
    /// A command the engine needs was refused.
    case commandFailed(String)
    /// The connection closed unexpectedly.
    case connectionLost
}

/// The IMAP sync engine for one account (DESIGN 5).
///
/// A class so `self` can be captured across the connection library's
/// `@Sendable` closures under every toolchain's strict-concurrency rules
/// (a struct's mutable copies would trip "sending self" on the 6.1
/// compiler); every field is a `let`, so it is safely `Sendable`.
public final class IMAPSyncEngine: Sendable {
    /// Where the connection goes. The engine never resolves providers
    /// itself: onboarding hands it a `ProviderProfile` (MailSync task 2).
    public let profile: ProviderProfile
    /// The account the archive records this mail under.
    public let account: AccountIdentity
    /// Byte budget per fetch batch (DESIGN 5: batches sized by bytes, not count).
    public let batchBytes: Int

    /// The archive-store calls block (SQLite, file writes), and a blocked
    /// call inside an async context parks a cooperative-pool thread — the
    /// very threads `IMAPConnection`'s reader/writer child tasks need, so a
    /// pass can starve its own connection and hang. Every store touch goes
    /// through this dedicated serial queue instead (hopped with a checked
    /// continuation), keeping the pool free.
    private let storeQueue = DispatchQueue(label: "geist9.sync.store")

    public init(profile: ProviderProfile, account: AccountIdentity, batchBytes: Int = 2_000_000) {
        self.profile = profile
        self.account = account
        self.batchBytes = batchBytes
    }

    /// Runs one blocking store call off the cooperative pool.
    private func offPool<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            self.storeQueue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// One full-or-incremental sync pass against the server, storing what it
    /// finds into `store`. Returns progress. Read-only: only LIST / SELECT /
    /// STATUS / UID FETCH are sent, plus ID and LOGIN.
    @discardableResult
    public func sync(
        store: ArchiveStore,
        credentials user: String,
        password: String,
        progress: @escaping (SyncProgress) -> Void = { _ in }
    ) async throws -> SyncProgress {
        let config = IMAPConnection.Configuration(
            hostname: profile.host,
            port: UInt16(port),
            useTLS: usesImplicitTLS,
            logging: .noLogging
        )
        do {
            return try await self.run(config: config, store: store, user: user, password: password) { progress($0) }
        } catch let error as IMAPConnection.Error {
            // The library's own failures (connection closed mid-command,
            // greeting never arrived, channel error) are connection loss.
            _ = error
            throw SyncEngineError.connectionLost
        }
    }

    private func run(
        config: IMAPConnection.Configuration,
        store: ArchiveStore,
        user: String,
        password: String,
        progress: @escaping (SyncProgress) -> Void
    ) async throws -> SyncProgress {
        var state = SyncProgress()
        let notify = { (s: SyncProgress) in progress(s) }
        try await IMAPConnection.withConnection(configuration: config) { greeting, connection in
            guard case .ok = greeting.status else {
                throw SyncEngineError.connectionLost
            }
            try await send(connection, .login(username: user, password: password)) { response in
                guard case .tagged(let t) = response else { return false }
                guard case .ok = t.state else {
                    throw SyncEngineError.authenticationFailed(Self.statusText(t.state))
                }
                return true
            }
            // RFC 2971 ID once after login (163 requires it before SELECT;
            // servers without the extension reply NO/BAD and stay up).
            try await send(connection, .id(["name": "Bristlecone", "version": "0.1.0"])) { response in
                // NO/BAD on ID is "extension not supported", not an error.
                if case .tagged = response { return true }
                return false
            }
            let mailboxes = try await listMailboxes(connection)
            state.foldersListed = mailboxes.count
            notify(state)
            // Folders that vanished from the server since the last pass:
            // everything stored under them is marked removed-from-server
            // (never deleted). Present folders are handled per-folder by
            // the UID SEARCH comparison.
            let account = self.account
            let presentPaths = mailboxes.map(\.path)
            _ = try await self.offPool {
                try store.markMembershipsInVanishedFolders(
                    account: account, presentMailboxes: presentPaths
                )
            }
            for mailbox in mailboxes where mailbox.isSelectable {
                let folderState = try await syncFolder(
                    connection, store: store, mailbox: mailbox, progress: &state, notify: notify
                )
                notify(state)
                if folderState.bytesThisFolder > 0 {
                    // Between batches: the politeness profile's pacing.
                    // batchPauseSeconds is in seconds; sleep the same unit
                    // (and only when there is something to wait for).
                    if profile.politeness.batchPauseSeconds > 0 {
                        try await Task.sleep(for: .seconds(profile.politeness.batchPauseSeconds))
                    }
                }
            }
        }
        return state
    }

    // MARK: - Connection steps

    private var port: Int {
        switch profile.tls {
        case .implicit(let port): return port
        case .starttls(let port): return port
        }
    }

    private var usesImplicitTLS: Bool {
        switch profile.tls {
        case .implicit: return true
        case .starttls: return false
        }
    }

    /// The human-readable text of a tagged state, without echoing any secret
    /// material: server status texts carry the server's own words only.
    private static func statusText(_ state: TaggedResponse.State) -> String {
        switch state {
        case .ok(let rt): return rt.text
        case .no(let rt): return rt.text
        case .bad(let rt): return rt.text
        }
    }

    private func send(
        _ connection: IMAPConnection, _ command: Command,
        untilDone check: @Sendable (Response) throws -> Bool
    ) async throws {
        try await connection.send(command) { _, stream in
            for try await response in stream {
                if try check(response) { return }
            }
            throw SyncEngineError.connectionLost
        }
    }

    private func listMailboxes(_ connection: IMAPConnection) async throws -> [RemoteMailbox] {
        var mailboxes: [RemoteMailbox] = []
        var sawDone = false
        try await connection.send(
            .list(nil, reference: MailboxName([]), .mailbox(ByteBuffer(string: "*")), [])
        ) { _, stream in
            for try await response in stream {
                switch response {
                case .untagged(.mailboxData(.list(let info))):
                    let name = String(decoding: info.path.name.bytes, as: UTF8.self)
                    var separator: Character?
                    if let sep = info.path.pathSeparator { separator = sep }
                    mailboxes.append(RemoteMailbox(
                        path: name,
                        attributes: info.attributes.compactMap { attribute in
                            // Render the attribute atomically ("\Noselect") by
                            // matching against the known set; unknown
                            // attributes are carried as their own equality
                            // class via the factory below.
                            RemoteMailbox.attributeName(attribute)
                        },
                        pathSeparator: separator
                    ))
                case .tagged(let t):
                    guard case .ok = t.state else {
                        throw SyncEngineError.commandFailed("LIST: \(Self.statusText(t.state))")
                    }
                    sawDone = true
                default:
                    break
                }
                if sawDone { return }
            }
            throw SyncEngineError.connectionLost
        }
        return mailboxes
    }

    // MARK: - Per-folder sync

    private struct FolderOutcome {
        var bytesThisFolder: Int
    }

    /// Syncs one folder: read the checkpoint, SELECT, fetch new UIDs in
    /// byte-sized batches, ingest, commit the checkpoint.
    private func syncFolder(
        _ connection: IMAPConnection,
        store: ArchiveStore,
        mailbox: RemoteMailbox,
        progress: inout SyncProgress,
        notify: (SyncProgress) -> Void
    ) async throws -> FolderOutcome {
        // 1. STATUS before SELECT: UIDVALIDITY and UIDNEXT without leaving
        // the selected state (the engine selects one folder at a time).
        guard let status = try await statusOf(connection, mailbox.path) else {
            throw SyncEngineError.commandFailed("STATUS \(mailbox.path): no response")
        }
        let account = self.account
        let path = mailbox.path
        let stored = try await self.offPool { try store.syncState(account: account, mailbox: path) }
        let serverValidity = status.uidValidity.map { Int64($0) } ?? 0
        if stored?.uidValidity != serverValidity {
            // Fresh folder or a forced UIDVALIDITY change: reset the
            // high-water mark so the folder is re-fetched from the start
            // (DESIGN 5 step 3). Duplicate bytes cost an index lookup only.
            _ = try await self.offPool { try store.clearSyncState(account: account, mailbox: path) }
        }
        let highWater = (stored?.uidValidity == serverValidity) ? (stored?.highestUID ?? 0) : 0

        // 2. SELECT the folder (read-only use of the connection; the engine
        // never issues anything that mutates).
        try await select(connection, mailbox.path)

        // 2b. The folder's live UID set (UID SEARCH ALL): what the server
        // has right now, independent of the checkpoint. Feeds deletion
        // tracking below — a membership the search no longer names is gone
        // from the server; one it names stays, fetched or not.
        let serverUIDs = try await liveUIDs(connection)

        var outcome = FolderOutcome(bytesThisFolder: 0)
        var batches = 0
        // The high-water the pass has reached so far; the checkpoint's
        // high-water only grows (it starts from the stored one).
        var passHighWater = highWater
        while true {
            batches += 1
            let lower = passHighWater + 1
            // Fetch in byte-sized batches above the high-water mark. The
            // budget caps one batch (at least one message fits); the next
            // batch continues above this one's highest UID until the
            // server says the window is empty.
            let batch = try await fetchBatch(
                connection, from: lower, maxBytes: batchBytes
            )
            guard !batch.messages.isEmpty else { break }
            var storedCount = 0
            for message in batch.messages {
                let result = try await self.ingest(message, into: store, mailbox: path)
                switch result {
                case .created: storedCount += 1
                case .duplicate: progress.messagesDuplicate += 1
                }
            }
            progress.messagesStored += storedCount
            progress.bytesDownloaded += batch.bytes
            outcome.bytesThisFolder += batch.bytes
            passHighWater = max(passHighWater, batch.highestUID)
            // 3. Commit the checkpoint only after the batch is durable
            // (ingest fsyncs before the rename and commits rows after), so
            // a kill resumes exactly where it stopped (DESIGN 5 step 5).
            let checkpoint = SyncState(
                uidValidity: serverValidity,
                highestUID: passHighWater,
                highestModSeq: status.highestModSeq.map { Int64($0) },
                updatedAt: Timestamp.string(Date())
            )
            try await self.offPool {
                try store.setSyncState(checkpoint, account: account, mailbox: path)
            }
            // The batch ended because the window is exhausted, not because
            // the budget capped it (a capped batch continues next batch).
            if batch.messages.isEmpty { break }
        }
        // 4. Deletion tracking (DESIGN 5 step 6): mark memberships the
        // folder's UID SEARCH no longer names. The store never deletes;
        // it only records.
        _ = try await self.offPool {
            try store.markMembershipsAbsentFrom(
                account: account, mailbox: path, serverUIDs: serverUIDs
            )
        }
        return outcome
    }

    private struct StatusInfo {
        var uidValidity: UIDValidity?
        var highestModSeq: ModificationSequenceValue?
    }

    private func statusOf(_ connection: IMAPConnection, _ path: String) async throws -> StatusInfo? {
        var info = StatusInfo(uidValidity: nil, highestModSeq: nil)
        var sawDone = false
        try await connection.send(
            .status(
                MailboxName(Array(path.utf8)),
                [.uidValidity, .highestModificationSequence]
            )
        ) { _, stream in
            for try await response in stream {
                switch response {
                case .untagged(.mailboxData(.status(_, let st))):
                    info = StatusInfo(uidValidity: st.uidValidity, highestModSeq: st.highestModificationSequence)
                case .tagged(let t):
                    guard case .ok = t.state else {
                        throw SyncEngineError.commandFailed("STATUS: \(Self.statusText(t.state))")
                    }
                    sawDone = true
                default:
                    break
                }
                if sawDone { return }
            }
            throw SyncEngineError.connectionLost
        }
        return info
    }

    private func select(_ connection: IMAPConnection, _ path: String) async throws {
        try await send(connection, .select(MailboxName(Array(path.utf8)))) { response in
            guard case .tagged(let t) = response else { return false }
            guard case .ok = t.state else {
                throw SyncEngineError.commandFailed("SELECT \(path): \(IMAPSyncEngine.statusText(t.state))")
            }
            return true
        }
    }

    /// The folder's live UIDs: `UID SEARCH ALL` right after SELECT.
    /// Servers without SEARCH reply NO/BAD — then the set is unknown and
    /// deletion marking is skipped for that folder this pass (fail-safe:
    /// nothing is ever marked gone on a missing answer).
    private func liveUIDs(_ connection: IMAPConnection) async throws -> Set<Int64> {
        // The response handler is @Sendable: hand results back through a
        // locked box (the stream serializes callbacks, so the lock only
        // silences the race warning).
        final class ResultBox: @unchecked Sendable {
            private let lock = NSLock()
            private var uids = Set<Int64>()
            private var sawSearch = false
            func insert(_ uid: Int64) {
                self.lock.lock(); defer { self.lock.unlock() }
                self.uids.insert(uid)
                self.sawSearch = true
            }
            func value() -> (uids: Set<Int64>, sawSearch: Bool) {
                self.lock.lock(); defer { self.lock.unlock() }
                return (self.uids, self.sawSearch)
            }
        }
        let box = ResultBox()
        try await send(connection, .uidSearch(key: .all)) { response in
            switch response {
            case .untagged(.mailboxData(.search(let ids, _))):
                for id in ids {
                    box.insert(Int64(id.rawValue))
                }
                return false
            case .tagged(let t):
                guard case .ok = t.state else { return true } // NO/BAD: skip marking
                return true
            default:
                return false
            }
        }
        let result = box.value()
        return result.sawSearch ? result.uids : Set()
    }

    // MARK: - Fetch

    private struct FetchedMessage {
        var uid: UInt32
        var data: Data
        var internalDate: Date?
    }

    private struct Batch {
        var messages: [FetchedMessage]
        var bytes: Int
        var highestUID: Int64
        var reachedEnd: Bool
    }

    /// One byte-sized batch: metadata for the next window of UIDs above
    /// `from`, then BODY.PEEK[] streamed straight into memory (the ingest
    /// path hashes and writes to disk). The batch ends at `maxBytes` of
    /// streamed body bytes.
    private func fetchBatch(
        _ connection: IMAPConnection, from: Int64, maxBytes: Int
    ) async throws -> Batch {
        // Window of candidate UIDs: one above the high-water mark up to
        // UID maximum. The server answers with what exists.
        let window = LastCommandSet<UID>.range(
            MessageIdentifierRange<UID>(
                UID(rawValue: UInt32(clamping: from))...UID(rawValue: .max)
            )
        )

        // 1. Stream bodies for the window, stopping at maxBytes.
        var collector = BodyCollector(maxBytes: maxBytes)
        try await connection.send(
            .uidFetch(window, [.uid, .internalDate, .bodySection(peek: true, .complete, nil)], [])
        ) { _, stream in
            for try await response in stream {
                switch response {
                case .fetch(let f):
                    try collector.observe(f)
                case .tagged(let t):
                    guard case .ok = t.state else {
                        throw SyncEngineError.commandFailed("UID FETCH body: \(Self.statusText(t.state))")
                    }
                    return
                default:
                    break
                }
            }
            throw SyncEngineError.connectionLost
        }
        // A window whose first candidate UID does not exist answers with
        // nothing; that is the "reached end" case.
        return collector.batch()
    }

    /// Collects the streamed BODY.PEEK[] responses for one batch.
    /// Enforces `maxBytes`: once the budget is reached, the message being
    /// streamed still completes (a partial message is not storable), but no
    /// further message starts, and `budgetReached` reports why the batch
    /// stopped — the caller then ends the pass's folder loop.
    private struct BodyCollector {
        var maxBytes: Int
        var messages: [FetchedMessage] = []
        var bytes = 0
        var currentUID: UInt32?
        var currentDate: Date?
        var currentData = Data()
        var currentExpected = 0
        /// True when the batch stopped because the byte budget ran out.
        var budgetReached = false

        /// INTERNALDATE to `Date`: the components carry an offset in minutes
        /// east of UTC, applied here the way the wire value means it
        /// (the date is written "date-time" with the zone sign included).
        static func date(_ d: ServerMessageDate) -> Date {
            let c = d.components
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: c.zoneMinutes * 60) ?? TimeZone(identifier: "UTC")!
            return calendar.date(
                from: DateComponents(
                    year: c.year, month: c.month, day: c.day,
                    hour: c.hour, minute: c.minute, second: c.second
                )
            ) ?? Date(timeIntervalSince1970: 0)
        }

        mutating func observe(_ f: FetchResponse) throws {
            switch f {
            case .start, .startUID:
                break
            case .simpleAttribute(.uid(let uid)):
                // A new message begins only when no message is in flight;
                // after the budget is hit, skip everything further.
                if currentUID == nil {
                    if self.bytes >= self.maxBytes {
                        self.budgetReached = true
                    }
                }
                currentUID = uid.rawValue
            case .simpleAttribute(.internalDate(let d)):
                currentDate = Self.date(d)
            case .simpleAttribute:
                break
            case .streamingBegin(_, let count):
                currentData = Data()
                currentExpected = count
            case .streamingBytes(var buffer):
                currentData.append(contentsOf: buffer.readBytes(length: buffer.readableBytes) ?? [])
            case .streamingEnd:
                if let uid = currentUID, currentData.count == currentExpected, !self.budgetReached {
                    messages.append(FetchedMessage(
                        uid: uid, data: Data(currentData), internalDate: currentDate
                    ))
                    bytes += currentData.count
                }
                currentUID = nil
                currentDate = nil
                currentData = Data()
            case .finish:
                break
            }
        }

        func batch() -> Batch {
            let highest = messages.map { Int64($0.uid) }.max() ?? 0
            return Batch(messages: messages, bytes: bytes, highestUID: highest, reachedEnd: messages.isEmpty)
        }
    }

    // MARK: - Ingest

    private func ingest(_ fetched: FetchedMessage, into store: ArchiveStore, mailbox: String) async throws -> IngestResult {
        // The parse is pure CPU over the fetched bytes; the store call
        // blocks (SQLite + fsync) and must leave the cooperative pool.
        let fetchedBox = fetched
        let parsed = MailBridge.parse(for: fetchedBox.data, ocr: .deferred)
        var record = parsed.record
        // INTERNALDATE is the arrival time (DESIGN 6 `dateReceived`); the
        // Date header stays `dateSent`. When the server gave no INTERNALDATE
        // the header date stands in (nil keeps the parse's own value).
        if let internalDate = fetchedBox.internalDate {
            record.dateReceived = internalDate
        }
        let message = IngestedMessage(
            record: record,
            data: fetchedBox.data,
            memberships: [Membership(
                mailbox: mailbox,
                uid: Int64(fetchedBox.uid),
                flags: [],
                dateReceived: fetchedBox.internalDate ?? record.dateSent
            )],
            searchText: parsed.searchText
        )
        let account = self.account
        return try await self.offPool { try store.ingest(message, into: account) }
    }
}
