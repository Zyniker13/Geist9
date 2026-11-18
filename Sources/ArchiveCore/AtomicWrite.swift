// Atomic, durable writes (DESIGN 6): every file the archive writes lands via
// write-temp → fsync → rename → fsync-directory, so a crash or power loss never
// leaves a half-written message or manifest. The original bytes of every message
// are kept exactly as downloaded; these helpers are the only writers.

import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

enum AtomicWrite {
    /// Writes `data` to `url` atomically and durably. Never rewrites an existing
    /// file's content in place: rename replaces it as a unit.
    static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appendingPathComponent(".tmp-" + UUID().uuidString + ".writing")

        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else { throw ArchiveError.io(underlying: ioDescription()) }
        defer { close(fd) }

        try data.withUnsafeBytes { raw in
            var written = 0
            while written < data.count {
                #if canImport(Glibc)
                let n = Glibc.write(fd, raw.baseAddress!.advanced(by: written), data.count - written)
                #else
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: written), data.count - written)
                #endif
                if n < 0 {
                    if errno == EINTR { continue }
                    throw ArchiveError.io(underlying: ioDescription())
                }
                written += n
            }
        }

        // Flush the file before the rename, so the renamed file is complete.
        try sync(fd: fd)

        guard rename(temp.path, url.path) == 0 else {
            let description = ioDescription()
            try? FileManager.default.removeItem(at: temp)
            throw ArchiveError.io(underlying: description)
        }

        // And flush the directory so the rename itself is durable.
        let dirFD = open(directory.path, O_RDONLY)
        guard dirFD >= 0 else { throw ArchiveError.io(underlying: ioDescription()) }
        defer { close(dirFD) }
        try sync(fd: dirFD)
    }

    /// Finalizes a file that was written to `temp` by a streaming writer:
    /// fsync it, rename it to `url`, fsync the directory. Deletes the temp
    /// file when anything fails, so a partial export never keeps the
    /// destination's name.
    static func finalize(temp: URL, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let fd = open(temp.path, O_RDONLY)
        guard fd >= 0 else { throw ArchiveError.io(underlying: ioDescription()) }
        defer { close(fd) }
        try sync(fd: fd)
        guard rename(temp.path, url.path) == 0 else {
            let description = ioDescription()
            try? FileManager.default.removeItem(at: temp)
            throw ArchiveError.io(underlying: description)
        }
        let dirFD = open(directory.path, O_RDONLY)
        guard dirFD >= 0 else { throw ArchiveError.io(underlying: ioDescription()) }
        defer { close(dirFD) }
        try sync(fd: dirFD)
    }

    private static func sync(fd: Int32) throws {
        #if os(macOS)
        // F_FULLFSYNC forces a physical flush on APFS; fsync alone may not.
        let result = fcntl(fd, F_FULLFSYNC)
        if result != 0 {
            guard fsync(fd) == 0 else { throw ArchiveError.io(underlying: ioDescription()) }
        }
        #else
        guard fsync(fd) == 0 else { throw ArchiveError.io(underlying: ioDescription()) }
        #endif
    }

    /// Snapshot errno into a string before anything else can touch it.
    private static func ioDescription() -> String {
        String(cString: strerror(errno)) + " (errno \(errno))"
    }
}
