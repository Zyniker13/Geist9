// The M6 Done-when line "JMAP full and incremental sync pass against local
// Stalwart" (ROADMAP M6), run against the real local Stalwart 1.2.0
// instance scripts/imap-servers.sh start brings up. Only the real server
// semantics differ from the in-repo fake: no sort key accepted, state
// strings that advance on every mutation, blob download returning the
// original bytes. The archive contracts are the same ones the fake-driven
// JMAPSyncEngineTests pin: originals stored byte-for-byte, deletions only
// ever flagged removed-from-server, nothing deleted from the archive.

import Foundation
import XCTest
import GRDB
import ArchiveCore
@testable import MailSync

final class StalwartJMAPSyncTests: XCTestCase {
    private var server: StalwartFixture.Type { StalwartFixture.self }

    private var auth: JMAPAuth {
        .basic(username: StalwartFixture.adminUser, password: StalwartFixture.password)
    }

    private var account: AccountIdentity {
        AccountIdentity(
            email: StalwartFixture.accountEmail, displayName: "Alice", providerKind: "jmap"
        )
    }

    private func makeStore() throws -> (store: ArchiveStore, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("geist9-stalwart-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try ArchiveStore.create(
            at: dir.appendingPathComponent("Stalwart.emailarchive"), appVersion: "0.1.0"
        )
        return (store, dir)
    }

    /// Seeds the bootstrap account's Inbox with three messages (upload +
    /// import, the verified pattern) and returns (inboxID, seeded ids).
    private func seedThree(client: JMAPHTTPClient, accountId: String) async throws -> (String, [String]) {
        let inbox = try await StalwartFixture.mailboxID(
            named: "Inbox", client: client, auth: auth, accountId: accountId
        )
        var ids: [String] = []
        for subject in ["Seeded Alpha", "Seeded Bravo", "Seeded Charlie"] {
            let raw = StalwartFixture.message(subject)
            let id = try await StalwartFixture.seed(
                raw, into: inbox, client: client, auth: auth, accountId: accountId
            )
            ids.append(id)
        }
        return (inbox, ids)
    }

    func testFullPassStoresOriginalBytesAgainstStalwart() async throws {
        try await StalwartFixture.requireServer()
        let client = URLSessionJMAPClient()
        let (inbox, seeded) = try await seedThree(client: client, accountId: StalwartFixture.scratchAccountID)

        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let engine = JMAPSyncEngine(account: account)
        let progress = try await engine.sync(
            store: store, base: StalwartFixture.baseURL, auth: auth, client: client
        )
        // The walk listed the bootstrap mailboxes and stored exactly the
        // three seeded messages once.
        XCTAssertGreaterThanOrEqual(progress.mailboxesListed, 1)
        XCTAssertEqual(progress.messagesStored, 3, "full pass must store the three seeded messages")
        // The originals came back byte-for-byte through blob download.
        for subject in ["Seeded Alpha", "Seeded Bravo", "Seeded Charlie"] {
            let raw = StalwartFixture.message(subject)
            let hits = try store.search(subject, limit: 10, offset: 0, withSnippets: false, groupByThread: false, now: Date())
            XCTAssertEqual(hits.hits.count, 1, "seeded subject \(subject) must be found once")
            let hash: Data? = try await store.db.read { db in
                try Data.fetchOne(db, sql: "SELECT hash FROM message WHERE subject = ?", arguments: [subject])
            }
            let stored = try store.messageData(MessageHash(bytes: XCTUnwrap(hash)))
            XCTAssertEqual(stored, raw, "original bytes must be preserved for \(subject)")
        }

        // Cleanup: destroy what the test seeded (only its own messages).
        try await StalwartFixture.destroySeeded(
            ids: seeded, client: client, auth: auth, accountId: StalwartFixture.scratchAccountID
        )
        _ = inbox
    }

    func testIncrementalPassSeesChangesAndDestroyedAgainstStalwart() async throws {
        try await StalwartFixture.requireServer()
        let client = URLSessionJMAPClient()
        let (inbox, seeded) = try await seedThree(client: client, accountId: StalwartFixture.scratchAccountID)

        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let engine = JMAPSyncEngine(account: account)
        // Pass 1: full. Pass 2 with nothing changed on the server: no new
        // messages. Pass 3 after one more seed and one destroy: exactly one
        // stored, and the destroyed membership flagged removed-from-server
        // while the message itself stays in the archive.
        let first = try await engine.sync(
            store: store, base: StalwartFixture.baseURL, auth: auth, client: client
        )
        XCTAssertEqual(first.messagesStored, 3)

        let second = try await engine.sync(
            store: store, base: StalwartFixture.baseURL, auth: auth, client: client
        )
        XCTAssertEqual(second.messagesStored, 0, "unchanged server must produce an empty incremental pass")

        let extra = StalwartFixture.message("Seeded Delta")
        let deltaID = try await StalwartFixture.seed(
            extra, into: inbox, client: client, auth: auth, accountId: StalwartFixture.scratchAccountID
        )
        let third = try await engine.sync(
            store: store, base: StalwartFixture.baseURL, auth: auth, client: client
        )
        XCTAssertEqual(third.messagesStored, 1, "one new message must arrive through Email/changes")

        try await StalwartFixture.destroySeeded(
            ids: [deltaID], client: client, auth: auth, accountId: StalwartFixture.scratchAccountID
        )
        let fourth = try await engine.sync(
            store: store, base: StalwartFixture.baseURL, auth: auth, client: client
        )
        // The membership is flagged removed-from-server; the message stays
        // archived and searchable (nothing is ever deleted).
        XCTAssertEqual(fourth.messagesStored, 0)
        let stillThere = try store.search("Seeded Delta", limit: 10, offset: 0, withSnippets: false, groupByThread: false, now: Date())
        XCTAssertEqual(stillThere.hits.count, 1, "destroyed-on-server messages stay in the archive")

        try await StalwartFixture.destroySeeded(
            ids: seeded, client: client, auth: auth, accountId: StalwartFixture.scratchAccountID
        )
    }
}
