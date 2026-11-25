// The interactive OAuth sign-in flow (DESIGN 4 "OAuth Flow"): build the
// authorize URL, hand it to the browser seam, receive the redirect on a
// loopback listener, validate `state`, and exchange the code with PKCE.
// Tested in Tests/MailSyncTests/OAuthAuthorizeTests.swift against the
// local OAuth test server.

import Foundation
import NIOCore
import NIOPosix

/// A minimal loopback HTTP listener that captures exactly one redirect:
/// `GET <path>?code=…&state=…`. Binds to 127.0.0.1 on a random port (the
/// redirect URI the flow advertises points at it). One-shot by design: a
/// second request is refused, so a stray prefetch or scanner cannot pull
/// the code.
public final class LoopbackRedirectReceiver: @unchecked Sendable {
    public struct Captured: Sendable, Equatable {
        public let code: String?
        public let state: String?
        public let error: String?
    }

    private let lock = NSLock()
    private var channel: Channel?
    private var group: EventLoopGroup?
    private var captured: Captured?
    private var expectation: CheckedContinuation<Captured, Never>?
    private var stopped = false
    private(set) var port: UInt16 = 0
    private let expectedPath: String

    /// - Parameter expectedPath: the path component of the redirect URI.
    public init(expectedPath: String) {
        self.expectedPath = expectedPath
    }

