import ArchiveCore
import Credentials
import Foundation

/// What the scheduler reports per event. The account is named by address;
/// reasons are one short sentence, never echoing a secret (DESIGN 10).
public enum SchedulerEvent: Sendable, Equatable {
    /// A pass for one account finished.
    case completed(email: String, messagesStored: Int)
    /// A pass was skipped for one account: the reason is a plain sentence
    /// ("Unlock the app to continue archiving") — an unreachable credential
    /// store is never reported as an authentication failure (DESIGN 4).
    case skipped(email: String, reason: String)
    /// A pass failed with the engine's folded sentence.
    case failed(email: String, reason: String)

    /// One folded sentence for a thrown error, mirroring onboarding's
    /// wording so the screen stays consistent. The caller adds the email.
    static func reason(_ error: Error) -> String {
        switch error as? SyncEngineError {
        case .authenticationFailed:
            return "The server rejected the sign-in. Check the address and the app password."
        case .connectionLost:
            return "Could not reach the mail server. Check the address, the port, and the network."
        case .commandFailed(let message):
            return "The server refused the sync: \(message)"
        case .certificateNotConfirmed:
            return "Confirm the server's certificate fingerprint before connecting."
        case nil:
            return "The sync failed: \(error)"
        }
    }
}

/// The sync scheduler (M4, DESIGN 5 "Politeness and Limits" and
/// "Background Sync").
///
/// It lists the archive's syncable accounts (decision 0062), reads each
/// secret from the credential store under the onboarding key
/// (`OnboardingController.credentialKey`), and runs one engine pass per
/// account. Accounts are processed **serially, one at a time** — that is
/// the politeness contract: never two accounts of the same provider
/// hammering a server at once.
///
/// `start` runs one pass immediately and then on the cadence
/// (default 30 minutes, DESIGN 5); `stop` cancels and `start` may be
/// called again (the app's foreground/background transition). `runPass`
/// is also public so the app can sync on demand ("Sync now").
public final class SyncScheduler: @unchecked Sendable {
    /// Time between automatic passes.
    private let pollInterval: Duration
    /// Serial gate: one pass across all accounts at a time. Reentrancy is
    /// deliberate — a `runPass` started while one is in flight returns
    /// immediately without duplicating work (an on-demand "Sync now" while
    /// the cadence is mid-pass is a no-op, not a second pass).
    private let gate = TryLockBox()
    /// The cadence task holder (`start`/`stop` run in async contexts).
    private let cadence = CadenceBox()

    public init(pollInterval: Duration = .seconds(30 * 60)) {
        self.pollInterval = pollInterval
    }

    /// The observer type for pass events. Function types are escaping by
    /// default; `@Sendable` keeps it cross-task safe.
    public typealias Observer = @Sendable (SchedulerEvent) -> Void

    /// Runs one pass over every syncable account, serially. Skips an
    /// account whose secret is absent or whose store is unavailable
    /// (1Password locked: DESIGN 4's "Unlock 1Password to continue
    /// archiving"), and reports engine failures as folded sentences.
    /// Returns the summed progress of the passes that ran.
    @discardableResult
    public func runPass(
        store: ArchiveStore,
        credentials: any CredentialStore,
        onEvent: @escaping Observer = { _ in }
    ) async throws -> SyncProgress {
        // Reentrancy: a pass already running makes this one a no-op.
        guard gate.tryLock() else { return SyncProgress() }
        defer { gate.unlock() }

        var total = SyncProgress()
        let accounts = try store.syncableAccounts()
        for syncable in accounts {
            guard !Task.isCancelled else { break }
            let email = syncable.identity.email
            let key = OnboardingController.credentialKey(email: email)
            let secret: Data
            do {
                secret = try await credentials.get(key)
            } catch {
                onEvent(.skipped(email: email, reason: "Unlock the app to continue archiving"))
                continue
            }
            let engine = IMAPSyncEngine(
                profile: syncable.profile, account: syncable.identity
            )
            do {
                let progress = try await engine.sync(
                    store: store, credentials: email,
                    password: String(data: secret, encoding: .utf8) ?? ""
                )
                total.add(progress)
                onEvent(.completed(email: email, messagesStored: progress.messagesStored))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                onEvent(.failed(email: email, reason: SchedulerEvent.reason(error)))
            }
        }
        return total
    }

    /// Starts the cadence: one immediate pass (awaited — `start` returns
    /// after it), then one every `pollInterval` until `stop`. A second
    /// `start` while one is running first stops it. The immediate pass and
    /// the loop share the reentrancy gate, so an on-demand `runPass` during
    /// a tick is a no-op rather than a second concurrent pass.
    public func start(
        store: ArchiveStore,
        credentials: any CredentialStore,
        onEvent: @escaping Observer = { _ in }
    ) async {
        await stop()
        // The immediate first pass, awaited before the loop starts.
        do {
            try await runPass(store: store, credentials: credentials, onEvent: onEvent)
        } catch is CancellationError {
            return
        } catch {
            onEvent(.failed(email: "", reason: SchedulerEvent.reason(error)))
        }
        let task = Task { [pollInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                if Task.isCancelled { break }
                do {
                    try await self.runPass(store: store, credentials: credentials, onEvent: onEvent)
                } catch is CancellationError {
                    break
                } catch {
                    onEvent(.failed(email: "", reason: SchedulerEvent.reason(error)))
                }
            }
        }
        _ = cadence.swap(task)
    }

    /// Stops the cadence and waits for the in-flight pass to finish (never
    /// mid-write: the engine's own cancellation contract, decision 0060).
    public func stop() async {
        guard let task = cadence.swap(nil) else { return }
        task.cancel()
        await task.value
    }
}

/// A boolean lock box whose `tryLock` never blocks: the scheduler's
/// non-reentrancy gate. One reference, mutated only under its own lock.
final class TryLockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var locked = false

    /// Returns false when the lock is already held. `try()`/`unlock()` are
    /// permitted in async contexts (only the blocking `lock()` is not).
    func tryLock() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if locked { return false }
        locked = true
        return true
    }

    func unlock() {
        lock.lock()
        defer { lock.unlock() }
        locked = false
    }
}

/// The cadence-task holder. The swap happens synchronously inside the
/// guarded region, so calling `swap` from an async context is safe: no
/// blocking `NSLock.lock()` is invoked while suspended, and the closure
/// never awaits.
final class CadenceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func swap(_ replacement: Task<Void, Never>?) -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        let current = task
        task = replacement
        return current
    }
}

extension SyncProgress {
    /// Adds another progress report's counts into this one.
    mutating func add(_ other: SyncProgress) {
        foldersListed += other.foldersListed
        messagesStored += other.messagesStored
        messagesDuplicate += other.messagesDuplicate
        bytesDownloaded += other.bytesDownloaded
    }
}
