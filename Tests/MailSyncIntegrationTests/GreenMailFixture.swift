// Integration tests for the sync engine against a REAL IMAP server
// (TESTING.md, Protocol row: "Sync engine against real servers").
//
// The suite runs whenever a GreenMail standalone instance is reachable at
// GEIST9_GREENMAIL_HOST / GEIST9_GREENMAIL_PORT (default 127.0.0.1:13143)
// with user `alice@example.com` / password `secret`; start one with
// `scripts/imap-servers.sh start` (TESTING.md). Without a reachable server
// every test fails loudly with setup instructions — it never silently skips
// (TESTING.md: "A test that needs a server it can't start fails with a clear
// message; it never silently skips").

import ArchiveCore
import GRDB
import IMAPCommands
import NIOCore
import NIOIMAP
import XCTest
@testable import MailSync

struct ServerMissing: Error, CustomStringConvertible {
    var message: String
    var description: String { self.message }
}

/// Connection details and helpers for the running GreenMail instance.
enum GreenMail {
    static var host: String {
        ProcessInfo.processInfo.environment["GEIST9_GREENMAIL_HOST"] ?? "127.0.0.1"
    }

    static var port: Int {
        Int(ProcessInfo.processInfo.environment["GEIST9_GREENMAIL_PORT"] ?? "13143") ?? 0
    }

    static var user: String { "alice@example.com" }
    static var password: String { "secret" }

    private static var configuration: IMAPConnection.Configuration {
        IMAPConnection.Configuration(
            hostname: self.host, port: UInt16(self.port), useTLS: false, logging: .noLogging
        )
    }

    /// Consumes a tagged response stream, asserting the final state is OK.
    static func awaitOK(_ stream: IMAPConnection.ResponseStream, what: String) async throws {
        for try await response in stream {
            if case .tagged(let tagged) = response {
                guard case .ok = tagged.state else {
                    throw SyncEngineError.commandFailed("\(what): \(tagged.state)")
                }
                break
            }
        }
    }

    /// Logs in and asserts the server answers with an OK greeting. Throws a
    /// ServerMissing with setup instructions when unreachable.
    static func connect(login: Bool) async throws -> IMAPConnection {
        do {
            return try await IMAPConnection.withConnection(configuration: self.configuration) { greeting, connection in
                guard case .ok = greeting.status else {
                    throw ServerMissing(message: "No OK greeting from \(self.host):\(self.port)")
                }
                if login {
                    try await connection.send(.login(username: self.user, password: self.password)) { _, stream in
                        try await self.awaitOK(stream, what: "seed login")
                    }
                }
                return connection
            }
        } catch let error as ServerMissing {
            throw error
        } catch {
            throw ServerMissing(message: """
                No IMAP server at \(self.host):\(self.port) — the integration suite needs a \
                running GreenMail standalone. Start it with scripts/imap-servers.sh start \
                (user \(self.user) / \(self.password)), then re-run. Underlying error: \(error)
                """)
        }
    }

    /// Asserts the server is up before a test does anything else.
    static func requireServer() async throws {
        _ = try await self.connect(login: false)
    }

    /// A fresh fixture folder per test run: a unique name means a guaranteed-
    /// empty folder whose UIDs restart at 1, so exact checkpoint assertions
    /// hold, and the suite is immune to shared-server pollution from earlier
    /// aborted runs.
    static func freshFixtureFolder() -> String {
        "gm-fixture-" + UUID().uuidString.prefix(8).lowercased()
    }

