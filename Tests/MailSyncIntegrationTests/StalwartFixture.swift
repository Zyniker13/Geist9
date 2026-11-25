// Connection details for the real local JMAP server the JMAP integration
// suite runs against (TESTING.md, Protocol row; M6 Done-when "JMAP full and
// incremental sync pass against local Stalwart"). Stalwart 1.2.0 bootstrap
// mode serves JMAP on its recovery HTTP listener; `scripts/imap-servers.sh
// start` brings it up alongside GreenMail and Dovecot and exports the
// bootstrap password it generated (GEIST9_STALWART_PASSWORD) — the test
// reads it from the environment and NEVER from a committed value. Without
// a reachable server the test fails loudly with setup instructions; it
// never silently skips. The only way to leave Stalwart out is
// GEIST9_SKIP_SERVERS=stalwart (explicit environment choice, never silent).

import Foundation
import ArchiveCore
@testable import MailSync

enum StalwartFixture {
    /// Where the recovery listener listens: IPv4 8080 is often taken on
    /// this machine's shared loopback, so the fixture binds [::1] and the
    /// default host name is the IPv6 loopback literal.
    static var host: String {
        ProcessInfo.processInfo.environment["GEIST9_STALWART_HOST"] ?? "::1"
    }
    static var port: Int {
        Int(ProcessInfo.processInfo.environment["GEIST9_STALWART_PORT"] ?? "18080") ?? 18080
    }

    /// The bootstrap password `scripts/imap-servers.sh start` generated.
    /// Missing or empty means the test cannot log in — a loud failure, not
    /// a skip (TESTING.md).
    static var password: String {
        ProcessInfo.processInfo.environment["GEIST9_STALWART_PASSWORD"] ?? ""
    }

    /// The bootstrap admin is "admin"; the scratch account Stalwart
    /// auto-creates in bootstrap mode and the test seeds messages into.
    static let adminUser = "admin"
    static let accountEmail = "alice@example.com"
    static let scratchAccountID = "d333333"

    static var baseURL: URL {
        URL(string: "http://[\(host)]:\(port)")!
    }

    /// Asserts the server answers /jmap/session and the bootstrap password
    /// is present. Throws ServerMissing with setup instructions otherwise.
    static func requireServer() async throws {
        guard !password.isEmpty else {
            throw ServerMissing(message: """
                GEIST9_STALWART_PASSWORD is not set — the JMAP integration test needs \
                the bootstrap password scripts/imap-servers.sh start exports. \
                Start the servers with scripts/imap-servers.sh start, then re-run.
                """)
        }
        let (status, _) = try await URLSessionJMAPClient().send(
            "GET", baseURL.appending(path: "jmap/session"), body: nil,
            tokenAuth: false, basicAuth: adminUser, password: password
        )
        guard status == 200 else {
            throw ServerMissing(message: """
                No JMAP session (HTTP \(status)) at \(baseURL)jmap/session — start \
                Stalwart with scripts/imap-servers.sh start, then re-run.
                """)
        }
    }

