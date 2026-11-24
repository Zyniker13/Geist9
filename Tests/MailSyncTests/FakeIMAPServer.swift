// The scriptable fake IMAP server used by the sync-engine tests (TESTING,
// "Quirk replay" row and "Servers we test with"). It runs a real TCP server
// on a loopback high port driven by swift-nio-imap's own `IMAPServerHandler`
// (the library's server-side protocol codec), so the engine is tested
// against the real wire protocol end to end — commands parsed by the same
// parser a production server would use, responses encoded by the same
// encoder. The scenario (which folders exist, which messages, what fails)
// is scripted per test; nothing here touches a real account.

import Foundation
import IMAPCommands
import NIOIMAP
import NIOCore
import NIOPosix

/// One message the fake server holds in one folder.
struct FakeMessage {
    var uid: UInt32
    /// The exact bytes a UID FETCH BODY.PEEK[] returns.
    var data: Data
    /// INTERNALDATE components (UTC).
    var date: (year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) =
        (2026, 1, 1, 12, 0, 0)
    var flags: [String] = []
    // Gmail labels (X-GM-LABELS) the message carries, when the fake plays
    // the Gmail extension.
    var gmLabels: [String] = []
}

/// One folder the fake server exposes.
struct FakeFolder {
    var name: String
    var messages: [FakeMessage]
    var uidValidity: UInt32
    /// SPECIAL-USE attributes the LIST response reports (RFC 6154),
    /// e.g. ["\\Sent"] — used by the localized-folders quirk replay.
    var specialUse: [String] = []
}

/// What the fake server does on one command. Beyond the plain protocol
/// behavior, a scenario can refuse or misbehave per test (quirk replay).
struct FakeServerScenario: Sendable {
    var folders: [FakeFolder] = [FakeFolder(name: "INBOX", messages: [], uidValidity: 1)]
    /// Accept this user/password pair only.
    var user: String = "alice@example.com"
    var password: String = "secret"
    /// Fail every LOGIN with NO (quirk: wrong credentials).
    var loginFails: Bool = false
    /// Flaky-auth replay (Comcast/Xfinity): the first N LOGIN attempts get
    /// NO regardless of credentials; a later one succeeds. Zero = off.
    var failFirstLogins: Int = 0
    /// Close the connection right after this many commands (quirk: mid-pass BYE).
    var disconnectAfterCommands: Int? = nil
    /// Folders whose STATUS gets a NO reply (quirk: server-side folder problem).
    var failStatusFor: Set<String> = []
    /// Status items the server refuses (e.g. GreenMail rejects HIGHESTMODSEQ
    /// without CONDSTORE): any STATUS whose request includes one gets a
    /// tagged NO naming the first refused item, exactly like a real server.
    var refuseStatusItems: Set<String> = []
    // 163/126 (PROVIDERS row 8): the first SELECT without a prior RFC 2971
    // ID in the same session is refused ("Unsafe Login"); after ID it works.
    var refuseSelectBeforeID: Bool = false
    /// XOAUTH2 fixtures: the access tokens this server accepts, and the
    /// SASL body each authenticated user must carry. When non-empty, LOGIN
    /// is refused (the server offers only AUTH=XOAUTH2) — the OAuth-on-IMAP
    /// scenario.
    var acceptedAccessTokens: Set<String> = []
    var xoauth2User: String? = nil
}

/// A running fake server. Bind on 127.0.0.1 port 0, read back the port.
/// The scenario is shared mutable state with the per-connection handler:
/// the lock guards the folders box, `updateFolders` swaps mid-test between
/// passes exactly the way a real server's content changes between passes.
final class FakeIMAPServer: @unchecked Sendable {
    private let lock = NSLock()
    private var folders: [FakeFolder]
    private var scenario: FakeServerScenario
    private var commands: [String] = []
    private var group: EventLoopGroup?
    private var channel: Channel?
    private(set) var port: UInt16 = 0

    init(scenario: FakeServerScenario) {
        self.folders = scenario.folders
        self.scenario = scenario
    }

