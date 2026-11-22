// SyncScheduler tests (M4 Done-when: "start/stop per account, background
// cadence, per-account politeness"). The scheduler lists the archive's
// syncable accounts (decision 0062), reads each secret from the credential
// store under the onboarding key, runs engine passes one account at a time
// (per-account politeness, never parallel across accounts), and can be
// stopped and started again. Everything here runs against the in-repo fake
// IMAP server; nothing touches a real account.

import ArchiveCore
import Credentials
import XCTest
@testable import MailSync

final class SyncSchedulerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("geist9-scheduler-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private let account = AccountIdentity(
        email: "alice@example.com", displayName: "Alice", providerKind: "imap"
    )

    /// One small RFC 822 message with a distinct subject per uid.
    private func message(_ subject: String) -> Data {
        let headers = (
            "From: Bob <bob@example.org>\r\n" +
            "To: Alice <alice@example.com>\r\n" +
            "Subject: \(subject)\r\n" +
            "Date: Mon, 20 Jan 2026 10:00:00 +0000\r\n" +
            "Message-ID: <\(subject)@example.org>\r\n" +
            "\r\n"
        )
        return Data((headers + "hello\r\n").utf8)
    }

    /// The conservative profile pointing at a plain loopback fake server.
    private func profile(port: UInt16) -> ProviderProfile {
        ProviderProfile(
            id: "test",
            displayName: "Test",
            host: "127.0.0.1",
            tls: .starttls(port: Int(port)),
            credential: .appPassword,
            politeness: PolitenessProfile(maxConnections: 2, dailyByteBudget: nil, batchPauseSeconds: 0),
            domains: []
        )
    }

    /// Adds the account through the onboarding path so the profile is
    /// stored on the row (decision 0062) and the secret under the
    /// standard credential key, exactly as production would.
    private func addAccount(
        store: ArchiveStore, credentials: InMemoryCredentialStore,
        server: FakeIMAPServer
    ) async throws {
        let controller = OnboardingController(resolver: { _ in .manual })
        _ = try await controller.addAccount(
            store: store, credentials: credentials,
            identity: account, profile: profile(port: server.port), password: "secret"
        )
    }

    /// Three messages in INBOX on the fake server, with a prefix keeping
    /// Message-IDs distinct across two server instances.
    private func threeMessageScenario(prefix: String = "A") -> FakeServerScenario {
        var scenario = FakeServerScenario()
        scenario.folders = [
            FakeFolder(
                name: "INBOX",
                messages: (1...3).map { uid in
                    FakeMessage(uid: UInt32(uid), data: message("\(prefix)\(uid)"))
                },
                uidValidity: 1
            )
        ]
        return scenario
    }

    // MARK: - One pass per account

    /// Running the scheduler once stores the server's messages and returns
    /// progress; nothing read-only is violated and nothing is stored twice.
    func testRunPassStoresMessagesOnce() async throws {
        let server = FakeIMAPServer(scenario: threeMessageScenario())
        try server.start()
        defer { server.stop() }

        let store = try ArchiveStore.create(
            at: tempDir.appendingPathComponent("Test.emailarchive"), appVersion: "0.1.0"
        )
        let credentials = InMemoryCredentialStore()
        try await addAccount(store: store, credentials: credentials, server: server)

        let scheduler = SyncScheduler()
        let progress = try await scheduler.runPass(store: store, credentials: credentials)

        XCTAssertEqual(progress.messagesStored, 3, "the pass stored the server's three messages")
        let again = try await scheduler.runPass(store: store, credentials: credentials)
        XCTAssertEqual(again.messagesStored, 0, "the second pass stores nothing new")
        // Read-only: no write commands ever reached the server.
        for command in server.seenCommands {
            XCTAssertTrue(
                Self.readOnlyCommands.contains(where: { command.hasPrefix($0) }),
                "read-only violated by: \(command)"
            )
        }
    }

    /// A missing credential makes the account skip its pass with an
    /// "unlock to continue" event (DESIGN 4), and the error is never
    /// echoed as an authentication failure (the secret is not at fault).
    func testMissingCredentialSkipsThePass() async throws {
        let server = FakeIMAPServer(scenario: threeMessageScenario())
        try server.start()
        defer { server.stop() }

        let store = try ArchiveStore.create(
            at: tempDir.appendingPathComponent("Test.emailarchive"), appVersion: "0.1.0"
        )
        let credentials = InMemoryCredentialStore()
        try await addAccount(store: store, credentials: credentials, server: server)
        try await credentials.delete(OnboardingController.credentialKey(email: account.email))

        let scheduler = SyncScheduler()
        let events = EventLog()
        let progress = try await scheduler.runPass(
            store: store, credentials: credentials,
            onEvent: { events.record($0) }
        )
        XCTAssertEqual(progress.messagesStored, 0, "nothing synced without the secret")
        XCTAssertTrue(
            events.contains { if case .skipped(let email, let reason) = $0 {
                return email == account.email && reason == "Unlock the app to continue archiving"
            } else { return false } },
            "expected a skipped event naming the account: \(events)"
        )
        XCTAssertTrue(server.seenCommands.isEmpty, "the server was never contacted")
    }

    // MARK: - Two accounts, serial

    /// Two accounts sync serially, each with its own profile and server,
    /// and both store their mail under their own account rows.
    func testTwoAccountsSyncSeriallyUnderTheirOwnRows() async throws {
        let serverA = FakeIMAPServer(scenario: threeMessageScenario())
        try serverA.start()
        var bobScenario = threeMessageScenario(prefix: "B")
        bobScenario.user = "bob@example.org"
        let serverB = FakeIMAPServer(scenario: bobScenario)
        try serverB.start()
        defer { serverA.stop(); serverB.stop() }

        let store = try ArchiveStore.create(
            at: tempDir.appendingPathComponent("Test.emailarchive"), appVersion: "0.1.0"
        )
        let credentials = InMemoryCredentialStore()

        let controller = OnboardingController(resolver: { _ in .manual })
        _ = try await controller.addAccount(
            store: store, credentials: credentials,
            identity: account, profile: profile(port: serverA.port), password: "secret"
        )
        let bob = AccountIdentity(
            email: "bob@example.org", displayName: "Bob", providerKind: "imap"
        )
        var bobProfile = profile(port: serverB.port)
        bobProfile.id = "bob-test"
        _ = try await controller.addAccount(
            store: store, credentials: credentials,
            identity: bob, profile: bobProfile, password: "secret"
        )

        let scheduler = SyncScheduler()
        let order = EventLog()
        let progress = try await scheduler.runPass(store: store, credentials: credentials) { event in
            if case .completed(let email, _) = event { order.recordEmail(email) }
        }
        XCTAssertEqual(order.emails, ["alice@example.com", "bob@example.org"], "serial, in row order")
        XCTAssertEqual(progress.messagesStored, 6, "both accounts stored their three messages")
        // Each account row carries its own mail (mailbox→account join).
        func storedUnder(_ identity: AccountIdentity) throws -> Int {
            try store.db.read { database in
                try Int.fetchOne(
                    database,
                    sql: """
                    SELECT COUNT(*) FROM message m
                    JOIN message_mailbox mm ON mm.messageID = m.id
                    JOIN mailbox mb ON mb.id = mm.mailboxID
                    JOIN account a ON a.id = mb.accountID
                    WHERE a.email = ? AND a.providerKind = 'imap'
                    """,
                    arguments: [identity.email.lowercased()]
                ) ?? 0
            }
        }
        XCTAssertEqual(try storedUnder(account), 3)
        XCTAssertEqual(try storedUnder(bob), 3)
    }

    // MARK: - Cadence loop

    /// start() runs a pass immediately and then on the cadence; stop()
    /// ends it and start() can be called again afterwards.
    func testStartRunsImmediatelyThenOnCadenceAndStopEndsIt() async throws {
        let server = FakeIMAPServer(scenario: threeMessageScenario())
        try server.start()
        defer { server.stop() }

        let store = try ArchiveStore.create(
            at: tempDir.appendingPathComponent("Test.emailarchive"), appVersion: "0.1.0"
        )
        let credentials = InMemoryCredentialStore()
        try await addAccount(store: store, credentials: credentials, server: server)

        let scheduler = SyncScheduler(pollInterval: .milliseconds(500))
        let passes = EventLog()
        await scheduler.start(store: store, credentials: credentials) { _ in passes.tick() }
        // The immediate first pass is synchronous with start().
        XCTAssertEqual(passes.count, 1, "start() ran the first pass before returning")

        // A server with new mail is picked up by a cadence tick within a
        // second (interval 0.5 s), and stop() ends the loop for good.
        server.updateFolders([
            FakeFolder(
                name: "INBOX",
                messages: (1...4).map { uid in
                    FakeMessage(uid: UInt32(uid), data: message("Scheduler\(uid)"))
                },
                uidValidity: 1
            )
        ])
        try await Task.sleep(for: .milliseconds(1_400))
        let afterTicks = passes.count
        await scheduler.stop()
        let afterStop = passes.count
        try await Task.sleep(for: .milliseconds(1_600))
        XCTAssertEqual(passes.count, afterStop, "nothing runs after stop()")
        XCTAssertGreaterThanOrEqual(afterTicks, 2, "the cadence ticked at least once while running")
    }

    private static let readOnlyCommands: Set<String> = [
        "LOGIN", "ID", "LIST", "STATUS", "SELECT", "UID FETCH", "UID SEARCH", "LOGOUT", "NOOP"
    ]
}

/// A thread-safe event box for assertions from @Sendable callbacks.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [SchedulerEvent] = []
    private var ticks = 0

    func record(_ event: SchedulerEvent) {
        lock.lock(); defer { lock.unlock() }
        items.append(event)
    }

    func tick() {
        lock.lock(); defer { lock.unlock() }
        ticks += 1
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return ticks
    }

    var emails: [String] {
        lock.lock(); defer { lock.unlock() }
        return items.compactMap {
            if case .completed(let email, _) = $0 { return email } else { return nil }
        }
    }

    func recordEmail(_ email: String) {
        record(.completed(email: email, messagesStored: 0))
    }

    func contains(_ predicate: (SchedulerEvent) -> Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return items.contains(where: predicate)
    }
}