    /// Uploads an RFC 5322 message through /jmap/upload/{accountId} and
    /// imports it into the named mailbox via Email/import (the verified
    /// Stalwart seeding pattern; the inline-base64 import path is refused).
    /// Returns the created email id.
    static func seed(
        _ raw: Data, into mailboxID: String, client: JMAPHTTPClient,
        auth: JMAPAuth, accountId: String
    ) async throws -> String {
        // Upload first.
        let uploadURL = baseURL
            .appending(path: "jmap/upload")
            .appending(path: accountId)
        let (uploadStatus, uploadBody) = try await client.send(
            "POST", uploadURL, body: raw, tokenAuth: auth.isToken,
            basicAuth: auth.username, password: auth.secret
        )
        guard uploadStatus == 200 else {
            throw JMAPSyncError.transportFailed(uploadStatus, "blob upload answered \(uploadStatus)")
        }
        guard let blob = (try JSONSerialization.jsonObject(with: uploadBody) as? [String: Any])?["blobId"] as? String,
              !blob.isEmpty else {
            throw JMAPSyncError.protocolError("upload response has no blobId")
        }

        // Then import the uploaded blob into the mailbox.
        let importCall: [String: Any] = [
            "using": ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail"],
            "methodCalls": [[
                "Email/import", [
                    "accountId": accountId,
                    "emails": [
                        "seed-\(UUID().uuidString.prefix(8))": [
                            "blobId": blob,
                            "mailboxIds": [mailboxID: true],
                        ]
                    ],
                ], "c0",
            ]],
        ]
        let request = try JSONSerialization.data(withJSONObject: importCall)
        let (status, body) = try await client.send(
            "POST", URL(string: apiUrl, relativeTo: baseURL)!, body: request,
            tokenAuth: auth.isToken, basicAuth: auth.username, password: auth.secret
        )
        guard status == 200 else {
            throw JMAPSyncError.transportFailed(status, "Email/import answered \(status)")
        }
        guard let envelope = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let calls = envelope["methodResponses"] as? [[Any]],
              let args = calls.first?[1] as? [String: Any],
              let created = args["created"] as? [String: Any],
              let id = (created.values.first as? [String: Any])?["id"] as? String,
              !id.isEmpty else {
            throw JMAPSyncError.protocolError("Email/import response unreadable")
        }
        return id
    }

    /// The Mailbox/get result for the seeded account's mailbox named
    /// `name` (bootstrap pre-creates Inbox "a".."Sent e").
    static func mailboxID(named name: String, client: JMAPHTTPClient, auth: JMAPAuth, accountId: String) async throws -> String {
        let call: [String: Any] = [
            "using": ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail"],
            "methodCalls": [["Mailbox/query", ["accountId": accountId, "filter": ["name": name]], "c0"]],
        ]
        let request = try JSONSerialization.data(withJSONObject: call)
        let (status, body) = try await client.send(
            "POST", URL(string: apiUrl, relativeTo: baseURL)!, body: request,
            tokenAuth: auth.isToken, basicAuth: auth.username, password: auth.secret
        )
        guard status == 200,
              let envelope = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let calls = envelope["methodResponses"] as? [[Any]],
              let args = calls.first?[1] as? [String: Any],
              let ids = args["ids"] as? [String],
              let id = ids.first, !id.isEmpty else {
            throw JMAPSyncError.protocolError("Mailbox/query for \(name) answered no id")
        }
        return id
    }

    /// Destroys every seeded email id the test created, by Email/changes
    /// + Email/set destroy. Read-only sync stays read-only: the fixture
    /// cleans up only messages it itself imported.
    static func destroySeeded(ids: [String], client: JMAPHTTPClient, auth: JMAPAuth, accountId: String) async throws {
        guard !ids.isEmpty else { return }
        let call: [String: Any] = [
            "using": ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail"],
            "methodCalls": [["Email/set", [
                "accountId": accountId, "destroy": ids,
            ], "c0"]],
        ]
        let request = try JSONSerialization.data(withJSONObject: call)
        let (status, _) = try await client.send(
            "POST", URL(string: apiUrl, relativeTo: baseURL)!, body: request,
            tokenAuth: auth.isToken, basicAuth: auth.username, password: auth.secret
        )
        guard status == 200 else {
            throw JMAPSyncError.transportFailed(status, "Email/set destroy answered \(status)")
        }
    }

    /// RFC 5322 bytes for a seeded message; obviously fake test data.
    static func message(_ subject: String) -> Data {
        Data("""
        From: alice@example.com\r
        To: bob@example.org\r
        Subject: \(subject)\r
        Date: Tue, 25 Nov 2026 10:00:00 +0000\r
        Message-ID: <\(subject.replacingOccurrences(of: " ", with: "-"))@example.com>\r
        \r
        Body of \(subject).\r
        """.utf8)
    }

    static var apiUrl: String { "jmap/" }
}
