// Integrity scrub (DESIGN 6): verify every stored file against its name and
// every indexed row against the files. Scrub only reports and repairs the
// index side; it never deletes or rewrites stored message bytes — a mismatch
// is the archive telling the person something they need to know.

import Foundation
import GRDB

public struct ScrubReport: Sendable, Equatable {
    /// .eml files hashed and compared against their names.
    public var filesVerified: Int
    /// Files whose bytes no longer hash to their name.
    public var hashMismatches: [MessageHash]
    /// Indexed messages whose file is missing (data loss candidates).
    public var missingFiles: [MessageHash]
    /// Files present but not indexed (hex, no .eml suffix); safe to re-ingest.
    public var unindexedFiles: [String]
    /// Files whose name or path does not match the layout contract.
    public var corruptLayout: [String]

    public var isClean: Bool {
        hashMismatches.isEmpty && missingFiles.isEmpty && unindexedFiles.isEmpty && corruptLayout.isEmpty
    }
}

extension ArchiveStore {
    /// Hashes every stored message file and cross-checks it against the index.
    ///
    /// - filesVerified + hashMismatches == number of .eml files found
    /// - a mismatch means the file's bytes changed after storing (never repair
    ///   silently: the person decides)
    /// - missingFiles: indexed row with no file — the row is reported, bytes win
    /// - unindexedFiles: file with no row — the index is behind; rebuild catches up
    public func scrub() throws -> ScrubReport {
        var report = ScrubReport(
            filesVerified: 0, hashMismatches: [], missingFiles: [], unindexedFiles: [], corruptLayout: []
        )
        let fm = FileManager.default

        // Walk messages/ab/cd/<hash>.eml
        var filesByHex = Set<String>()
        let shards = (try? fm.contentsOfDirectory(atPath: messagesDirectory.path)) ?? []
        for shard1 in shards.sorted() {
            let shard1URL = messagesDirectory.appendingPathComponent(shard1)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: shard1URL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }
            for shard2 in (try? fm.contentsOfDirectory(atPath: shard1URL.path))?.sorted() ?? [] {
                let shard2URL = shard1URL.appendingPathComponent(shard2)
                guard fm.fileExists(atPath: shard2URL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    continue
                }
                for file in (try? fm.contentsOfDirectory(atPath: shard2URL.path))?.sorted() ?? [] {
                    guard file.hasSuffix(".eml") else { continue }
                    let hex = String(file.dropLast(4))
                    guard let stored = MessageHash(hex: hex),
                          stored.shard1 == shard1.lowercased(),
                          stored.shard2 == shard2.lowercased() else {
                        report.corruptLayout.append("\(shard1)/\(shard2)/\(file)")
                        continue
                    }
                    let url = shard2URL.appendingPathComponent(file)
                    guard let data = try? Data(contentsOf: url) else {
                        // Unreadable file: neither matched nor missing; surface as mismatch
                        // since its bytes cannot be verified.
                        report.hashMismatches.append(stored)
                        continue
                    }
                    report.filesVerified += 1
                    if MessageHash.sha256(data) != stored {
                        report.hashMismatches.append(stored)
                        continue
                    }
                    filesByHex.insert(hex)
                }
            }
        }

        // Index rows must all have files.
        let indexedHashes = try db.read { db in
            try Data.fetchAll(db, sql: "SELECT hash FROM message")
        }
        var missing = [MessageHash]()
        var indexedHex = Set<String>()
        for blob in indexedHashes {
            let hash = MessageHash(bytes: blob)
            indexedHex.insert(hash.hex)
            if !filesByHex.contains(hash.hex) {
                missing.append(hash)
            }
        }
        report.missingFiles = missing

        // Files must all be indexed.
        report.unindexedFiles = filesByHex.subtracting(indexedHex).sorted()
        return report
    }
}
