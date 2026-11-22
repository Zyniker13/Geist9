import Foundation

/// A cross-process mutual exclusion lock held on a file, so concurrently
/// scheduled test processes (swift test --parallel launches more than one
/// runner for a single test bundle) serialize against the one shared test
/// server. POSIX flock; the fd stays open for the lock's lifetime.
struct FileLock {
    let path: String
    private var fd: Int32 = -1

    init(name: String) {
        self.path = FileManager.default.temporaryDirectory
            .appendingPathComponent(name).path
    }

    /// Runs `body` holding the lock. Blocks until the lock is free; fails
    /// loudly if the lock file cannot be opened (never a silent skip).
    func withLock<T>(_ body: () async throws -> T) async throws -> T {
        let fd = open(self.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            throw NSError(
                domain: "FileLock", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "cannot open lock file \(self.path)"]
            )
        }
        defer { close(fd) }
        // Blocking exclusive lock; released by close in the defer.
        while true {
            if flock(fd, LOCK_EX) == 0 { break }
            if errno == EINTR { continue }
            throw NSError(
                domain: "FileLock", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "flock failed on \(self.path): errno \(errno)"]
            )
        }
        return try await body()
    }
}