    /// Prepares a clean slate for a test:
    /// 1. purge every non-INBOX folder's content (earlier runs leave folders
    ///    behind that GreenMail can never delete once a session has selected
    ///    them — see the quirk note below — but emptied they hold no mail and
    ///    the engine syncs them as zero-message folders);
    /// 2. purge INBOX (the engine syncs it too, so archive-wide progress
    ///    counts must reflect the fixture alone);
    /// 3. create the fresh unique fixture folder.
    ///
    /// All purges run on the TEST HARNESS's own connections managing its own
    /// fixture — the read-only guarantee is about the sync engine (asserted
    /// separately against the fake server's recorded command list); fixture
    /// setup is not a violation of it.
    static func resetFixture(folder: String) async throws {
        var folders: [String] = []
        try await IMAPConnection.withConnection(configuration: self.configuration) { greeting, connection in
            guard case .ok = greeting.status else { throw ServerMissing(message: "no greeting") }
            try await connection.send(.login(username: self.user, password: self.password)) { _, stream in
                try await self.awaitOK(stream, what: "reset login")
            }
            try await connection.send(.list(nil, reference: MailboxName([]), .mailbox(ByteBuffer(string: "*")), [])) { _, stream in
                for try await response in stream {
                    if case .untagged(.mailboxData(.list(let info))) = response {
                        let name = String(decoding: info.path.name.bytes, as: UTF8.self)
                        if name != "INBOX" { folders.append(name) }
                    }
                    if case .tagged(let tagged) = response {
                        guard case .ok = tagged.state else {
                            throw SyncEngineError.commandFailed("reset LIST: \(tagged.state)")
                        }
                        break
                    }
                }
            }
            for name in folders {
                try await self.purgeFolder(name, on: connection)
            }
            try await self.purgeFolder("INBOX", on: connection)
            try await connection.send(.create(MailboxName(Array(folder.utf8)), [])) { _, stream in
                try await self.awaitOK(stream, what: "reset CREATE \(folder)")
            }
            return ()
        }
    }

    /// Marks every message in a folder \Deleted and expunges them, leaving
    /// the folder present but empty (STORE + EXPUNGE; DELETE is not usable
    /// on GreenMail for a folder any session ever selected: its session
    /// bookkeeping crashes the deleting connection instead).
    static func purgeFolder(_ name: String, on connection: IMAPConnection) async throws {
        try await connection.send(.select(MailboxName(Array(name.utf8)))) { _, stream in
            try await self.awaitOK(stream, what: "purge SELECT \(name)")
        }
        try await connection.send(
            .uidStore(
                .range(MessageIdentifierRange<UID>(UID(rawValue: 1)...UID(rawValue: UInt32.max))),
                [],
                .flags(StoreFlags.add(silent: true, list: [.deleted]))
            )
        ) { _, stream in
            try await self.awaitOK(stream, what: "purge STORE \(name)")
        }
        try await connection.send(.expunge) { _, stream in
            try await self.awaitOK(stream, what: "purge EXPUNGE \(name)")
        }
    }

    /// Creates one folder (for fixture folders the test builds mid-run).
    static func createFolder(_ folder: String) async throws {
        try await IMAPConnection.withConnection(configuration: self.configuration) { greeting, connection in
            guard case .ok = greeting.status else { throw ServerMissing(message: "no greeting") }
            try await connection.send(.login(username: self.user, password: self.password)) { _, stream in
                try await self.awaitOK(stream, what: "create login")
            }
            try await connection.send(.create(MailboxName(Array(folder.utf8)), [])) { _, stream in
                try await self.awaitOK(stream, what: "create \(folder)")
            }
            return ()
        }
    }

    /// Appends raw RFC 822 messages to the fixture folder in a fresh connection.
    static func seed(_ messages: [Data], to folder: String) async throws {
        try await IMAPConnection.withConnection(configuration: self.configuration) { greeting, connection in
            guard case .ok = greeting.status else { throw ServerMissing(message: "no greeting") }
            try await connection.send(.login(username: self.user, password: self.password)) { _, stream in
                try await self.awaitOK(stream, what: "seed login")
            }
            for bytes in messages {
                try await connection.append(to: MailboxName(Array(folder.utf8))) { _, stream, writer in
                    let message = AppendMessage(
                        options: .none,
                        data: AppendData(byteCount: bytes.count)
                    )
                    try await writer.write(message: message) { appendSlot in
                        try await appendSlot.write(messageBytes: ByteBuffer(bytes: bytes))
                    }
                    try await writer.finish()
                    for try await response in stream {
                        if case .tagged(let tagged) = response {
                            guard case .ok = tagged.state else {
                                throw SyncEngineError.commandFailed("seed APPEND: \(tagged.state)")
                            }
                            break
                        }
                    }
                }
            }
            return ()
        }
    }

}