    /// Make the server reject every login (test scripts a wrong password).
    func setLoginFails(_ fails: Bool) {
        lock.lock(); defer { lock.unlock() }
        self.scenario.loginFails = fails
    }

    /// Swap the folder contents between sync passes.
    func updateFolders(_ folders: [FakeFolder]) {
        lock.lock(); defer { lock.unlock() }
        self.folders = folders
        self.scenario.folders = folders
    }

    /// Change the scripted disconnect point between passes (a test that
    /// replays "Yahoo dropped me once" then lets the retry finish).
    func setDisconnectAfterCommands(_ limit: Int?) {
        lock.lock(); defer { lock.unlock() }
        self.scenario.disconnectAfterCommands = limit
    }

    /// Commands the server processed, for assertions (read-only commands
    /// only ever expected; a STORE or EXPUNGE in this list fails the test).
    var seenCommands: [String] {
        lock.lock(); defer { lock.unlock() }
        return commands
    }

    func start() throws {
        lock.lock()
        let scenario = self.scenario
        lock.unlock()
        // The bind runs on its own worker thread with a deadline: a
        // `.wait()` on the cooperative pool can wedge every concurrent
        // test (see NonBlockingTestBootstrap), so nothing here parks the
        // pool, and a stuck bind fails the start instead of hanging it.
        // The bootstrap is built inside the worker closure: NIO types are
        // not Sendable and must not cross the thread boundary.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        self.group = group
        let recorder = self
        let channel = try NonBlockingTestBootstrap.bind({
            let bind = try ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 16)
                .childChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
                .childChannelInitializer { channel -> EventLoopFuture<Void> in
                    let handler = CommandRecorderHandler(scenario: scenario, server: recorder)
                    return channel.pipeline.addHandlers([
                        ByteToMessageHandler(FrameDecoder()),
                        IMAPServerHandler(),
                        handler,
                    ])
                }
                .bind(to: SocketAddress(ipAddress: "127.0.0.1", port: 0))
            return bind
        }, timeout: 10)
        self.channel = channel
        self.port = UInt16(channel.localAddress!.port!)
    }

    func stop() {
        // Non-blocking teardown (same pattern as OAuthTestServer.stop):
        // firing the async close/shutdown from a `defer` returns at once
        // instead of parking the cooperative pool on the event loops it
        // must spawn — the wedge that once hung whole parallel runs.
        self.channel?.close(promise: nil)
        self.channel = nil
        self.group?.shutdownGracefully { _ in }
        self.group = nil
    }

    fileprivate func record(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        commands.append(name)
    }

    /// Swaps the scenario mid-test: the next command (or connection) sees
    /// the new state, the way a real server's state changes over time.
    func updateScenario(_ mutate: @Sendable (inout FakeServerScenario) -> Void) {
        lock.lock(); defer { lock.unlock() }
        mutate(&self.scenario)
    }

    /// Snapshot for handlers: folders + scenario under the lock.
    fileprivate func snapshot() -> (FakeServerScenario, [FakeFolder]) {
        lock.lock(); defer { lock.unlock() }
        var scenario = self.scenario
        scenario.folders = self.folders
        return (scenario, self.folders)
    }
}