    /// Starts listening on a random loopback port. The redirect URI used
    /// in the authorize request must be `http://127.0.0.1:<port><path>`.
    public func start() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group
        let path = self.expectedPath
        let channel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 4)
            .childChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandlers([
                    RedirectHandler(receiver: self, expectedPath: path),
                ])
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait()
        self.channel = channel
        self.port = UInt16(channel.localAddress!.port!)
    }

    /// Waits for the single redirect the browser delivers, or throws
    /// `.timedOut` when nothing arrives within `timeout` seconds — a user
    /// who never returns to the browser cannot leave the sign-in parked
    /// forever. The capture is judged by the caller, which owns the
    /// expected `state`.
    public func awaitRedirect(timeout: TimeInterval = 300) async throws -> Captured {
        if let existing = self.lock.withLock({ self.captured }) { return existing }
        let receiver = self
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Captured?.self) { group in
                // The wait: parks until deliver() or stop() resumes it,
                // and honours cancellation by ending the park.
                group.addTask { await receiver.waitForCapture() }
                // The deadline: after `timeout` seconds the race is lost
                // and the flow ends instead of parking forever.
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                    return nil
                }
                let first = try await group.next() ?? nil
                group.cancelAll()
                if Task.isCancelled { throw CancellationError() }
                guard let captured = first else {
                    throw OAuthAuthorizeFlowError.timedOut
                }
                return captured
            }
        } onCancel: {
            receiver.stop()
        }
    }

    /// Parks until `deliver` or `stop` resumes the wait. Cancellation
    /// ends the park with an empty capture (through `stop`), so a
    /// cancelled or timed-out flow never leaves a parked waiter behind.
    private func waitForCapture() async -> Captured {
        if let existing = self.lock.withLock({ self.captured }) { return existing }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Captured, Never>) in
                let outcome = self.lock.withLock { () -> ParkOutcome in
                    if let captured = self.captured { return .deliver(captured) }
                    // stop() already ran: no redirect can arrive after it,
                    // so the wait ends at once with an empty capture.
                    if self.stopped { return .stoppedEmpty }
                    self.expectation = continuation
                    return .parked
                }
                switch outcome {
                case .deliver(let captured):
                    continuation.resume(returning: captured)
                case .stoppedEmpty:
                    continuation.resume(returning: Captured(code: nil, state: nil, error: nil))
                case .parked:
                    break
                }
            }
        } onCancel: {
            self.stop()
        }
    }

    /// Stops listening; non-blocking (see OAuthTestServer.stop for why).
    /// A waiter parked in `awaitRedirect` resumes immediately with an
    /// empty capture.
    public func stop() {
        let group = self.lock.withLock { () -> EventLoopGroup? in
            let group = self.group
            self.stopped = true
            self.channel?.close(promise: nil)
            self.channel = nil
            self.group = nil
            if let expectation = self.expectation {
                // A test that abandons the wait still gets a value.
                let empty = Captured(code: nil, state: nil, error: nil)
                self.expectation = nil
                expectation.resume(returning: empty)
            }
            return group
        }
        group?.shutdownGracefully { _ in }
    }

    fileprivate func deliver(_ captured: Captured) {
        let waiting = self.lock.withLock { () -> CheckedContinuation<Captured, Never>? in
            if self.captured == nil { self.captured = captured }
            let waiting = self.expectation
            self.expectation = nil
            return waiting
        }
        waiting?.resume(returning: captured)
    }

    /// What the parked wait resolves to: the redirect's capture, an
    /// already-stopped receiver (empty capture), or a registered park.
    private enum ParkOutcome {
        case deliver(Captured)
        case stoppedEmpty
        case parked
    }

    /// One redirect request, parsed by hand: method line, headers to the
    /// blank line, then nothing (a GET has no body). Answers with a small
    /// HTML page telling the person to return to the app.
    private final class RedirectHandler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer

        private let receiver: LoopbackRedirectReceiver
        private let expectedPath: String
        private var buffer = ByteBuffer()
        private var answered = false

        init(receiver: LoopbackRedirectReceiver, expectedPath: String) {
            self.receiver = receiver
            self.expectedPath = expectedPath
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var chunk = self.unwrapInboundIn(data)
            self.buffer.writeBuffer(&chunk)
            guard !self.answered, let request = Self.parse(&self.buffer) else { return }
            self.answered = true
            let captured = Self.classify(request: request, expectedPath: self.expectedPath)
            self.receiver.deliver(captured)
            let page = "<html><body><p>Sign-in complete. Return to Bristlecone.</p></body></html>"
            let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
                + "Content-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n"
            var out = ByteBufferAllocator().buffer(capacity: head.utf8.count + page.utf8.count)
            out.writeString(head + page)
            context.writeAndFlush(self.wrapOutboundOut(out), promise: nil)
            context.close(promise: nil)
        }

        /// `GET /path?query HTTP/1.1` up to the blank line.
        static func parse(_ buffer: inout ByteBuffer) -> String? {
            // The offset of the first `\r\n\r\n` within the readable
            // region (the same scan the test server does; kept inline so
            // the production target never depends on a test fixture).
            var offset: Int?
            buffer.withUnsafeReadableBytes { raw in
                offset = Data(raw).range(of: Data("\r\n\r\n".utf8))?.lowerBound
            }
            guard let found = offset else { return nil }
            let headerLength = buffer.readerIndex + found + 4 - buffer.readerIndex
            guard let head = buffer.readString(length: headerLength) else { return nil }
            return String(head.prefix(while: { $0 != "\r" && $0 != "\n" }))
        }

        static func classify(request: String, expectedPath: String) -> Captured {
            let parts = request.split(separator: " ")
            guard parts.count >= 2 else { return Captured(code: nil, state: nil, error: nil) }
            let target = String(parts[1])
            guard let question = target.firstIndex(of: "?") else {
                return Captured(code: nil, state: nil, error: nil)
            }
            let path = String(target[..<question])
            guard path == expectedPath else {
                return Captured(code: nil, state: nil, error: "wrong_path")
            }
            let queryString = target[target.index(after: question)...]
            var code: String?
            var state: String?
            var error: String?
            for pair in queryString.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard kv.count == 2 else { continue }
                let name = String(kv[0])
                let value = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                switch name {
                case "code": code = value
                case "state": state = value
                case "error": error = value
                default: break
                }
            }
            return Captured(code: code, state: state, error: error)
        }
    }
}

