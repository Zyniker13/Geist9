import Foundation
import NIOCore
import NIOPosix
import Testing

/// A test-server bootstrap that never waits without a deadline and never
/// parks the cooperative pool on NIO teardown.
///
/// The OAuth suites' `OAuthTestServer.stop()` once deadlocked exactly here:
/// an unbounded `syncShutdownGracefully()` (or any `.wait()`) called from a
/// task running on the cooperative pool can wait for event-loop threads
/// that the pool must spawn — the pool cannot spawn them while a thread is
/// parked on the wait, so every concurrent test wedges and the run hangs
/// until the CI job cap. Two rules follow, and this helper enforces both:
///
/// 1. the NIO `.wait()` runs on a plain worker `Thread`, never on the
///    cooperative pool, so the bind progresses independently of whatever
///    the pool is juggling;
/// 2. every wait is bounded — the caller blocks on a semaphore with a
///    deadline, so even a bind that never completes costs at most
///    `timeout` seconds and then throws `BindTimedOut` instead of parking
///    the task forever.
///
/// `start()`/`stop()` therefore stay callable synchronously from
/// `setUpWithError` and `defer` while remaining hang-free under
/// `swift test --parallel`.
enum NonBlockingTestBootstrap {
    /// Runs `makeFuture`'s bind on its own worker thread and returns the
    /// bound channel. Throws the bind's own error when the bind fails
    /// (port in use, …) and `BindTimedOut` when it does not complete
    /// within `timeout` seconds.
    static func bind(
        _ makeFuture: @escaping @Sendable () throws -> EventLoopFuture<Channel>,
        timeout: TimeInterval = 10
    ) throws -> Channel {
        let box = BindBox()
        let ready = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            do {
                box.set(.bound(try makeFuture().wait()))
            } catch {
                box.set(.failed(error))
            }
            ready.signal()
        }
        // The caller's wait is bounded: whether the caller runs on the
        // cooperative pool or a plain thread, at most `timeout` seconds
        // are lost, because the worker signals independently of anything
        // the pool would have to schedule. That is the difference between
        // this and the unbounded `.wait()` that wedged whole runs.
        guard ready.wait(timeout: .now() + timeout) == .success else {
            throw BindTimedOut()
        }
        switch box.take() {
        case .bound(let channel): return channel
        case .failed(let error): throw error
        }
    }

    /// The bind did not complete within the deadline.
    struct BindTimedOut: Error, Equatable {}

    /// The bind worker's outcome, handed to the bounded waiter.
    private enum Outcome: Sendable {
        case bound(Channel)
        case failed(Error)
    }

    /// A one-slot handoff from the bind worker to the bounded waiter.
    private final class BindBox: @unchecked Sendable {
        private let lock = NSLock()
        private var outcome: Outcome?

        func set(_ outcome: Outcome) {
            self.lock.lock()
            if self.outcome == nil { self.outcome = outcome }
            self.lock.unlock()
        }

        /// Precondition: the worker signalled, so a value is set.
        func take() -> Outcome {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.outcome!
        }
    }
}

@Suite("NonBlockingTestBootstrap")
struct NonBlockingTestBootstrapTests {
    @Test func bindReturnsABoundChannelOnLoopback() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { group.shutdownGracefully { _ in } }
        let channel = try NonBlockingTestBootstrap.bind({
            ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0)
        }, timeout: 10)
        defer { channel.close(promise: nil) }
        #expect(try #require(channel.localAddress?.port) > 0)
    }

    @Test func bindFailureThrowsTheBindsOwnErrorNotATimeout() throws {
        let holderGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { holderGroup.shutdownGracefully { _ in } }
        let holder = try NonBlockingTestBootstrap.bind({
            ServerBootstrap(group: holderGroup).bind(host: "127.0.0.1", port: 0)
        }, timeout: 10)
        defer { holder.close(promise: nil) }
        let held = try #require(holder.localAddress?.port)

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { group.shutdownGracefully { _ in } }
        do {
            _ = try NonBlockingTestBootstrap.bind({
                try ServerBootstrap(group: group)
                    .bind(to: SocketAddress(ipAddress: "127.0.0.1", port: held))
            }, timeout: 5)
            Issue.record("the second bind should have failed")
        } catch is NonBlockingTestBootstrap.BindTimedOut {
            Issue.record("the occupied-port bind failed as a timeout, not a bind error")
        } catch {
            // Expected: the bind's own error (address in use), not a hang.
        }
    }

    /// A bind that never completes fails the call at the deadline instead
    /// of parking it forever — the regression test for the cooperative-pool
    /// wedge that once hung the whole parallel test run.
    @Test func bindThatNeverCompletesTimesOut() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { group.shutdownGracefully { _ in } }
        // A promise nobody ever succeeds: its future never completes.
        let promise = group.next().makePromise(of: Channel.self)
        do {
            _ = try NonBlockingTestBootstrap.bind({
                promise.futureResult
            }, timeout: 0.5)
            Issue.record("the never-completing bind should have timed out")
        } catch let error as NonBlockingTestBootstrap.BindTimedOut {
            // Expected: the deadline threw instead of parking forever.
            _ = error
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