/// The fake server's brain: reads `CommandStreamPart`s from the pipeline,
/// answers with `Response`s through the same encoder a real server uses.
final class CommandRecorderHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = CommandStreamPart
    typealias OutboundIn = Response
    typealias OutboundOut = Response

    /// The handler pulls a fresh scenario+folders snapshot per command, so
    /// a test that swaps folder contents between passes is visible to the
    /// next connection (and mid-connection).
    private let server: FakeIMAPServer
    private var commandsSeen = 0
    private var loggedIn = false
    private var sentID = false
    /// Remaining flaky-auth rejections, decrementing per LOGIN (seeded from
    /// the scenario this connection was created with).
    private var failFirstLoginsRemaining = 0
    private var selected: String?
    private var byID: [String: FakeFolder] = [:]
    /// When set: an `AUTHENTICATE` sent the SASL failure report as a
    /// continuation request under this tag and is now waiting for the
    /// client's SASL termination (a bare base64 continuation-response
    /// line) before sending the tagged completion — the exchange real
    /// servers (Gmail, Yahoo) run per RFC 7628 §3.2.4.
    private var pendingRejectTag: String?

    init(scenario: FakeServerScenario, server: FakeIMAPServer) {
        self.server = server
        self.failFirstLoginsRemaining = scenario.failFirstLogins
        for folder in scenario.folders {
            self.byID[folder.name] = folder
        }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        // The handler receives encoded bytes to forward; nothing to do.
        context.write(data, promise: promise)
    }

    func channelActive(context: ChannelHandlerContext) {
        // A real server's first bytes are the greeting ("* OK ..."), and
        // IMAPConnection waits for exactly that before anything else. The
        // library's `IMAPServerHandler` does not send it, so the fake does.
        self.emit(context, .untagged(.conditionalState(.ok(ResponseText(
            code: .capability([.imap4rev1, .id, .idle]),
            text: "FakeIMAP ready"
        )))))
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = self.unwrapInboundIn(data)
        // The client's SASL termination line after a failure report
        // arrives as a continuation-response part (the parser stays in
        // `.expectingAuthenticationResponse`); a rejected AUTHENTICATE
        // completes only once that line is in.
        if case .continuationResponse = part, let tag = self.pendingRejectTag {
            self.pendingRejectTag = nil
            self.no(context, tag, "AUTHENTICATE failed")
            return
        }
        guard case .tagged(let command) = part else { return }
        self.commandsSeen += 1
        let tag = String(describing: command.tag)
        let name = self.commandName(command.command)
        self.server.record(name)
        let (scenario, folders) = self.server.snapshot()
        for folder in folders {
            self.byID[folder.name] = folder
        }
        self.handle(command.command, tag: tag, scenario: scenario, context: context)
        // Optional scripted misbehavior.
        if let limit = scenario.disconnectAfterCommands, self.commandsSeen >= limit {
            context.close(promise: nil)
        }
    }

    private func commandName(_ command: Command) -> String {
        switch command {
        case .capability: return "CAPABILITY"
        case .login: return "LOGIN"
        case .id: return "ID"
        case .list: return "LIST"
        case .select: return "SELECT"
        case .examine: return "EXAMINE"
        case .status: return "STATUS"
        case .uidFetch: return "UID FETCH"
        case .uidSearch: return "UID SEARCH"
        case .fetch: return "FETCH"
        case .idleStart: return "IDLE"
        case .logout: return "LOGOUT"
        case .noop: return "NOOP"
        case .enable: return "ENABLE"
        case .store: return "STORE"
        case .uidStore: return "UID STORE"
        case .expunge: return "EXPUNGE"
        case .uidExpunge: return "UID EXPUNGE"
        case .copy: return "COPY"
        case .uidCopy: return "UID COPY"
        case .move: return "MOVE"
        case .uidMove: return "UID MOVE"
        case .create: return "CREATE"
        case .delete: return "DELETE"
        case .rename: return "RENAME"
        case .subscribe: return "SUBSCRIBE"
        case .unsubscribe: return "UNSUBSCRIBE"
        case .close: return "CLOSE"
        case .unselect: return "UNSELECT"
        case .startTLS: return "STARTTLS"
        case .check: return "CHECK"
        case .namespace: return "NAMESPACE"
        case .lsub: return "LSUB"
        case .listIndependent: return "LIST (INDEPENDENT)"
        case .uidBatches: return "UID BATCHES"
        case .getQuota: return "GETQUOTA"
        case .getQuotaRoot: return "GETQUOTAROOT"
        case .setQuota: return "SETQUOTA"
        case .getMetadata: return "GETMETADATA"
        case .setMetadata: return "SETMETADATA"
        case .extendedSearch: return "ESEARCH"
        case .resetKey: return "RESETKEY"
        case .generateAuthorizedURL: return "GENURLAUTH"
        case .urlFetch: return "URLFETCH"
        case .compress: return "COMPRESS"
        case .getJMAPAccess: return "GETJMAPACCESS"
        case .custom: return "CUSTOM"
        case .authenticate: return "AUTHENTICATE"
        case .search: return "SEARCH"
        case .sort: return "SORT"
        case .uidSort: return "UID SORT"
        }
    }

    private func emit(_ context: ChannelHandlerContext, _ response: Response) {
        context.writeAndFlush(self.wrapOutboundOut(response), promise: nil)
    }

    private func ok(_ context: ChannelHandlerContext, _ tag: String, _ text: String) {
        guard let tagValue = Command.Tag(tag) else { return }
        self.emit(context, .tagged(TaggedResponse(
            tag: tagValue,
            state: .ok(ResponseText(code: nil, text: text))
        )))
    }

    private func no(_ context: ChannelHandlerContext, _ tag: String, _ text: String) {
        guard let tagValue = Command.Tag(tag) else { return }
        self.emit(context, .tagged(TaggedResponse(
            tag: tagValue,
            state: .no(ResponseText(code: nil, text: text))
        )))
    }

    private func handle(
        _ command: Command, tag: String, scenario: FakeServerScenario,
        context: ChannelHandlerContext
    ) {
        switch command {
        case .capability:
            self.emit(context, .untagged(.capabilityData([.imap4rev1, .id, .idle])))
            self.ok(context, tag, "CAPABILITY completed")
        case .login(let user, let password):
            if scenario.failFirstLogins > 0 {
                self.failFirstLoginsRemaining -= 1
                self.no(context, tag, "LOGIN failed")
            } else if !scenario.acceptedAccessTokens.isEmpty {
                // OAuth-only server: LOGIN is refused outright (Gmail with
                // app passwords disabled for the account, Yahoo OAuth).
                self.no(context, tag, "LOGIN: use AUTHENTICATE XOAUTH2")
            } else if scenario.loginFails || user != scenario.user || password != scenario.password {
                self.no(context, tag, "LOGIN failed")
            } else {
                self.loggedIn = true
                self.ok(context, tag, "LOGIN completed")
            }
        case .id:
            self.sentID = true
            self.emit(context, .untagged(.id(["name": "FakeIMAP", "version": "1.0"])))
            self.ok(context, tag, "ID completed")
        case .authenticate(let mechanism, let initialResponse):
            self.handleAuthenticate(mechanism, initialResponse, tag: tag, scenario: scenario, context: context)
        case .list(_, _, _, _):
            for folder in scenario.folders {
                let name = MailboxName(Array(folder.name.utf8))
                let path = try! MailboxPath(name: name, pathSeparator: "/")
                var attrs: [MailboxInfo.Attribute] = [.hasNoChildren]
                for use in folder.specialUse {
                    if let attribute = MailboxInfo.Attribute(use) {
                        attrs.append(attribute)
                    }
                }
                let info = MailboxInfo(
                    attributes: attrs,
                    path: path,
                    objectID: nil,
                    extensions: [:]
                )
                self.emit(context, .untagged(.mailboxData(.list(info))))
            }
            self.ok(context, tag, "LIST completed")
        case .status(let mailbox, let attributes):
            let name = String(decoding: mailbox.bytes, as: UTF8.self)
            if scenario.failStatusFor.contains(name) {
                self.no(context, tag, "STATUS failed (scripted)")
                return
            }
            let refused = scenario.refuseStatusItems
            if let first = attributes.first(where: { refused.contains($0.rawValue) }) {
                self.no(context, tag, "Unknown status item: '\(first.rawValue)'")
                return
            }
            guard let folder = self.byID[name] else {
                self.no(context, tag, "Mailbox does not exist")
                return
            }
            var status = MailboxStatus()
            if attributes.contains(.uidValidity) {
                status.uidValidity = UIDValidity(exactly: folder.uidValidity)
            }
            if attributes.contains(.highestModificationSequence) {
                status.highestModificationSequence = ModificationSequenceValue(0)
            }
            if attributes.contains(.messageCount) {
                status.messageCount = folder.messages.count
            }
            self.emit(context, .untagged(.mailboxData(.status(mailbox, status))))
            self.ok(context, tag, "STATUS completed")
        case .select(let mailbox, _):
            // 163's documented rule: no ID in this session yet → refuse
            // SELECT ("Unsafe Login"); once ID has been sent, it works.
            if scenario.refuseSelectBeforeID && !self.sentID {
                self.no(context, tag, "Unsafe Login. Please contact us for more info")
                return
            }
            let name = String(decoding: mailbox.bytes, as: UTF8.self)
            guard let folder = self.byID[name], folder.name != "" else {
                self.no(context, tag, "Mailbox does not exist")
                return
            }
            self.selected = name
            self.emit(context, .untagged(.mailboxData(.exists(folder.messages.count))))
            self.emit(context, .untagged(.conditionalState(.ok(ResponseText(
                code: .uidValidity(UIDValidity(exactly: folder.uidValidity)!),
                text: "SELECT completed"
            )))))
            self.ok(context, tag, "SELECT completed")
        case .uidFetch(let set, let attributes, _):
            guard self.loggedIn, self.selected != nil else {
                self.no(context, tag, "No mailbox selected")
                return
            }
            let folder = self.byID[self.selected!]!
            let wantsBody = attributes.contains(where: {
                if case .bodySection = $0 { return true }
                return false
            })
            let wantsUID = attributes.contains(.uid)
            let wantsInternalDate = attributes.contains(.internalDate)
            // The set is a real UID range unless the client asked for "$"
            // (SEARCH result), which this fake never sees from the engine.
            // RFC 3501 §6.4.8: a range whose lower bound exceeds the folder's
            // highest UID still matches the LAST message ("*"): real servers
            // (GreenMail) answer a stale "n:*" with the final message, so the
            // fake must reproduce that or a wrap-driven bug hides.
            let wantedUIDs: Set<UInt32>
            switch set {
            case .set(let nonEmpty):
                let folderMax = folder.messages.map { $0.uid }.max() ?? 0
                var matched = Set<UInt32>(
                    folder.messages.map { $0.uid }.filter {
                        nonEmpty.set.contains(UID(rawValue: $0))
                    }
                )
                let lower = nonEmpty.set.min()?.rawValue ?? 0
                if folderMax > 0, lower > folderMax, let last = folder.messages.map({ $0.uid }).max() {
                    matched.insert(last)
                }
                wantedUIDs = matched
            case .lastCommand:
                wantedUIDs = Set(folder.messages.map { $0.uid })
            }
            for message in folder.messages.sorted(by: { $0.uid < $1.uid })
            where wantedUIDs.contains(message.uid) {
                self.emit(context, .fetch(.start(SequenceNumber(1))))
                if wantsUID {
                    self.emit(context, .fetch(.simpleAttribute(.uid(UID(rawValue: message.uid)))))
                }
                if wantsInternalDate {
                    self.emit(context, .fetch(.simpleAttribute(.internalDate(Self.internalDate(message)))))
                }
                if wantsUID, !message.gmLabels.isEmpty {
                    // Gmail X-GM-EXT-1: the labels attribute as Gmail sends it.
                    let labels = message.gmLabels.map { GmailLabel(ByteBufferAllocator().buffer(string: $0)) }
                    self.emit(context, .fetch(.simpleAttribute(.gmailLabels(labels))))
                }
                if wantsBody {
                    var buffer = ByteBufferAllocator().buffer(capacity: message.data.count)
                    buffer.writeBytes(message.data)
                    self.emit(context, .fetch(.streamingBegin(kind: .body(section: .complete, offset: nil), byteCount: message.data.count)))
                    self.emit(context, .fetch(.streamingBytes(buffer)))
                    self.emit(context, .fetch(.streamingEnd))
                }
                self.emit(context, .fetch(.finish))
            }
            self.ok(context, tag, "UID FETCH completed")
        case .uidSearch:
            guard self.loggedIn, self.selected != nil else {
                self.no(context, tag, "No mailbox selected")
                return
            }
            let folder = self.byID[self.selected!]!
            let ids = folder.messages.map { UnknownMessageIdentifier(UID(rawValue: $0.uid)) }
            self.emit(context, .untagged(.mailboxData(.search(ids))))
            self.ok(context, tag, "UID SEARCH completed")
        case .logout:
            self.ok(context, tag, "LOGOUT completed")
        case .idleStart:
            // Accept IDLE; the engine never uses it in these tests.
            self.ok(context, tag, "IDLE terminated")
        default:
            // Anything that would mutate the server is refused loudly: the
            // engine must never send it. (The test asserts the recorded
            // command list contains no mutating command.)
            self.no(context, tag, "read-only test server: command not supported")
        }
    }

    /// SASL XOAUTH2 (RFC 7628): the engine sends AUTHENTICATE with the
    /// base64 body `user=…\x01auth=Bearer …\x01\x01` as the initial
    /// response. A valid token answers tagged OK; an invalid one answers
    /// the RFC 7628 §3.2.4 failure report as a continuation request, then
    /// reads the client's empty-line termination and answers tagged NO.
    /// This mirrors what Gmail and Yahoo actually do on the wire.
    private func handleAuthenticate(
        _ mechanism: AuthenticationMechanism,
        _ initialResponse: InitialResponse?,
        tag: String,
        scenario: FakeServerScenario,
        context: ChannelHandlerContext
    ) {
        guard mechanism == AuthenticationMechanism("XOAUTH2") else {
            self.no(context, tag, "unsupported mechanism")
            return
        }
        guard let initialResponse else {
            // No SASL-IR: the real servers expect it; refuse plainly.
            self.no(context, tag, "SASL-IR required")
            return
        }
        // The client's SASL-IR: `parseBase64` already decoded it, so
        // `initialResponse.data` holds the raw `user=…\x01auth=Bearer …`
        // bytes — decode nothing here.
        var body = initialResponse.data
        let text = body.readString(length: body.readableBytes) ?? ""
        // Parse user=…\x01auth=Bearer …\x01\x01.
        let fields = text.components(separatedBy: "\u{01}")
        var user: String?
        var token: String?
        for field in fields {
            if field.hasPrefix("user=") { user = String(field.dropFirst(5)) }
            if field.hasPrefix("auth=Bearer ") { token = String(field.dropFirst(12)) }
        }
        if let user = user, user == (scenario.xoauth2User ?? scenario.user),
           let token = token, scenario.acceptedAccessTokens.contains(token) {
            self.loggedIn = true
            self.ok(context, tag, "AUTHENTICATE completed")
            return
        }
        // The failure report: a `+ <base64>` continuation (RFC 7628
        // §3.2.4). The server then waits for the client's empty-line SASL
        // termination before sending the tagged NO — matching Gmail and
        // Yahoo. The encoder base64s the bytes it is handed, so give it
        // the raw JSON.
        let report = "{\"status\":\"401\",\"schemes\":\"bearer\",\"scope\":\"https://mail.example.com/read\"}"
        self.pendingRejectTag = tag
        self.emit(context, .authenticationChallenge(ByteBuffer(string: report)))
    }

    /// The fake's fixed INTERNALDATE (2026-01-01 12:00:00 UTC) as a
    /// `ServerMessageDate` via the library's own component encoding.
    private static func internalDate(_ message: FakeMessage) -> ServerMessageDate {
        let c = ServerMessageDate.Components(
            year: message.date.year, month: message.date.month, day: message.date.day,
            hour: message.date.hour, minute: message.date.minute, second: message.date.second,
            timeZoneMinutes: 0
        )!
        return ServerMessageDate(c)
    }
}