public enum OAuthAuthorizeFlowError: Error, Equatable {
    /// The provider's redirect carried `error=` (the person declined, or
    /// the request was malformed).
    case providerDeclined(String)
    /// The redirect's `state` did not match what the flow issued.
    case stateMismatch
    /// The redirect never named the path the receiver listens on.
    case wrongRedirect
    /// The receiver heard nothing before the timeout.
    case timedOut
    /// The person closed the browser sheet before any redirect arrived
    /// (the browser was the redirect's only source). A deliberate stop,
    /// not a failure: the sign-in ends with nothing stored.
    case cancelled
    /// The browser sheet could not be shown (no window to present in, or
    /// the session refused to start). The person never saw a consent
    /// screen; nothing to blame on them.
    case browserUnavailable
}

/// Runs one interactive sign-in: fresh PKCE + state, authorize URL, the
/// caller's browser seam opens it, the redirect lands on the receiver,
/// `state` is checked, and the code is exchanged. The browser seam is a
/// closure so the app can drive `ASWebAuthenticationSession` (the app-side
/// adapter is `BrowserSessionOpener`) and tests can drive the local server
/// directly.
///
/// The seam receives a `BrowserSession` handle: the flow cancels it when
/// the sign-in ends (whatever the outcome), so the browser sheet never
/// outlives the exchange; and the person closing the sheet resolves the
/// handle's waiter as `false`, which the flow turns into `.cancelled` —
/// closing the sheet is how a person says "stop", not an error.
public func runAuthorizeFlow(
    authorizeEndpoint: URL,
    configuration: OAuthTokenClient.Configuration,
    client: OAuthTokenClient,
    timeout: TimeInterval = 300,
    openBrowser: @escaping @Sendable (URL, BrowserSession) async -> Void
) async throws -> OAuthTokens {
    let pkce = PKCEPair()
    var stateBytes = [UInt8](repeating: 0, count: 32)
    var rng = SystemRandomNumberGenerator()
    for index in stateBytes.indices {
        var value = rng.next()
        withUnsafeBytes(of: &value) { stateBytes[index] = $0[0] }
    }
    let state = PKCEPair.base64URL(Data(stateBytes))

    guard let redirect = URL(string: configuration.redirectURI) else {
        throw OAuthAuthorizeFlowError.wrongRedirect
    }
    let receiver = LoopbackRedirectReceiver(expectedPath: redirect.path.isEmpty ? "/" : redirect.path)
    try receiver.start()
    defer { receiver.stop() }
    // Rebind the redirect URI to the port actually bound: the provider
    // config names port 0's real value only after the receiver starts.
    let boundRedirect = "http://127.0.0.1:\(receiver.port)\(redirect.path)"
    let boundConfiguration = OAuthTokenClient.Configuration(
        tokenEndpoint: configuration.tokenEndpoint,
        clientID: configuration.clientID,
        clientSecret: configuration.clientSecret,
        redirectURI: boundRedirect,
        scope: configuration.scope
    )
    let url = makeAuthorizeURL(
        endpoint: authorizeEndpoint,
        configuration: boundConfiguration,
        pkce: pkce,
        state: state
    )
    // The browser handle: cancelled when the sign-in ends (success,
    // decline, mismatch, timeout — the sheet must not outlive the
    // exchange), and resolved `false` by the adapter when the person
    // closes the sheet before any redirect arrives.
    let browser = BrowserSession { receiver.stop() }
    await openBrowser(url, browser)

    let captured = try await receiver.awaitRedirect(timeout: timeout)
    defer { browser.cancel() }
    // An empty capture (nothing captured) happens when the receiver was
    // stopped early: the person closed the sheet, or the browser could
    // not open at all. Either ends the flow at once — the flags decide
    // which sentence. A real redirect always wins over a late close.
    let empty = captured.code == nil && captured.state == nil
        && (captured.error == nil || captured.error!.isEmpty)
    if empty {
        if browser.sheetClosedByPerson { throw OAuthAuthorizeFlowError.cancelled }
        if browser.openerFailed { throw OAuthAuthorizeFlowError.browserUnavailable }
    }
    if let error = captured.error, !error.isEmpty {
        throw OAuthAuthorizeFlowError.providerDeclined(error)
    }
    guard captured.state == state else { throw OAuthAuthorizeFlowError.stateMismatch }
    guard let code = captured.code, !code.isEmpty else {
        throw OAuthAuthorizeFlowError.providerDeclined("missing_code")
    }
    return try await client.exchangeWithRedirect(code: code, redirectURI: boundRedirect, pkce: pkce)
}

