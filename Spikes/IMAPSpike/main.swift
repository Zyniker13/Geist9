import IMAPCommands
import NIOIMAP
import NIOCore
import Foundation

// M0 spike: drive swift-nio-imap 0.5.0 against a local test server
// (Dovecot, GreenMail; Stalwart bring-up is parked, see docs/spikes/imap-client.md).
//
// Usage:
//   IMAP_HOST=127.0.0.1 IMAP_PORT=3143 IMAP_USER=alice@example.com \
//   IMAP_PASS=testpass swift run IMAPSpike
//
// Prints one PASS/FAIL/SKIP line per step and exits 0 only if every step
// that ran passed. QRESYNC steps SKIP when the server does not advertise it.

let env = ProcessInfo.processInfo.environment
let host = env["IMAP_HOST"] ?? "127.0.0.1"
let port = UInt16(env["IMAP_PORT"] ?? "3143") ?? 3143
let user = env["IMAP_USER"] ?? "alice@example.com"
let pass = env["IMAP_PASS"] ?? "testpass"
let useTLS = (env["IMAP_TLS"] ?? "0") == "1"

// Throwaway spike, strictly sequential: plain mutable counters are fine here.
nonisolated(unsafe) var passed = 0
nonisolated(unsafe) var failed = 0
nonisolated(unsafe) var skipped = 0

