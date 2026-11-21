// ArchiveStore (DESIGN 6): owns one `<name>.emailarchive` directory —
// manifest.json, content-addressed messages/, index.sqlite (WAL), and later
// attachments-text/ and logs/. Message bytes and index rows are written so
// that a crash can never lose stored bytes: the file lands first (fsync'd,
// atomic rename), then the index records it; scrub re-converges the two.

import Foundation
import GRDB

public final class ArchiveStore: Sendable {
    /// Root of the archive, e.g. .../Mail.emailarchive
    public let directory: URL
    public let manifest: ArchiveManifest
    public let db: DatabasePool

    /// Test-only fault injection: called with a stage label at batch-ingest
    /// durability boundaries ("files-written", "dir-fsync", "index-commit") so
    /// crash-recovery tests can stop the process exactly between stages.
    /// Always nil in production; the crash tests in KillTests.swift are the
    /// only setters. Not part of the API contract.
    nonisolated(unsafe) public static var crashHook: (@Sendable (String) -> Void)?

    /// The index format this store was created at or migrated to.
    public var indexVersion: Int { IndexSchema.version }

    // MARK: Layout

    static let manifestName = "manifest.json"
    static let indexName = "index.sqlite"
    static let messagesDirName = "messages"
    static let attachmentsTextDirName = "attachments-text"

    var messagesDirectory: URL { directory.appendingPathComponent(Self.messagesDirName) }
    var indexURL: URL { directory.appendingPathComponent(Self.indexName) }

    public static func isArchiveDirectory(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(manifestName).path)
    }

    /// Creates a new archive. Refuses to touch an existing non-empty directory.
    public static func create(at directory: URL, appVersion: String) throws -> ArchiveStore {
        let fm = FileManager.default
        let exists = (try? directory.checkResourceIsReachable()) ?? false
        if exists {
            let contents = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
            if !contents.isEmpty { throw ArchiveError.notAnArchive }
        } else {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try fm.createDirectory(at: directory.appendingPathComponent(messagesDirName), withIntermediateDirectories: true)
        let manifest = ArchiveManifest(createdAt: Date(), appVersion: appVersion)
        try manifest.write(to: directory.appendingPathComponent(manifestName))
        return try open(at: directory)
    }

    /// Opens an existing archive, validating its manifest and running migrations.
    public static func open(at directory: URL) throws -> ArchiveStore {
        let manifestURL = directory.appendingPathComponent(manifestName)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw ArchiveError.notAnArchive
        }
        let manifest = try ArchiveManifest.read(from: manifestURL)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(messagesDirName), withIntermediateDirectories: true
        )
        let db = try IndexSchema.openDatabase(at: directory.appendingPathComponent(indexName))
        return ArchiveStore(directory: directory, manifest: manifest, db: db)
    }

    /// Opens an existing archive strictly read-only, for readers that must
    /// never write: the MCP helper (DESIGN 9A), scripts, tests.
    ///
    /// The manifest is validated and the index is opened with SQLite's
    /// read-only mode, so any attempted write fails at the database layer.
    /// Unlike `open`, this never migrates, never creates directories, and
    /// never touches a byte of the archive: if the index is behind the
    /// current schema the open fails with `schemaBehind` and the person is
    /// asked to open the archive in the app once so it can upgrade.
    public static func openReadOnly(at directory: URL) throws -> ArchiveStore {
        let manifestURL = directory.appendingPathComponent(manifestName)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw ArchiveError.notAnArchive
        }
        let manifest = try ArchiveManifest.read(from: manifestURL)
        var configuration = Configuration()
        configuration.readonly = true
        configuration.busyMode = .timeout(10)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA mmap_size = 1073741824")
        }
        let db = try DatabasePool(
            path: directory.appendingPathComponent(indexName).path, configuration: configuration
        )
        try verifySchemaCurrent(db)
        return ArchiveStore(directory: directory, manifest: manifest, db: db)
    }

    /// Read-only readers never migrate: refuse instead (DESIGN 9A).
    static func verifySchemaCurrent(_ db: DatabasePool) throws {
        let target = IndexSchema.migrationTargetCount
        let applied = try db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations") ?? 0
        }
        guard applied == target else {
            throw ArchiveError.schemaBehind(applied: applied, target: target)
        }
    }

    init(directory: URL, manifest: ArchiveManifest, db: DatabasePool) {
        self.directory = directory
        self.manifest = manifest
        self.db = db
    }

    // MARK: Content-addressed message storage

    /// Storage path of a message, relative to the archive root.
    public static func relativePath(for hash: MessageHash) -> String {
        "\(messagesDirName)/\(hash.relativePath)"
    }

    func fileURL(for hash: MessageHash) -> URL {
        messagesDirectory.appendingPathComponent(hash.relativePath)
    }

    /// Stores message bytes content-addressed. If the exact bytes are already
    /// stored, does nothing (dedup) — bytes are never rewritten in place.
    /// Returns the hash. The write is fsync'd before it returns.
    @discardableResult
    public func putMessage(_ data: Data) throws -> MessageHash {
        let hash = MessageHash.sha256(data)
        let url = fileURL(for: hash)
        if FileManager.default.fileExists(atPath: url.path) { return hash }
        try AtomicWrite.write(data, to: url)
        return hash
    }

    /// The stored original bytes of a message.
    public func messageData(_ hash: MessageHash) throws -> Data {
        let url = fileURL(for: hash)
        do {
            return try Data(contentsOf: url)
        } catch {
            throw ArchiveError.messageNotFound(hash)
        }
    }

    public func hasMessage(_ hash: MessageHash) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: hash).path)
    }
}