/// The handle the browser seam receives with the authorize URL. The flow
/// cancels it when the sign-in ends so the browser sheet is dismissed
/// whatever the outcome; the adapter reports the person closing the sheet
/// (`personClosedSheet`, which also ends the redirect wait — the browser
/// was its only source) or the sheet failing to open
/// (`openerCouldNotOpen`, same). The methods are public: the adapter lives
/// in the app target, a different module.
public final class BrowserSession: Sendable {
    /// Latches, so a close or cancel is recorded exactly once.
    private let closedByPerson = ClosedBox()
    private let openerFailedBox = ClosedBox()
    private let flowDone = SheetWaiter()
    /// The flow's way to end the redirect wait when the browser dies
    /// early: the receiver's `stop()`, which resumes the parked wait with
    /// an empty capture. Installed at construction; never replaced.
    private let unavailable: @Sendable () -> Void

    /// - Parameter onUnavailable: called when the browser is gone before
    ///   any redirect (person closed the sheet, or it failed to open).
    ///   The flow passes the receiver's `stop()`.
    public init(onUnavailable: @escaping @Sendable () -> Void) {
        self.unavailable = onUnavailable
    }

    /// The adapter reports the person closed the sheet. Records the
    /// close, ends the redirect wait (no browser, no future redirect),
    /// and wakes the adapter's dismissal await with `false` (the sheet
    /// is already gone; nothing to cancel).
    public func personClosedSheet() {
        if self.closedByPerson.close() {
            self.unavailable()
            self.flowDone.resolve(false)
        }
    }

    /// The adapter reports the sheet could not open (no window, start
    /// refused). Same early end as a person-close, reported to the flow
    /// as `browserUnavailable` rather than `cancelled`.
    public func openerCouldNotOpen() {
        if self.openerFailedBox.close() {
            self.unavailable()
            self.flowDone.resolve(true)
        }
    }

    /// True when the person closed the sheet before any redirect.
    public var sheetClosedByPerson: Bool { self.closedByPerson.isOpen }
    /// True when the sheet never opened or died with a non-person error.
    public var openerFailed: Bool { self.openerFailedBox.isOpen }

    /// The adapter awaits this to learn when the flow is done with the
    /// browser: `true` resolves when the flow ends the sign-in (cancel
    /// the sheet), `false` when the person already closed it themselves.
    public func waitUntilFlowDone() async -> Bool {
        await self.flowDone.wait()
    }

    /// The flow is done with the browser (any outcome): dismiss the
    /// sheet if it is still up. Idempotent; a later person-close after
    /// the flow finished is ignored (the waiter is single-shot).
    public func cancel() {
        _ = self.closedByPerson.close()
        self.flowDone.resolve(true)
    }
}

/// A one-way boolean latch safe to close from any thread.
private final class ClosedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    var isOpen: Bool { self.lock.withLock { self.closed } }
    /// Returns true on the first close, false afterwards.
    func close() -> Bool {
        self.lock.withLock {
            if self.closed { return false }
            self.closed = true
            return true
        }
    }
}

/// A single-shot async waiter for the adapter's sheet-dismissal await.
/// The first `resolve` wins; later ones are ignored, and a resolve that
/// lands before any `wait` is handed back immediately.
private final class SheetWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var resolved: Bool?

    func resolve(_ value: Bool) {
        let toResume = self.lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            guard self.resolved == nil else { return nil }
            self.resolved = value
            let pending = self.continuation
            self.continuation = nil
            return pending
        }
        toResume?.resume(returning: value)
    }

    func wait() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let outcome = self.lock.withLock { () -> Bool? in
                if let resolved = self.resolved { return resolved }
                self.continuation = continuation
                return nil
            }
            if let outcome { continuation.resume(returning: outcome) }
        }
    }
}