func report(_ name: String, _ ok: Bool, _ detail: String = "", skip: Bool = false) {
    if skip {
        skipped += 1
        print("SKIP \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    } else if ok {
        passed += 1
        print("PASS \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    } else {
        failed += 1
        print("FAIL \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    }
}

func mailboxName(_ s: String) -> MailboxName {
    MailboxName(Array(s.utf8))
}

func nameString(_ name: MailboxName) -> String {
    String(decoding: name.bytes, as: UTF8.self)
}

let testMessageBody = """
From: alice@example.com
To: bob@example.org
Subject: IMAPSpike test message
Date: Mon, 17 Nov 2026 00:00:00 -0500
Message-ID: <spike-0001@example.com>
MIME-Version: 1.0
Content-Type: text/plain; charset=utf-8

Body of the IMAP spike test message.

"""

// IMAP requires CRLF line endings; appending bare LF gets normalized by
// servers, which would defeat the byte-exact round-trip check below.
let testMessage = testMessageBody.replacingOccurrences(of: "\n", with: "\r\n")
let testMessageData = testMessage.data(using: .utf8)!

let config = IMAPConnection.Configuration(
    hostname: host,
    port: port,
    useTLS: useTLS,
    logging: .noLogging
)

do {
    try await IMAPConnection.withConnection(configuration: config) { greeting, connection in
        // 1. Greeting.
        var greetingOK = false
        switch greeting.status {
        case .ok: greetingOK = true
        default: break
        }
        report("greeting", greetingOK)

        // 2. CAPABILITY.
        var caps: [String] = []
        var capTagged: TaggedResponse?
        try await connection.send(.capability) { _, stream in
            for try await response in stream {
                switch response {
                case .untagged(.capabilityData(let list)):
                    caps.append(contentsOf: list.map { "\($0.name)\($0.value.map { "=\($0)" } ?? "")" })
                case .tagged(let t):
                    capTagged = t
                default:
                    break
                }
            }
        }
        var capOK = false
        if case .ok = capTagged?.state { capOK = true }
        let capSet = Set(caps)
        report("capability", capOK, caps.sorted().joined(separator: " "))

        // 3. LOGIN.
        var loginOK = false
        try await connection.send(.login(username: user, password: pass)) { _, stream in
            for try await response in stream {
                if case .tagged(let t) = response {
                    if case .ok = t.state { loginOK = true }
                }
            }
        }
        report("login", loginOK)

        // 4. ID (RFC 2971) — some providers (163) require it before SELECT;
        // servers without the extension reply NO/BAD and stay up.
        var idOK = false
        var idServer = ""
        var idUnsupported = false
        try await connection.send(.id(["name": "Bristlecone", "version": "0.1.0"])) { _, stream in
            for try await response in stream {
                switch response {
                case .untagged(.id(let dict)):
                    idServer = dict.map { "\($0.key)=\($0.value ?? "")" }.sorted().joined(separator: " ")
                    idOK = true
                case .tagged(let t):
                    switch t.state {
                    case .ok: idOK = true
                    case .no(let rt): idUnsupported = true; idServer = "NO: \(rt.text)"
                    case .bad(let rt): idUnsupported = true; idServer = "BAD: \(rt.text)"
                    }
                default:
                    break
                }
            }
        }
        report("id", idOK, idServer, skip: idUnsupported)

        // 5. LIST.
        var mailboxes: [String] = []
        var listOK = false
        try await connection.send(
            .list(nil, reference: mailboxName(""), .mailbox(ByteBuffer(string: "*")), [])
        ) { _, stream in
            for try await response in stream {
                switch response {
                case .untagged(.mailboxData(.list(let info))):
                    mailboxes.append(nameString(info.path.name))
                case .tagged(let t):
                    if case .ok = t.state { listOK = true }
                default:
                    break
                }
            }
        }
        report("list", listOK, mailboxes.sorted().joined(separator: ", "))

        // 6. ENABLE QRESYNC (only when the server advertises it).
        let serverHasQresync = capSet.contains("QRESYNC")
        var enableOK = false
        var enabledCaps: [String] = []
        if serverHasQresync {
            try await connection.send(.enable([.qresync])) { _, stream in
                for try await response in stream {
                    switch response {
                    case .untagged(.enableData(let list)):
                        enabledCaps.append(contentsOf: list.map { "\($0.name)\($0.value.map { "=\($0)" } ?? "")" })
                    case .tagged(let t):
                        if case .ok = t.state { enableOK = true }
                    default:
                        break
                    }
                }
            }
            report("enable-qresync", enableOK, enabledCaps.sorted().joined(separator: " "))
        } else {
            report("enable-qresync", true, "server does not advertise QRESYNC", skip: true)
        }

        // 7. SELECT INBOX, with a QRESYNC parameter when enabled.
        var exists: Int?
        var uidValidity: String?
        var modseq: String?
        var selectOK = false
        let selectCommand: Command = serverHasQresync && enableOK
            ? .select(
                mailboxName("INBOX"),
                [.qresync(QResyncParameter(
                    uidValidity: 1,
                    modificationSequenceValue: 1,
                    knownUIDs: nil,
                    sequenceMatchData: nil
                ))]
            )
            : .select(mailboxName("INBOX"))
        try await connection.send(selectCommand) { _, stream in
            for try await response in stream {
                switch response {
                case .untagged(.mailboxData(.exists(let n))):
                    exists = n
                case .untagged(.conditionalState(let status)):
                    let text = "\(status)"
                    if text.contains("UIDVALIDITY") { uidValidity = text }
                    if text.contains("MODSEQ") { modseq = text }
                case .tagged(let t):
                    if case .ok = t.state { selectOK = true }
                default:
                    break
                }
            }
        }
        var selectDetail = "exists=\(exists.map(String.init) ?? "?")"
        if let u = uidValidity { selectDetail += " \(u)" }
        if let m = modseq { selectDetail += " \(m)" }
        report("select", selectOK, selectDetail)

        // 8. APPEND a test message.
        var appendOK = false
        try await connection.append(to: mailboxName("INBOX")) { _, stream, writer in
            let message = AppendMessage(
                options: .none,
                data: AppendData(byteCount: testMessageData.count)
            )
            try await writer.write(message: message) { w in
                try await w.write(messageBytes: ByteBuffer(bytes: testMessageData))
            }
            try await writer.finish()
            for try await response in stream {
                if case .tagged(let t) = response {
                    if case .ok = t.state { appendOK = true }
                }
            }
        }
        report("append", appendOK)

        // 9. UID FETCH envelope and size for all messages.
        var subjects: [String] = []
        var sizesByUID: [UInt32: Int] = [:]
        var metaUID: UInt32?
        var fetchOK = false
        try await connection.send(
            .uidFetch(
                LastCommandSet<UID>.range(
                    MessageIdentifierRange<UID>(UID(rawValue: 1)...UID(rawValue: UInt32.max))
                ),
                [.envelope, .uid, .rfc822Size],
                []
            )
        ) { _, stream in
            for try await response in stream {
                switch response {
                case .fetch(.simpleAttribute(let attr)):
                    switch attr {
                    case .envelope(let env):
                        if let subject = env.subject {
                            subjects.append(String(buffer: subject))
                        }
                    case .uid(let uid):
                        metaUID = UInt32(uid)
                    case .rfc822Size(let size):
                        if let u = metaUID { sizesByUID[u] = size }
                    default:
                        break
                    }
                case .fetch(.finish):
                    metaUID = nil
                case .tagged(let t):
                    if case .ok = t.state { fetchOK = true }
                default:
                    break
                }
            }
        }
        report(
            "fetch-metadata",
            fetchOK && !subjects.isEmpty,
            "count=\(subjects.count) sizes=\(sizesByUID.values.sorted().map(String.init).joined(separator: ",")) subjects=\(subjects.joined(separator: " | "))"
        )

        // 10. UID SEARCH ALL.
        var searchedUIDs: [UInt32] = []
        var searchOK = false
        try await connection.send(.uidSearch(key: .all)) { _, stream in
            for try await response in stream {
                switch response {
                case .untagged(.mailboxData(.search(let ids, _))):
                    searchedUIDs.append(contentsOf: ids.map { UInt32($0) })
                case .tagged(let t):
                    if case .ok = t.state { searchOK = true }
                default:
                    break
                }
            }
        }
        report("uid-search", searchOK, "count=\(searchedUIDs.count)")

        // 11. UID FETCH BODY.PEEK[] streaming every message to disk.
        let streamDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("imapspike-\(port)", isDirectory: true)
        try? FileManager.default.createDirectory(at: streamDir, withIntermediateDirectories: true)
        var streamedFiles: [String] = []
        var streamSizes: [Int] = []
        var bodyStreamOK = false
        var streamError = ""
        var matched = false
        var sizeMismatch = ""
        do {
            var currentBytes = Data()
            var currentExpected = 0
            var currentUID: UInt32?
            try await connection.send(
                .uidFetch(
                    LastCommandSet<UID>.range(
                        MessageIdentifierRange<UID>(UID(rawValue: 1)...UID(rawValue: UInt32.max))
                    ),
                    [.uid, .bodySection(peek: true, .complete, nil)],
                    []
                )
            ) { _, stream in
                for try await response in stream {
                    switch response {
                    case .fetch(.simpleAttribute(.uid(let uid))):
                        currentUID = UInt32(uid)
                    case .fetch(.streamingBegin(_, let byteCount)):
                        currentBytes = Data()
                        currentExpected = byteCount
                    case .fetch(.streamingBytes(let buffer)):
                        var b = buffer
                        currentBytes.append(contentsOf: b.readBytes(length: b.readableBytes) ?? [])
                    case .fetch(.streamingEnd):
                        if currentBytes.count == currentExpected, let uid = currentUID {
                            let file = streamDir.appendingPathComponent("uid-\(uid).eml")
                            try currentBytes.write(to: file)
                            streamedFiles.append(file.lastPathComponent)
                            streamSizes.append(currentBytes.count)
                            if currentBytes == testMessageData { matched = true }
                            if let reported = sizesByUID[uid], reported != currentBytes.count {
                                sizeMismatch = "uid \(uid): rfc822Size=\(reported) streamed=\(currentBytes.count)"
                            }
                        }
                        currentUID = nil
                        currentBytes = Data()
                    case .tagged(let t):
                        if case .ok = t.state { bodyStreamOK = true }
                        if case .no(let rt) = t.state { streamError = "NO: \(rt.text)" }
                        if case .bad(let rt) = t.state { streamError = "BAD: \(rt.text)" }
                    default:
                        break
                    }
                }
            }
        } catch {
            streamError = "\(error)"
        }
        let filesOK = !streamedFiles.isEmpty && streamedFiles.count == streamSizes.count
        report(
            "body-peek-stream",
            bodyStreamOK && filesOK && matched && streamError.isEmpty && sizeMismatch.isEmpty,
            "files=\(streamedFiles.count) sizes=\(streamSizes) sizeMismatch=\(sizeMismatch.isEmpty ? "none" : sizeMismatch) error=\(streamError.isEmpty ? "none" : streamError)"
        )

        // 12. IDLE for two seconds, then DONE.
        var idleOK = false
        try await connection.sendIdle { _, stream in
            // Returning ends the IDLE (DONE is sent by the library). Consume nothing: no
            // mail arrives during the window, and the deadline check must not depend on a
            // response arriving.
            _ = stream
            try await Task.sleep(for: .seconds(2))
            idleOK = true
        }
        report("idle", idleOK)

        // 13. LOGOUT.
        var logoutOK = false
        try await connection.send(.logout) { _, stream in
            for try await response in stream {
                if case .tagged(let t) = response {
                    if case .ok = t.state { logoutOK = true }
                }
            }
        }
        report("logout", logoutOK)
    }
} catch {
    report("connection", false, "\(error)")
}

print("IMAPSpike: \(passed) passed, \(failed) failed, \(skipped) skipped")
exit(failed == 0 ? 0 : 1)
